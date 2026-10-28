(function () {
  if (window.__webTap) return;

  // ---------------------------------------------------------------------
  // Streaming "tap": copies the audio segments YouTube Music appends to its
  // MSE buffer, decodes them with decodeAudioData and plays them through the
  // equaliser chain built by webEqJs, while the page's own element is muted.
  // The element keeps running (muted) and stays the master clock.
  // ---------------------------------------------------------------------
  var FR = 1024;            // samples per AAC-LC frame
  var PREROLL = 3;          // frames decoded before a segment, then thrown away
  var LOOKAHEAD = 14;       // seconds of audio decoded and scheduled ahead
  var KEEP_BEHIND = 3;      // seconds of decoded audio kept behind the playhead
  var MAX_BYTES = 40 * 1048576;
  var DRIFT = 0.08;         // seconds the output may lag the page's clock before it is re-anchored
  var RATES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
               16000, 12000, 11025, 8000, 7350];

  var S = {
    sbs: new WeakMap(), owner: new WeakMap(), blobs: {}, list: [],
    ctx: null, sink: null, enabled: false, offsetMs: 0,
    mode: 'adts',                       // 'adts' (raw AAC frames) or 'fmp4'
    anchor: null, gen: 0, bad: 0, disabled: '',
    muting: false, fallback: false, fallbackAt: 0,
    uncoveredSince: 0, uncoveredMedia: 0, coveredSince: 0,
    decoding: 0, lastErr: '',
    stats: { appends: 0, segs: 0, decoded: 0, failed: 0, missedInit: 0,
             reanchors: 0, fallbacks: 0, driftMs: 0, maxDriftMs: 0, stalls: 0,
             maxTickGapMs: 0, maxDecodeMs: 0 },
    log: [], lastTick: 0, lastCT: -1, lastCTWall: 0, stalled: false, stalledAt: 0, lastCover: null,
    elFn: function () { return document.querySelector('video, audio'); }
  };
  var T0 = performance.now();
  // ring buffer shown by the debug screen: [seconds since start, kind, text]
  function dbg(k, m) {
    try {
      var l = S.log;
      l.push([Math.round(performance.now() - T0) / 1000, k, String(m).slice(0, 220)]);
      if (l.length > 500) l.shift();
    } catch (e) {}
  }
  function noteErr(e) { S.lastErr = String(e && e.message || e).slice(0, 160); dbg('error', S.lastErr); }

  // ---------------- MP4 parsing ----------------
  function u32(u, o) { return ((u[o] << 24) | (u[o + 1] << 16) | (u[o + 2] << 8) | u[o + 3]) >>> 0; }
  function i32(u, o) { return (u[o] << 24) | (u[o + 1] << 16) | (u[o + 2] << 8) | u[o + 3]; }
  function u64(u, o) { return u32(u, o) * 4294967296 + u32(u, o + 4); }
  function u16(u, o) { return (u[o] << 8) | u[o + 1]; }
  function cc(u, o) { return String.fromCharCode(u[o], u[o + 1], u[o + 2], u[o + 3]); }

  // cb(type, bodyStart, boxEnd, boxStart); return false to stop.
  function boxes(u, start, end, cb) {
    var o = start;
    while (o + 8 <= end) {
      var size = u32(u, o), type = cc(u, o + 4), hdr = 8;
      if (size === 1) { size = u64(u, o + 8); hdr = 16; }
      else if (size === 0) size = end - o;
      if (size < hdr || o + size > end) break;
      if (cb(type, o + hdr, o + size, o) === false) return;
      o += size;
    }
  }
  function topTypes(u) {
    var t = [];
    boxes(u, 0, u.length, function (type) { t.push(type); });
    return t;
  }

  function parseEsds(u, s, e) {
    function desc(o) {
      var tag = u[o++], len = 0, b, n = 0;
      do { b = u[o++]; len = (len << 7) | (b & 127); n++; } while ((b & 128) && n < 4 && o < e);
      return { tag: tag, len: len, pos: o };
    }
    var d = desc(s);
    if (d.tag !== 3) return null;
    var o = d.pos + 2, fl = u[o++];
    if (fl & 0x80) o += 2;
    if (fl & 0x40) o += 1 + u[o];
    if (fl & 0x20) o += 2;
    d = desc(o);
    if (d.tag !== 4) return null;
    d = desc(d.pos + 13);
    if (d.tag !== 5) return null;
    return u.slice(d.pos, d.pos + d.len);
  }

  function parseAsc(a) {
    if (!a || a.length < 2) return null;
    var bit = 0;
    function rd(n) {
      var v = 0;
      while (n--) { v = (v * 2) + ((a[bit >> 3] >> (7 - (bit & 7))) & 1); bit++; }
      return v;
    }
    var aot = rd(5);
    if (aot === 31) aot = 32 + rd(6);
    var fi = rd(4), rate;
    if (fi === 15) rate = rd(24); else rate = RATES[fi];
    var ch = rd(4);
    return { aot: aot, fi: fi, rate: rate, ch: ch };
  }

  // Returns { audio: track|null, trex, end } for a buffer that holds a moov.
  function parseInit(u) {
    var out = { audio: null, hasVideo: false, trex: {}, end: 0 };
    boxes(u, 0, u.length, function (t, s, e) {
      if (t !== 'moov') return;
      out.end = e;
      boxes(u, s, e, function (t2, s2, e2) {
        if (t2 === 'mvex') {
          boxes(u, s2, e2, function (t3, s3) {
            if (t3 === 'trex') out.trex[u32(u, s3 + 4)] = { dur: u32(u, s3 + 12), size: u32(u, s3 + 16) };
          });
        }
      });
      boxes(u, s, e, function (t2, s2, e2) {
        if (t2 !== 'trak') return;
        var tr = { id: 0, scale: 0, handler: '', codec: '', asc: null, ascInfo: null, ch: 0, rate: 0 };
        boxes(u, s2, e2, function (t3, s3, e3) {
          if (t3 === 'tkhd') {
            tr.id = u32(u, s3 + (u[s3] === 1 ? 20 : 12));
          } else if (t3 === 'mdia') {
            boxes(u, s3, e3, function (t4, s4, e4) {
              if (t4 === 'mdhd') tr.scale = u32(u, s4 + (u[s4] === 1 ? 20 : 12));
              else if (t4 === 'hdlr') tr.handler = cc(u, s4 + 8);
              else if (t4 === 'minf') {
                boxes(u, s4, e4, function (t5, s5, e5) {
                  if (t5 !== 'stbl') return;
                  boxes(u, s5, e5, function (t6, s6, e6) {
                    if (t6 !== 'stsd') return;
                    boxes(u, s6 + 8, e6, function (t7, s7, e7) {
                      tr.codec = t7;
                      if (t7 === 'mp4a') {
                        tr.ch = u16(u, s7 + 16);
                        tr.rate = u16(u, s7 + 24);
                        boxes(u, s7 + 28, e7, function (t8, s8, e8) {
                          if (t8 === 'esds') tr.asc = parseEsds(u, s8 + 4, e8);
                        });
                      }
                    });
                  });
                });
              }
            });
          }
        });
        if (tr.handler === 'soun' && !out.audio) {
          tr.ascInfo = parseAsc(tr.asc);
          if (tr.ascInfo && tr.ascInfo.rate) tr.rate = tr.ascInfo.rate;
          out.audio = tr;
        } else if (tr.handler === 'vide') out.hasVideo = true;
      });
    });
    return out;
  }

  // Fragments (moof + data) of a media segment. Sample offsets are relative to u.
  function parseSegment(u, trex) {
    var frags = [];
    boxes(u, 0, u.length, function (t, s, e, start) {
      if (t !== 'moof') return;
      var fragEnd = e;
      var seenEnd = false;
      boxes(u, e, u.length, function (t2, s2, e2) {
        if (!seenEnd && t2 === 'mdat') { fragEnd = e2; seenEnd = true; }
        return false;
      });
      boxes(u, s, e, function (t2, s2, e2) {
        if (t2 !== 'traf') return;
        var tf = { id: 0, defDur: 0, defSize: 0, baseTime: 0, samples: [],
                   start: start, end: fragEnd, next: 0 };
        boxes(u, s2, e2, function (t3, s3) {
          if (t3 === 'tfhd') {
            var fl = u32(u, s3) & 0xFFFFFF, o = s3 + 4;
            tf.id = u32(u, o); o += 4;
            if (fl & 1) o += 8;
            if (fl & 2) o += 4;
            if (fl & 8) { tf.defDur = u32(u, o); o += 4; }
            if (fl & 0x10) { tf.defSize = u32(u, o); o += 4; }
            var d = trex && trex[tf.id];
            if (d) { if (!tf.defDur) tf.defDur = d.dur; if (!tf.defSize) tf.defSize = d.size; }
          } else if (t3 === 'tfdt') {
            tf.baseTime = u[s3] === 1 ? u64(u, s3 + 4) : u32(u, s3 + 4);
          } else if (t3 === 'trun') {
            var f2 = u32(u, s3) & 0xFFFFFF, n = u32(u, s3 + 4), p = s3 + 8;
            var data = tf.next;
            if (f2 & 1) { data = start + i32(u, p); p += 4; }
            if (f2 & 4) p += 4;
            for (var i = 0; i < n; i++) {
              var dur = tf.defDur, size = tf.defSize;
              if (f2 & 0x100) { dur = u32(u, p); p += 4; }
              if (f2 & 0x200) { size = u32(u, p); p += 4; }
              if (f2 & 0x400) p += 4;
              if (f2 & 0x800) p += 4;
              tf.samples.push({ off: data, size: size, dur: dur || FR });
              data += size;
            }
            tf.next = data;
          }
        });
        frags.push(tf);
      });
    });
    return frags;
  }

  // Raw AAC frames in ADTS wrappers: decodeAudioData reads these everywhere.
  function adts(parts, asc) {
    var total = 0, i;
    for (i = 0; i < parts.length; i++) total += 7 + parts[i].len;
    var out = new Uint8Array(total), o = 0;
    var prof = (asc.aot - 1) & 3, fi = asc.fi, ch = asc.ch;
    for (i = 0; i < parts.length; i++) {
      var p = parts[i], fl = 7 + p.len;
      out[o] = 0xFF; out[o + 1] = 0xF1;
      out[o + 2] = (prof << 6) | (fi << 2) | ((ch >> 2) & 1);
      out[o + 3] = ((ch & 3) << 6) | ((fl >> 11) & 3);
      out[o + 4] = (fl >> 3) & 0xFF;
      out[o + 5] = ((fl & 7) << 5) | 0x1F;
      out[o + 6] = 0xFC;
      out.set(p.u.subarray(p.off, p.off + p.len), o + 7);
      o += fl;
    }
    return out;
  }

  // ---------------- capturing what the page feeds MSE ----------------
  function copyBytes(d) {
    if (d instanceof ArrayBuffer) return new Uint8Array(d.slice(0));
    if (d && ArrayBuffer.isView(d))
      return new Uint8Array(d.buffer.slice(d.byteOffset, d.byteOffset + d.byteLength));
    return null;
  }

  function stateOf(sb) {
    var st = S.sbs.get(sb);
    if (!st) {
      st = { sb: sb, ms: S.owner.get(sb) || null, mime: '', kind: '', init: null,
             segs: [], bytes: 0, last: 0 };
      S.sbs.set(sb, st);
    }
    return st;
  }

  function dropSeg(st, seg) {
    killNode(seg);
    seg.buf = null; seg.dead = true;
    st.bytes -= seg.cost;
  }

  function onAppend(sb, data) {
    var u = copyBytes(data);
    if (!u || u.length < 8) return;
    var st = stateOf(sb);
    S.stats.appends++;
    var types = topTypes(u);
    if (types.indexOf('moov') >= 0) {
      var init = parseInit(u);
      if (init.audio) {
        init.u = u.slice(0, init.end);
        st.init = init;
        dbg('init', init.audio.codec + ' ' + init.audio.rate + 'Hz ch' + init.audio.ch + ' aot' + (init.audio.ascInfo ? init.audio.ascInfo.aot : '?') + ' scale ' + init.audio.scale);
        st.kind = 'audio';
        if (S.list.indexOf(st) < 0) {
          S.list.push(st);
          if (S.list.length > 4) { var old = S.list.shift(); old.segs.forEach(function (g) { dropSeg(old, g); }); old.segs = []; }
        }
      } else if (init.hasVideo) st.kind = 'video';
    }
    if (types.indexOf('moof') >= 0) {
      if (st.kind === 'audio' || (!st.kind && /^audio\//i.test(st.mime))) {
        if (!st.init) { S.stats.missedInit++; dbg('missed-init', 'media segment without an init segment'); return; }
        addSegments(st, u, sb.timestampOffset || 0);
      }
    }
  }

  function addSegments(st, u, tsOff) {
    var trk = st.init.audio, scale = trk.scale || trk.rate || 44100;
    var frags = parseSegment(u, st.init.trex);
    frags.forEach(function (f) {
      if (f.id !== trk.id || !f.samples.length) return;
      var total = 0;
      f.samples.forEach(function (s) { total += s.dur; });
      var t0 = f.baseTime / scale + tsOff;
      var seg = { st: st, init: st.init, u: u, frag: f, samples: f.samples,
                  t0: t0, t1: t0 + total / scale, dur: total / scale,
                  cost: u.length, buf: null, off: 0, len: 0, delay: 0,
                  noPre: false, node: null, gain: null, busy: false,
                  failed: false, dead: false };
      // a re-append of the same time range replaces the older copy
      st.segs = st.segs.filter(function (o) {
        var ov = Math.min(o.t1, seg.t1) - Math.max(o.t0, seg.t0);
        if (ov > 0.5 * Math.min(o.dur, seg.dur)) { dropSeg(st, o); return false; }
        return true;
      });
      st.segs.push(seg);
      st.bytes += seg.cost;
      dbg('seg', seg.t0.toFixed(2) + '-' + seg.t1.toFixed(2) + ' n=' + seg.samples.length + ' ' + Math.round(u.length / 1024) + 'KB');
      S.stats.segs++;
    });
    st.segs.sort(function (a, b) { return a.t0 - b.t0; });
    trim(st);
  }

  function onRemove(sb, a, b) {
    var st = S.sbs.get(sb);
    if (!st || !st.segs.length) return;
    dbg('remove', (+a).toFixed(2) + '-' + (+b).toFixed(2));
    st.segs = st.segs.filter(function (g) {
      if (g.t0 >= a - 0.02 && g.t1 <= b + 0.02) { dropSeg(st, g); return false; }
      return true;
    });
  }

  function trim(st) {
    if (st.bytes <= MAX_BYTES) return;
    var v = S.elFn(), at = v ? v.currentTime : 0;
    var order = st.segs.slice().sort(function (a, b) {
      return Math.abs(b.t0 - at) - Math.abs(a.t0 - at);
    });
    for (var i = 0; i < order.length && st.bytes > MAX_BYTES * 0.8; i++) {
      var g = order[i];
      if (g.node) continue;
      dropSeg(st, g);
      st.segs.splice(st.segs.indexOf(g), 1);
    }
  }

  function patch(P, name, wrap) {
    try {
      if (!P || !P[name] || P[name].__tap) return;
      var orig = P[name];
      var w = wrap(orig);
      w.__tap = true;
      P[name] = w;
    } catch (e) { noteErr(e); }
  }

  function install() {
    ['SourceBuffer', 'ManagedSourceBuffer'].forEach(function (n) {
      var C = window[n];
      if (!C || !C.prototype) return;
      var P = C.prototype;
      patch(P, 'appendBuffer', function (orig) {
        return function (d) {
          try { onAppend(this, d); } catch (e) { noteErr(e); }
          return orig.apply(this, arguments);
        };
      });
      patch(P, 'remove', function (orig) {
        return function (a, b) {
          try { onRemove(this, a, b); } catch (e) { noteErr(e); }
          return orig.apply(this, arguments);
        };
      });
      patch(P, 'changeType', function (orig) {
        return function (t) {
          try { var st = stateOf(this); st.mime = String(t || ''); st.init = null; st.kind = ''; } catch (e) {}
          return orig.apply(this, arguments);
        };
      });
    });
    ['MediaSource', 'ManagedMediaSource'].forEach(function (n) {
      var C = window[n];
      if (!C || !C.prototype) return;
      patch(C.prototype, 'addSourceBuffer', function (orig) {
        return function (type) {
          var sb = orig.apply(this, arguments);
          try { S.owner.set(sb, this); stateOf(sb).mime = String(type || ''); } catch (e) {}
          return sb;
        };
      });
    });
    patch(URL, 'createObjectURL', function (orig) {
      return function (o) {
        var u = orig.apply(this, arguments);
        try {
          if ((window.MediaSource && o instanceof window.MediaSource) ||
              (window.ManagedMediaSource && o instanceof window.ManagedMediaSource)) S.blobs[u] = o;
        } catch (e) {}
        return u;
      };
    });
  }

  // The audio buffer that belongs to the element that is playing now.
  function activeState(v) {
    var ms = null;
    try {
      var so = v.srcObject;
      if (so) ms = so;
      else ms = S.blobs[v.currentSrc || v.src] || null;
    } catch (e) {}
    var best = null;
    for (var i = S.list.length - 1; i >= 0; i--) {
      var st = S.list[i];
      if (ms && st.ms === ms) return st;
      if (!best && !ms) best = st;
    }
    if (best) return best;
    return S.list.length ? S.list[S.list.length - 1] : null;
  }

  // ---------------- decoding ----------------
  function decodeAB(ab) {
    return new Promise(function (res, rej) {
      try {
        var p = S.ctx.decodeAudioData(ab, res, rej);
        if (p && p.then) p.then(res, rej);
      } catch (e) { rej(e); }
    });
  }

  function prevContiguous(seg) {
    var st = seg.st, best = null, tol = 0.6 * FR / (seg.init.audio.rate || 44100);
    for (var i = 0; i < st.segs.length; i++) {
      var o = st.segs[i];
      if (o !== seg && !o.dead && o.init === seg.init && Math.abs(o.t1 - seg.t0) < tol) best = o;
    }
    return best;
  }

  function finishAdts(seg, buf, pre) {
    var asc = seg.init.audio.ascInfo, n = seg.samples.length;
    var expect = (pre + n) * FR / asc.rate;
    var actual = buf.length / buf.sampleRate;
    var trim = Math.max(0, expect - actual);       // decoder dropped priming at the front
    var off = pre * FR / asc.rate - trim;
    var len = n * FR / asc.rate;
    var delay = 0;
    if (off < 0) { delay = -off; len += off; off = 0; }
    seg.buf = buf; seg.off = off; seg.len = len; seg.delay = delay;
    seg.noPre = pre === 0;
  }

  function decodeSeg(seg) {
    if (seg.buf || seg.busy || seg.failed || seg.dead || !S.ctx) return;
    if (S.decoding >= 2) return;
    var trk = seg.init.audio, asc = trk.ascInfo;
    var canAdts = S.mode === 'adts' && asc && asc.aot === 2 && asc.fi <= 12 && asc.ch >= 1 && asc.ch <= 2;
    seg.busy = true; S.decoding++;
    var tDec = performance.now();
    var work;
    if (canAdts) {
      var prev = prevContiguous(seg), parts = [], pre = 0, i;
      if (prev) {
        var from = Math.max(0, prev.samples.length - PREROLL);
        for (i = from; i < prev.samples.length; i++) {
          parts.push({ u: prev.u, off: prev.samples[i].off, len: prev.samples[i].size });
          pre++;
        }
      }
      for (i = 0; i < seg.samples.length; i++)
        parts.push({ u: seg.u, off: seg.samples[i].off, len: seg.samples[i].size });
      var bytes = adts(parts, asc);
      work = decodeAB(bytes.buffer).then(function (buf) { finishAdts(seg, buf, pre); });
    } else {
      work = decodeFmp4(seg);
    }
    work.then(function () {
      var ms = Math.round(performance.now() - tDec);
      if (ms > S.stats.maxDecodeMs) S.stats.maxDecodeMs = ms;
      dbg('decoded', seg.t0.toFixed(2) + ' in ' + ms + 'ms' + (seg.noPre ? ' (no preroll)' : '') + ' off=' + seg.off.toFixed(3) + ' delay=' + seg.delay.toFixed(3));
      S.stats.decoded++; S.bad = 0;
    }, function (e) {
      noteErr(e);
      dbg('decode-fail', seg.t0.toFixed(2) + ' mode=' + S.mode);
      if (S.stats.decoded === 0 && S.mode === 'adts') {
        // nothing decoded yet: after two refusals of raw AAC frames, try whole fMP4 chunks
        S.adtsFails = (S.adtsFails || 0) + 1;
        if (S.adtsFails >= 2) { S.mode = 'fmp4'; dbg('mode', 'raw AAC refused, switching to fmp4'); S.lastErr = 'adts refused, using fmp4: ' + S.lastErr; }
      } else {
        S.stats.failed++; S.bad++; seg.failed = true;
        if (S.bad >= 4) disable('decoding failed: ' + S.lastErr);
      }
    }).then(function () { seg.busy = false; S.decoding--; });
  }

  function decodeFmp4(seg) {
    var init = seg.init.u, f = seg.frag;
    var body = seg.u.subarray(f.start, f.end);
    var all = new Uint8Array(init.length + body.length);
    all.set(init, 0); all.set(body, init.length);
    return decodeAB(all.buffer).then(function (buf) {
      seg.buf = buf; seg.off = 0; seg.len = Math.min(seg.dur, buf.duration);
      seg.delay = 0; seg.noPre = true;
    });
  }

  // ---------------- playback ----------------
  function killNode(seg) {
    if (!seg.node) return;
    try {
      var c = S.ctx, t = c ? c.currentTime : 0;
      if (seg.gain) { seg.gain.gain.cancelScheduledValues(t); seg.gain.gain.setTargetAtTime(0, t, 0.004); }
      seg.node.stop(t + 0.03);
      var n = seg.node, g = seg.gain;
      setTimeout(function () { try { n.disconnect(); if (g) g.disconnect(); } catch (e) {} }, 80);
    } catch (e) {}
    seg.node = null; seg.gain = null;
  }

  function stopAll(why) {
    if (S.anchor) dbg('stop', why || '?');
    S.gen++;
    S.list.forEach(function (st) { st.segs.forEach(killNode); });
    S.anchor = null;
  }

  function disable(why) {
    S.disabled = why;
    dbg('DISABLED', why);
    stopAll('disabled');
    unmute();
  }

  function mute() {
    var v = S.elFn();
    if (!v) return;
    try { if (!S.muting) S.muting = true; if (!v.muted) { v.muted = true; dbg('mute', 'page sound muted'); } } catch (e) {}
  }
  function unmute() {
    var v = S.elFn();
    try { if (v && S.muting && v.muted) { v.muted = false; dbg('unmute', 'page sound restored'); } } catch (e) {}
    S.muting = false;
  }

  function schedule(seg, now) {
    var a = S.anchor, c = S.ctx;
    var when = a.c + (seg.t0 - a.m) + seg.delay;
    var off = seg.off, len = seg.len;
    var cur = now + 0.004;
    if (when < cur) {
      var skip = cur - when;
      if (skip >= len) { seg.node = null; seg.passed = true; return; }
      off += skip; len -= skip; when = cur;
    }
    var src = c.createBufferSource();
    src.buffer = seg.buf;
    var g = c.createGain();
    if (seg.noPre) {
      g.gain.setValueAtTime(0, when);
      g.gain.linearRampToValueAtTime(1, when + 0.012);
    }
    src.connect(g); g.connect(S.sink);
    src.start(when, off, len);
    seg.node = src; seg.gain = g; seg.gen = S.gen;
  }

  function mediaNow(now) {
    var a = S.anchor;
    return a ? a.m + (now - a.c) : 0;
  }

  function tick() {
    var c = S.ctx;
    if (!c || !S.sink) return;
    var v = S.elFn();
    if (!S.enabled || S.disabled || !v) {
      if (S.anchor) stopAll('tap disabled');
      unmute();
      return;
    }
    var playing = !v.paused && !v.ended && !v.seeking && v.readyState >= 2;
    var rate = v.playbackRate || 1;
    var wall = performance.now() / 1000;
    // main thread blocked or throttled? (a long gap between two ticks)
    if (S.lastTick) {
      var gap = Math.round((wall - S.lastTick) * 1000);
      if (gap > S.stats.maxTickGapMs) S.stats.maxTickGapMs = gap;
      if (gap > 600) dbg('tick-gap', gap + 'ms (page busy or throttled) visible=' + document.visibilityState);
    }
    S.lastTick = wall;
    // is the page's own clock stuck while it claims to play?
    if (playing) {
      if (Math.abs(v.currentTime - S.lastCT) > 0.01) {
        if (S.stalled) { dbg('stall-end', 'after ' + (wall - S.stalledAt).toFixed(1) + 's, t=' + v.currentTime.toFixed(2)); S.stalled = false; }
        S.lastCT = v.currentTime; S.lastCTWall = wall;
      } else if (!S.stalled && wall - S.lastCTWall > 1.5) {
        S.stalled = true; S.stalledAt = wall; S.stats.stalls++;
        var br = ''; try { for (var q = 0; q < v.buffered.length; q++) br += v.buffered.start(q).toFixed(1) + '-' + v.buffered.end(q).toFixed(1) + ' '; } catch (e) {}
        dbg('STALL', 'page clock frozen at ' + v.currentTime.toFixed(2) + ' readyState=' + v.readyState + ' network=' + v.networkState +
            ' muted=' + v.muted + ' buffered=[' + br.trim() + '] ctx=' + c.state + ' anchor=' + !!S.anchor + ' fallback=' + S.fallback);
      }
    } else { S.lastCT = -1; if (S.stalled) { S.stalled = false; } }

    if (!playing || Math.abs(rate - 1) > 0.001) {
      if (S.anchor) stopAll(!playing ? 'not playing (paused=' + v.paused + ' seeking=' + v.seeking + ' ready=' + v.readyState + ')' : 'rate ' + rate);
      if (Math.abs(rate - 1) > 0.001) unmute();
      return;
    }
    if (c.state !== 'running') { try { c.resume(); } catch (e) {} }

    var st = activeState(v);
    if (!st) return;

    var now = c.currentTime;
    var want = v.currentTime + S.offsetMs / 1000;
    if (!S.anchor) {
      S.anchor = { c: now + 0.08, m: want + 0.08 };
      S.stats.reanchors++;
      dbg('anchor', 'media ' + want.toFixed(2) + 's ctx=' + c.state + ' rate=' + c.sampleRate);
    } else {
      var drift = want - mediaNow(now);
      S.stats.driftMs = Math.round(drift * 1000);
      if (Math.abs(S.stats.driftMs) > S.stats.maxDriftMs) S.stats.maxDriftMs = Math.abs(S.stats.driftMs);
      if (Math.abs(drift) > DRIFT) {
        S.driftHits = (S.driftHits || 0) + 1;
        if (S.driftHits >= 3) { S.driftHits = 0; dbg('drift', 'output off by ' + S.stats.driftMs + 'ms, re-anchoring'); stopAll('drift'); return; }
      } else S.driftHits = 0;
    }

    var mn = mediaNow(now);
    // timers are throttled in the background: queue much more audio ahead then
    var look = document.visibilityState === 'hidden' ? 45 : LOOKAHEAD;
    var segs = st.segs, covered = false, i, g;
    var pending = [];
    for (i = 0; i < segs.length; i++) {
      g = segs[i];
      if (g.dead) continue;
      if (g.t1 < mn - KEEP_BEHIND) { if (g.buf && !g.node) g.buf = null; continue; }
      if (g.t0 > mn + look) break;
      if (g.t1 < mn - 0.05) continue;
      if (!g.buf) { if (!g.failed) pending.push(g); continue; }
      if (!g.node && !g.passed) schedule(g, now);
      // a suspended / interrupted context (call, Siri, route change) is not covering anything
      if (g.node && c.state === 'running' && g.t0 <= mn + 0.02 && g.t1 > mn) covered = true;
    }
    pending.sort(function (a, b) { return Math.abs(a.t0 - mn) - Math.abs(b.t0 - mn); });
    for (i = 0; i < pending.length; i++) decodeSeg(pending[i]);

    // mute the page's own sound while we cover it; give it back if we cannot
    if (S.fallback && wall - S.fallbackAt > 10) { S.fallback = false; dbg('fallback-off', 'retry after 10s'); }
    if (S.lastCover !== covered) {
      var nd = 0; segs.forEach(function (g) { if (g.buf) nd++; });
      dbg(covered ? 'covered' : 'UNCOVERED', 'media ' + mn.toFixed(2) + ' segs=' + segs.length + ' decoded=' + nd + ' pending=' + pending.length + ' decoding=' + S.decoding + ' ctx=' + c.state);
      S.lastCover = covered;
    }
    if (covered) {
      S.uncoveredSince = 0; S.coveredSince = S.coveredSince || wall;
      if (S.fallback && wall - S.coveredSince > 0.8) { S.fallback = false; dbg('fallback-off', 'tap covers the sound again'); }
      if (!S.fallback) mute();
    } else {
      S.coveredSince = 0;
      if (!S.fallback) mute();
      if (!S.uncoveredSince) { S.uncoveredSince = wall; S.uncoveredMedia = v.currentTime; }
      // only a real problem if the page's clock keeps running without us
      else if (wall - S.uncoveredSince > 2.0 && v.currentTime - S.uncoveredMedia > 1.0 && !S.fallback) {
        S.fallback = true; S.fallbackAt = wall; S.stats.fallbacks++; dbg('fallback-on', 'no tap audio for 2s while the page clock runs'); unmute();
      }
    }
  }

  // ---------------- events ----------------
  var watching = null;
  function watch() {
    var v = S.elFn();
    if (!v || v === watching) return;
    watching = v;
    ['seeking', 'seeked', 'waiting', 'pause', 'playing', 'play', 'ratechange',
     'emptied', 'loadstart', 'ended'].forEach(function (n) {
      v.addEventListener(n, function () {
        dbg('el:' + n, 't=' + v.currentTime.toFixed(2) + ' ready=' + v.readyState + ' paused=' + v.paused + ' muted=' + v.muted);
        if (S.anchor) stopAll('event ' + n);
        S.coveredSince = 0; S.uncoveredSince = 0;
        if (n === 'emptied' || n === 'loadstart') S.fallback = false;
      }, true);
    });
    v.addEventListener('volumechange', function () {
      if (S.muting && !v.muted && !S.fallback && S.enabled) { try { v.muted = true; } catch (e) {} }
    }, true);
  }

  setInterval(function () { try { watch(); tick(); } catch (e) { noteErr(e); } }, 100);

  // ---------------- API for webEqJs ----------------
  function statusText(short) {
    if (S.disabled) return 'tap off (' + S.disabled + ')';
    var head = 'tap ' + S.mode + (S.fallback ? ' [raw fallback]' : S.anchor ? ' [playing]' : ' [idle]');
    if (short) return head;
    var st = null, v = S.elFn();
    if (v) st = activeState(v);
    var n = st ? st.segs.length : 0, b = 0;
    if (st) st.segs.forEach(function (g) { if (g.buf) b++; });
    return head + ' | ' + n + ' segs, ' + b + ' decoded' +
        (S.stats.missedInit ? ' | missed init x' + S.stats.missedInit : '') +
        (S.stats.failed ? ' | decode fails ' + S.stats.failed : '');
  }

  window.__webTap = {
    attach: function (ctx, node) {
      if (S.ctx !== ctx) {
        stopAll('new context');
        try { ctx.addEventListener('statechange', function () { dbg('ctx', 'state ' + ctx.state); }); } catch (e) {}
        dbg('ctx', 'attached state=' + ctx.state + ' rate=' + ctx.sampleRate);
      }
      S.ctx = ctx; S.sink = node;
    },
    detach: function () { stopAll('detach'); unmute(); S.ctx = null; S.sink = null; },
    setEnabled: function (on) {
      on = !!on;
      if (S.enabled !== on) dbg('enabled', on ? 'tap turned on' : 'tap turned off');
      if (S.enabled && !on) { stopAll('turned off'); unmute(); }
      S.enabled = on;
      if (on && S.disabled && /decoding failed/.test(S.disabled)) S.disabled = '';
    },
    setOffset: function (ms) { S.offsetMs = +ms || 0; if (S.anchor) stopAll('offset'); },
    rate: function () {
      var v = S.elFn(), st = v ? activeState(v) : null;
      return st && st.init && st.init.audio ? st.init.audio.rate || 0 : 0;
    },
    seen: function () { return S.stats.appends > 0 && S.list.length > 0; },
    status: function (short) { return statusText(short); },
    log: function () { return S.log; },
    clearLog: function () { S.log.length = 0; },
    diag: function () {
      var v = S.elFn(), st = v ? activeState(v) : null;
      return {
        mode: S.mode, enabled: S.enabled, disabled: S.disabled, fallback: S.fallback,
        playing: !!S.anchor, muting: S.muting, stats: S.stats, lastError: S.lastErr,
        audioBuffers: S.list.length,
        codec: st && st.init ? st.init.audio.codec : null,
        asc: st && st.init && st.init.audio.ascInfo ? st.init.audio.ascInfo : null,
        segs: st ? st.segs.length : 0,
        decoded: st ? st.segs.filter(function (g) { return g.buf; }).length : 0,
        cachedMB: st ? Math.round(st.bytes / 1048576 * 10) / 10 : 0,
        range: st && st.segs.length ? [st.segs[0].t0, st.segs[st.segs.length - 1].t1] : null,
        ctx: S.ctx ? { state: S.ctx.state, rate: S.ctx.sampleRate } : null
      };
    },
    _t: { S: S, parseInit: parseInit, parseSegment: parseSegment, adts: adts,
          parseAsc: parseAsc, install: install, onAppend: onAppend, tick: tick,
          finishAdts: finishAdts }
  };

  install();
})();
