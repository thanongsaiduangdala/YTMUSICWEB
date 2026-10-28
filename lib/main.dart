import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt_explode;

import 'backup_zip.dart';

late final WebAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  audioHandler = await AudioService.init<WebAudioHandler>(
    builder: () => WebAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.ytmusicweb.channel.audio',
      androidNotificationChannelName: 'Music playback',
      androidNotificationOngoing: true,
    ),
  );
  runApp(const YtMusicApp());
}

class PlayerOptions extends ChangeNotifier {
  bool shuffle = false;
  int repeat = 1;

  VoidCallback? onShuffleChanged;

  Timer? _sleepTimer;
  DateTime? sleepAt;
  bool sleepAtSongEnd = false;
  String? armedSong;

  bool get sleepActive => sleepAt != null || sleepAtSongEnd;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      shuffle = p.getBool('shuffle') ?? false;
      final r = p.getInt('repeat') ?? 1;
      repeat = (r < 0 || r > 2) ? 1 : r;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('shuffle', shuffle);
      await p.setInt('repeat', repeat);
    } catch (_) {}
  }

  void setShuffle(bool on, {bool apply = true}) {
    shuffle = on;
    notifyListeners();
    _save();
    if (apply) onShuffleChanged?.call();
  }

  void cycleRepeat() {
    repeat = repeat == 1 ? 2 : (repeat == 2 ? 0 : 1);
    notifyListeners();
    _save();
  }

  void sleepIn(Duration d) {
    cancelSleep();
    sleepAt = DateTime.now().add(d);
    _sleepTimer = Timer(d, () {
      cancelSleep();
      audioHandler.pause();
    });
    notifyListeners();
  }

  void sleepAtEndOfSong() {
    cancelSleep();
    sleepAtSongEnd = true;
    final key = audioHandler.webSongKey;
    armedSong = (audioHandler.isLocal || key.isEmpty) ? null : key;
    notifyListeners();
  }

  void cancelSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepAt = null;
    sleepAtSongEnd = false;
    armedSong = null;
    notifyListeners();
  }

  bool consumeSleepAtEnd() {
    if (!sleepAtSongEnd) return false;
    cancelSleep();
    return true;
  }
}

final PlayerOptions playerOpts = PlayerOptions();

const double kMaxBoostDb = 12;

const List<double> kEqFreqs = [
  32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
];

class EqProfile {
  final String id, name, desc;
  final List<double> gains;
  final bool builtIn;
  const EqProfile(this.id, this.name, this.gains,
      {this.desc = '', this.builtIn = true});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'gains': gains};

  static EqProfile? fromJson(Map<String, dynamic> j) {
    final g = ((j['gains'] as List?) ?? const [])
        .whereType<num>()
        .map((n) => n.toDouble())
        .toList();
    final id = j['id'] as String?;
    if (id == null || g.length != kEqFreqs.length) return null;
    return EqProfile(id, (j['name'] as String?) ?? 'Profile', g,
        builtIn: false);
  }
}

class FxPreset {
  final String id, name;
  final double wide, bass, clarity, room;
  const FxPreset(this.id, this.name, this.wide, this.bass, this.clarity, this.room);
}

class EqSettings extends ChangeNotifier {
  bool enabled = false;
  String selectedId = 'flat';
  List<double> gains = List<double>.filled(kEqFreqs.length, 0);
  List<EqProfile> custom = [];

  double boostDb = 0;

  /// iPhone: stream through the re-rendering tap (webTapJs). Off by default.
  bool tapOn = false;

  double fxWide = 0, fxBass = 0, fxClarity = 0, fxRoom = 0;
  String fxId = 'off';
  Timer? _applyTimer;

  static const List<FxPreset> fxPresets = [
    FxPreset('off', 'Off', 0, 0, 0, 0),
    FxPreset('headphone', 'Headphone spatial', 0.55, 0.15, 0.2, 0.25),
    FxPreset('speaker', 'Speaker surround', 0.8, 0.3, 0.25, 0.1),
    FxPreset('cinema', 'Cinema surround', 0.75, 0.35, 0.3, 0.4),
    FxPreset('clearwide', 'Clear & wide', 0.5, 0.1, 0.5, 0),
    FxPreset('hall', 'Live hall', 0.4, 0.1, 0.1, 0.8),
    FxPreset('bassplus', 'Bass + wide', 0.45, 0.8, 0.1, 0),
    FxPreset('vocalfx', 'Vocal presence', 0.2, 0, 0.7, 0.15),
  ];

  static const List<EqProfile> builtIns = [
    EqProfile('flat', 'Flat / Reference',
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        desc: 'Every band at 0 dB: the recording exactly as it was made.'),
    EqProfile('rock', 'Rock',
        [4, 3, 1, -3, -3, 0, 3, 4, 3, 2],
        desc: 'Less muddy low-mids, more kick punch and guitar bite.'),
    EqProfile('metal', 'Metal',
        [3, 4, 2, -5, -4, -1, 3, 5, 4, 2],
        desc: 'Deeper scoop of the low-mids, sharp guitars and tight kick.'),
    EqProfile('hiphop', 'Hip-Hop / Rap',
        [8, 7, 4, 1, 0, -1, 1, 2, 4, 5],
        desc: 'Heavy sub-bass with crisp hi-hats.'),
    EqProfile('rnb', 'R&B / Soul',
        [5, 6, 4, 1, -1, 0, 1, 1, 2, 2],
        desc: 'Warm, round bass with smooth vocals.'),
    EqProfile('pop', 'Pop',
        [-1, 0, 2, 3, 3, 1, -1, -1, 0, 1],
        desc: 'Forward vocals with a little punch at the bottom.'),
    EqProfile('edm', 'Electronic / EDM',
        [7, 6, 3, 0, -2, -2, 0, 3, 5, 6],
        desc: 'Deep sub-bass shelf and bright synth highs (V-shape).'),
    EqProfile('dance', 'Dance / Club',
        [5, 5, 4, 3, 1, 0, 1, 2, 3, 3],
        desc: 'Strong kick and bass line with sparkle on top.'),
    EqProfile('vshape', 'V-Shape',
        [6, 5, 2, -1, -3, -3, -1, 2, 5, 6],
        desc: 'Boosted bass and treble, lowered mids: punchy and exciting.'),
    EqProfile('jazz', 'Jazz',
        [1, 2, 2, 1, 0, 0, 0, 1, 2, 2],
        desc: 'Gentle, smooth curve that keeps the warmth of live rooms.'),
    EqProfile('acoustic', 'Acoustic',
        [2, 2, 2, 1, 0, 0, 1, 2, 2, 1],
        desc: 'Natural wood and string tone without heavy colouring.'),
    EqProfile('classical', 'Classical',
        [2, 1, 0, 0, 0, 0, 0, 1, 2, 3],
        desc: 'Open and natural, with a touch of air for orchestras.'),
    EqProfile('country', 'Country',
        [2, 2, 1, 0, 1, 2, 3, 3, 2, 1],
        desc: 'Clear picking and vocals, warm low end.'),
    EqProfile('lounge', 'Lounge',
        [-3, -2, -1, 1, 2, 2, 1, 0, 1, 2],
        desc: 'Relaxed and smooth, light on bass.'),
    EqProfile('vocal', 'Vocal Enhancement',
        [-2, -2, -1, 0, 2, 4, 4, 3, 1, 0],
        desc: 'Lifts the mids and high-mids for clearer voices.'),
    EqProfile('spoken', 'Podcast / Spoken word',
        [-6, -5, -3, 0, 2, 4, 4, 2, 0, -2],
        desc: 'Cuts rumble and hiss so speech is easy to follow.'),
    EqProfile('bass', 'Bass Boost',
        [8, 8, 6, 2, 0, 0, 0, 0, 0, 0],
        desc: 'Adds low-end weight between about 20 and 125 Hz.'),
    EqProfile('deepbass', 'Deep Bass',
        [11, 9, 5, 1, 0, 0, 0, 0, 0, 0],
        desc: 'Very heavy sub-bass. Best on good headphones; turn the volume down.'),
    EqProfile('lessbass', 'Reduce Bass',
        [-8, -6, -3, -1, 0, 0, 0, 0, 0, 0],
        desc: 'Tames boomy tracks and bass-heavy speakers.'),
    EqProfile('treble', 'Treble Boost / Bright',
        [0, 0, 0, 0, 0, 0, 1, 3, 6, 7],
        desc: 'Adds air, sparkle and clarity above 5 kHz.'),
    EqProfile('night', 'Late Night',
        [-4, -3, -2, 0, 2, 3, 3, 2, 1, 0],
        desc: 'Less thump so low volume stays clear and neighbours happy.'),
    EqProfile('small', 'Small Speakers',
        [5, 5, 4, 2, 0, 0, 0, 1, 2, 2],
        desc: 'Makes up for the weak bass of a phone speaker.'),
  ];

  List<EqProfile> get all => [...builtIns, ...custom];

  EqProfile? get selected {
    for (final p in all) {
      if (p.id == selectedId) return p;
    }
    return null;
  }

  bool get modified {
    final p = selected;
    if (p == null) return true;
    for (var i = 0; i < gains.length; i++) {
      if ((p.gains[i] - gains[i]).abs() > 0.01) return true;
    }
    return false;
  }

  double gainAtHz(double hz) {
    final f = kEqFreqs;
    if (hz <= f.first) return gains.first;
    if (hz >= f.last) return gains.last;
    for (var i = 0; i < f.length - 1; i++) {
      if (hz <= f[i + 1]) {
        final t = (math.log(hz) - math.log(f[i])) /
            (math.log(f[i + 1]) - math.log(f[i]));
        return gains[i] + (gains[i + 1] - gains[i]) * t;
      }
    }
    return 0;
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool('eq_on') ?? false;
      tapOn = p.getBool('tap_on') ?? false;
      final b = p.getDouble('boost_db') ?? 0;
      boostDb = b.clamp(0.0, kMaxBoostDb).toDouble();
      selectedId = p.getString('eq_selected') ?? 'flat';
      fxId = p.getString('fx_id') ?? 'off';
      fxWide = (p.getDouble('fx_wide') ?? 0).clamp(0.0, 1.0).toDouble();
      fxBass = (p.getDouble('fx_bass') ?? 0).clamp(0.0, 1.0).toDouble();
      fxClarity = (p.getDouble('fx_clarity') ?? 0).clamp(0.0, 1.0).toDouble();
      fxRoom = (p.getDouble('fx_room') ?? 0).clamp(0.0, 1.0).toDouble();
      final cust = <EqProfile>[];
      for (final raw in p.getStringList('eq_custom') ?? <String>[]) {
        try {
          final c = EqProfile.fromJson(
              Map<String, dynamic>.from(jsonDecode(raw) as Map));
          if (c != null) cust.add(c);
        } catch (_) {}
      }
      custom = cust;
      final g = (jsonDecode(p.getString('eq_gains') ?? '[]') as List)
          .whereType<num>()
          .map((n) => n.toDouble())
          .toList();
      if (g.length == kEqFreqs.length) {
        gains = g;
      } else {
        gains = List.of(selected?.gains ?? builtIns.first.gains);
      }
      notifyListeners();
      audioHandler.pushWebEq();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('eq_on', enabled);
      await p.setBool('tap_on', tapOn);
      await p.setDouble('boost_db', boostDb);
      await p.setString('eq_selected', selectedId);
      await p.setString('fx_id', fxId);
      await p.setDouble('fx_wide', fxWide);
      await p.setDouble('fx_bass', fxBass);
      await p.setDouble('fx_clarity', fxClarity);
      await p.setDouble('fx_room', fxRoom);
      await p.setString('eq_gains', jsonEncode(gains));
      await p.setStringList(
          'eq_custom', custom.map((c) => jsonEncode(c.toJson())).toList());
    } catch (_) {}
  }

  void _changed() {
    notifyListeners();
    _save();

    _applyTimer?.cancel();
    _applyTimer =
        Timer(const Duration(milliseconds: 80), () => audioHandler.applyEq());
  }

  void refresh() => notifyListeners();

  void setEnabled(bool on) {
    enabled = on;
    _changed();
  }

  void setTapOn(bool on) {
    tapOn = on;
    _changed();
  }

  bool get fxOn => fxWide > 0 || fxBass > 0 || fxClarity > 0 || fxRoom > 0;

  void selectFx(FxPreset f) {
    fxId = f.id;
    fxWide = f.wide;
    fxBass = f.bass;
    fxClarity = f.clarity;
    fxRoom = f.room;
    _changed();
  }

  void setFx({double? wide, double? bass, double? clarity, double? room}) {
    if (wide != null) fxWide = wide;
    if (bass != null) fxBass = bass;
    if (clarity != null) fxClarity = clarity;
    if (room != null) fxRoom = room;
    fxId = fxOn ? 'custom' : 'off';
    _changed();
  }

  double clarityDbAt(double hz) {
    if (fxClarity <= 0) return 0;
    if (hz < 1500) return 0;
    if (hz < 4000) return fxClarity * 3;
    return fxClarity * 6;
  }

  void setBoost(double db) {
    boostDb = db.clamp(0.0, kMaxBoostDb).toDouble();
    _changed();
  }

  void select(EqProfile p) {
    selectedId = p.id;
    gains = List.of(p.gains);
    enabled = true;
    _changed();
  }

  void setGain(int i, double v) {
    gains = List.of(gains)..[i] = v;
    enabled = true;
    _changed();
  }

  void saveAs(String name) {
    final c = EqProfile('c${DateTime.now().microsecondsSinceEpoch}',
        name.trim().isEmpty ? 'My profile' : name.trim(), List.of(gains),
        builtIn: false);
    custom = [...custom, c];
    selectedId = c.id;
    _changed();
  }

  void updateSelected() {
    final p = selected;
    if (p == null || p.builtIn) return;
    custom = [
      for (final c in custom)
        c.id == p.id ? EqProfile(c.id, c.name, List.of(gains), builtIn: false) : c
    ];
    _changed();
  }

  void deleteCustom(String id) {
    custom = custom.where((c) => c.id != id).toList();
    if (selectedId == id) {
      selectedId = 'flat';
      gains = List.of(builtIns.first.gains);
    }
    _changed();
  }
}

final EqSettings eqState = EqSettings();

class IosFxEngine {
  static const MethodChannel _ch = MethodChannel('ytmusicweb/fxplayer');
  final _changes = StreamController<void>.broadcast();
  final _states = StreamController<ProcessingState>.broadcast();

  bool playing = false;
  ProcessingState state = ProcessingState.idle;
  Duration? duration;
  Duration _pos = Duration.zero;
  DateTime _stamp = DateTime.now();

  IosFxEngine() {
    _ch.setMethodCallHandler(_onNative);
  }

  Stream<void> get changes => _changes.stream;
  Stream<ProcessingState> get processingStates => _states.stream;

  Duration get position {
    if (!playing) return _pos;
    final p = _pos + DateTime.now().difference(_stamp);
    final d = duration;
    return (d != null && p > d) ? d : p;
  }

  void _take(Map<String, dynamic>? r) {
    if (r == null) return;
    final p = r['pos'];
    if (p is num) {
      _pos = Duration(milliseconds: (p * 1000).round());
      _stamp = DateTime.now();
    }
    final d = r['dur'];
    if (d is num) duration = Duration(milliseconds: (d * 1000).round());
  }

  Future<dynamic> _onNative(MethodCall c) async {
    if (c.method != 'event' || c.arguments is! Map) return null;
    final m = Map<String, dynamic>.from(c.arguments as Map);
    _take(m);
    switch (m['type']) {
      case 'completed':
        playing = false;
        state = ProcessingState.completed;
        _changes.add(null);
        _states.add(state);
        break;
      case 'paused':
        playing = false;
        _changes.add(null);
        break;
    }
    return null;
  }

  Future<Duration?> load(String path) async {
    playing = false;
    state = ProcessingState.loading;
    _pos = Duration.zero;
    duration = null;
    _changes.add(null);
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('load', {'path': path});
      _take(r);
      state = ProcessingState.ready;
      _changes.add(null);
      return duration;
    } catch (_) {
      state = ProcessingState.idle;
      _changes.add(null);
      rethrow;
    }
  }

  Future<void> play() async {
    _take(await _ch.invokeMapMethod<String, dynamic>('play'));
    playing = true;
    state = ProcessingState.ready;
    _changes.add(null);
  }

  Future<void> pause() async {
    playing = false;
    _take(await _ch.invokeMapMethod<String, dynamic>('pause'));
    _changes.add(null);
  }

  Future<void> seek(Duration d) async {
    _take(await _ch.invokeMapMethod<String, dynamic>(
        'seek', {'seconds': d.inMilliseconds / 1000}));
    _changes.add(null);
  }

  Future<void> stop() async {
    playing = false;
    state = ProcessingState.idle;
    _pos = Duration.zero;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    _changes.add(null);
  }

  Future<void> applyFx(Map<String, dynamic> fx) => _ch.invokeMethod('fx', fx);
}

class WebAudioHandler extends BaseAudioHandler {

  Future<void> Function()? resetPageSession;

  Future<void> Function(String js)? runJs;

  Future<Object> Function(String js)? runJsResult;
  String _lastKey = '';

  Future<void> _js(String code) async => runJs?.call(code);

  final AndroidEqualizer equalizer = AndroidEqualizer();

  final AndroidLoudnessEnhancer loudness = AndroidLoudnessEnhancer();
  late final AudioPlayer _player = AudioPlayer(
      audioPipeline:
          AudioPipeline(androidAudioEffects: [equalizer, loudness]));
  bool eqReady = false;
  bool? eqWorks;
  bool? boostWorks;
  static const MethodChannel _fx = MethodChannel('ytmusicweb/fx');
  Map<String, dynamic> fxNative = {};

  String webEqStatus = '';
  bool _local = false;

  Future<void> Function()? localNext, localPrev;

  Future<void> Function()? localEnded;

  bool get isLocal => _local;

  String webSongKey = '';

  VoidCallback? localStopped;

  late final IosFxEngine _ios = IosFxEngine();

  bool get _lPlaying => Platform.isIOS ? _ios.playing : _player.playing;
  Duration get _lPos => Platform.isIOS ? _ios.position : _player.position;
  ProcessingState get _lProc =>
      Platform.isIOS ? _ios.state : _player.processingState;
  Duration get _lBuffered => Platform.isIOS
      ? (_ios.duration ?? _ios.position)
      : _player.bufferedPosition;
  double get _lSpeed => Platform.isIOS ? 1.0 : _player.speed;
  Future<void> _lStop() => Platform.isIOS ? _ios.stop() : _player.stop();
  Future<void> _lPause() => Platform.isIOS ? _ios.pause() : _player.pause();
  Future<void> _lPlay() => Platform.isIOS ? _ios.play() : _player.play();
  Future<void> _lSeek(Duration d) =>
      Platform.isIOS ? _ios.seek(d) : _player.seek(d);

  void _onLocalCompleted() {
    if (!_local) return;
    if (playerOpts.consumeSleepAtEnd()) {

      _lPause();
      return;
    }
    (localEnded ?? localNext)?.call();
  }

  WebAudioHandler() {
    if (Platform.isIOS) {
      _ios.changes.listen((_) {
        if (_local) _broadcastLocal();
      });
      _ios.processingStates.listen((s) {
        if (s == ProcessingState.completed) _onLocalCompleted();
      });
    } else {
      _player.playbackEventStream.listen((_) {
        if (_local) _broadcastLocal();
      }, onError: (_) {});
      _player.processingStateStream.listen((s) {
        if (s == ProcessingState.completed) _onLocalCompleted();
      });
    }
  }

  static const gvHookJs = r'''
(function () {
  if (window.__gv) return;
  var log = [];
  window.__gv = { log: log, audio: null };
  // Ask the page for AAC (MP4) audio instead of Opus (WebM): iPhone cannot play Opus.
  function noOpus(t) {
    t = String(t || '').toLowerCase();
    return t.indexOf('opus') >= 0 || t.indexOf('audio/webm') >= 0;
  }
  try {
    ['MediaSource', 'ManagedMediaSource'].forEach(function (n) {
      var C = window[n];
      if (!C || !C.isTypeSupported) return;
      var f = C.isTypeSupported.bind(C);
      C.isTypeSupported = function (t) { return noOpus(t) ? false : f(t); };
    });
    var cp = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function (t) {
      return noOpus(t) ? '' : cp.call(this, t);
    };
  } catch (e) {}
  function curVid() {
    try {
      var pl = document.getElementById('movie_player');
      return pl && pl.getVideoData ? (pl.getVideoData().video_id || '') : '';
    } catch (e) { return ''; }
  }
  function bodyInfo(body) {
    var len = 0, b64 = '';
    try {
      var u8 = null;
      if (body instanceof ArrayBuffer) u8 = new Uint8Array(body);
      else if (body && ArrayBuffer.isView(body)) u8 = new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
      if (u8) {
        len = u8.length;
        if (len <= 256) { var s = ''; for (var i = 0; i < len; i++) s += String.fromCharCode(u8[i]); b64 = btoa(s); }
      } else if (typeof body === 'string') {
        len = body.length;
        if (len <= 256) b64 = btoa(unescape(encodeURIComponent(body)));
      }
    } catch (e) {}
    return { len: len, b64: b64 };
  }
  function note(kind, method, url, body) {
    try {
      if (!/googlevideo\.com\/videoplayback/.test(url)) return;
      var u = new URL(url, location.href), p = u.searchParams;
      var mime = p.get('mime') || '';
      var bi = bodyInfo(body);
      method = String(method || 'GET').toUpperCase();
      log.push({ kind: kind, method: method, mime: mime, itag: p.get('itag'),
                 pot: p.has('pot'), sabr: p.has('sabr'), ump: p.has('ump'),
                 range: p.get('range'), clen: p.get('clen'), bodyLen: bi.len });
      if (log.length > 30) log.shift();
      if (mime.indexOf('audio') === 0 && !p.has('sabr')) {
        window.__gv.audio = { url: u.href, mime: mime, itag: p.get('itag'),
                              clen: p.get('clen'), vid: curVid(), method: method,
                              ump: p.has('ump'), body: bi.b64, bodyLen: bi.len };
      }
    } catch (e) {}
  }
  var of = window.fetch;
  if (of) {
    window.fetch = function (input, init) {
      try {
        var url = typeof input === 'string' ? input : (input && input.url);
        var m = (init && init.method) || (input && input.method) || 'GET';
        note('fetch', m, String(url), init && init.body);
      } catch (e) {}
      return of.apply(this, arguments);
    };
  }
  var ox = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) {
    this.__gm = m; this.__gu = u;
    return ox.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (b) {
    try { note('xhr', this.__gm, String(this.__gu), b); } catch (e) {}
    return os.apply(this, arguments);
  };
  window.__gvDiag = function () {
    var a = window.__gv.audio;
    return JSON.stringify({
      hookInstalled: true,
      playingVideo: curVid(),
      audioLinkCaptured: !!a,
      audio: a ? { method: a.method, itag: a.itag, mime: a.mime, bytes: a.clen,
                   video: a.vid, ump: a.ump, bodyLen: a.bodyLen,
                   hasPot: /[?&]pot=/.test(a.url) } : null,
      lastRequests: log.slice(-6)
    });
  };
})();
''';

  /// Streaming tap (iPhone): copies the audio segments the page feeds to its
  /// media buffer, decodes them and plays them through the effects chain of
  /// [webEqJs] while the page's own sound is muted. Must be installed as early
  /// as possible, before the page creates its media source.
  static const webTapJs = r'''
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
''';

  static const webEqJs = r'''
(function () {
  if (window.__webEq) return;
  var FREQS = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  var ctx = null, filters = [], failed = false;
  var bassF, clarF, presF, side, wet, boost, limiter, probe, tapIn;
  var rateTried = {};
  var lastStatus = '';
  var hookError = '';
  function report(extra) {
    var st;
    if (failed) st = 'unsupported';
    else if (!ctx) st = wanted() ? 'starting' : 'idle';
    else if (hookError) st = 'hook-failed: ' + hookError;
    else st = ctx.state;
    if (tapMode()) {
      try { st += ' | ' + window.__webTap.status(true); } catch (e) { st += ' | tap error'; }
    } else {
      var v = document.querySelector('video, audio');
      st += v ? (v.__eqHooked ? ' | video hooked' : ' | video not hooked yet') : ' | no video';
    }
    if (extra) st += ' | ' + extra;
    if (st === lastStatus) return;
    lastStatus = st;
    try { if (window.EqStatus) EqStatus.postMessage(st); } catch (e) {}
  }
  function resumeCtx() {
    if (!ctx || ctx.state === 'running') return;
    try {
      var r = ctx.resume();
      if (r && r.then) r.then(function () { report(); }, function () { report('resume refused'); });
    } catch (e) {}
  }

  function cfg() {
    return window.__webEqCfg || { on: false, gains: [], boost: 0, fx: {} };
  }
  // iPhone: the page's media element cannot feed the chain directly, so the
  // audio is re-rendered from the segments captured by webTapJs instead.
  function tapMode() { return cfg().tap === true && !!window.__webTap; }
  function wanted() {
    var c = cfg(), f = c.fx || {};
    if (c.off) return false;  // the streaming tap is switched off in the settings
    return !!c.on || (c.boost || 0) > 0 ||
        (f.wide || 0) > 0 || (f.bass || 0) > 0 || (f.clarity || 0) > 0 || (f.room || 0) > 0;
  }
  function biquad(type, freq, q) {
    var f = ctx.createBiquadFilter();
    f.type = type; f.frequency.value = freq; f.Q.value = q; f.gain.value = 0;
    return f;
  }
  function gain(v) { var g = ctx.createGain(); g.gain.value = v; return g; }
  function impulse() {
    var sr = ctx.sampleRate, len = Math.floor(sr * 1.8);
    var b = ctx.createBuffer(2, len, sr);
    for (var ch = 0; ch < 2; ch++) {
      var d = b.getChannelData(ch);
      for (var i = 0; i < len; i++) {
        d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3);
      }
    }
    return b;
  }
  function ensureChain() {
    if (ctx) return true;
    if (failed) return false;
    try {
      var AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) { failed = true; return false; }
      var sr = 0;
      if (tapMode()) { try { sr = window.__webTap.rate() || 44100; } catch (e) { sr = 44100; } }
      try { ctx = sr ? new AC({ sampleRate: sr }) : new AC(); } catch (e) { ctx = new AC(); }
      probe = ctx.createAnalyser();  // only listens: shows if sound reaches the chain
      probe.fftSize = 512;
      // 10-band equaliser
      for (var i = 0; i < FREQS.length; i++) {
        var f = biquad(i === 0 ? 'lowshelf' : (i === FREQS.length - 1 ? 'highshelf' : 'peaking'),
                       FREQS[i], 1.1);
        if (i > 0) filters[i - 1].connect(f);
        filters.push(f);
      }
      // bass enhancer + clarity
      bassF = biquad('lowshelf', 90, 0.8);
      clarF = biquad('highshelf', 5000, 0.8);
      presF = biquad('peaking', 3000, 1);
      filters[filters.length - 1].connect(bassF);
      bassF.connect(clarF);
      clarF.connect(presF);
      // stereo widener (mid / side). side gain 1 = untouched.
      var split = ctx.createChannelSplitter(2), merge = ctx.createChannelMerger(2);
      var lm = gain(0.5), rm = gain(0.5), ls = gain(0.5), rs = gain(-0.5);
      var mid = gain(1), inv = gain(-1);
      side = gain(1);
      presF.connect(split);
      split.connect(lm, 0); split.connect(ls, 0);
      split.connect(rm, 1); split.connect(rs, 1);
      lm.connect(mid); rm.connect(mid);
      ls.connect(side); rs.connect(side);
      side.connect(inv);
      mid.connect(merge, 0, 0); side.connect(merge, 0, 0);
      mid.connect(merge, 0, 1); inv.connect(merge, 0, 1);
      // room (reverb), mixed in beside the dry sound
      var conv = ctx.createConvolver();
      conv.buffer = impulse();
      wet = gain(0);
      boost = gain(1);
      merge.connect(boost);
      merge.connect(conv); conv.connect(wet); wet.connect(boost);
      // limiter, so boosting never distorts
      limiter = ctx.createDynamicsCompressor();
      limiter.threshold.value = -3;
      limiter.knee.value = 0;
      limiter.ratio.value = 20;
      limiter.attack.value = 0.003;
      limiter.release.value = 0.1;
      boost.connect(limiter);
      limiter.connect(ctx.destination);
      // entry point of the chain for the streaming tap
      tapIn = gain(1);
      tapIn.connect(filters[0]);
      tapIn.connect(probe);
      if (tapMode()) window.__webTap.attach(ctx, tapIn);
      return true;
    } catch (e) { failed = true; ctx = null; hookError = String(e && e.message || e); return false; }
  }
  // The tap decodes at the stream's own sample rate (no resampling per segment).
  function syncTap() {
    if (!ctx || !tapMode()) return;
    var r = 0;
    try { r = window.__webTap.rate(); } catch (e) {}
    if (r && Math.abs(ctx.sampleRate - r) > 1 && !rateTried[r]) {
      rateTried[r] = true;  // never rebuild twice for a rate the device refuses
      try { window.__webTap.detach(); ctx.close(); } catch (e) {}
      ctx = null; filters = [];
      if (!ensureChain()) return;
    }
    try {
      window.__webTap.attach(ctx, tapIn);
      window.__webTap.setEnabled(wanted());
    } catch (e) {}
  }
  function hook() {
    if (tapMode()) return;
    var v = document.querySelector('video, audio');
    if (!v || v.__eqHooked || !ensureChain()) return;
    try {
      var src = ctx.createMediaElementSource(v);
      src.connect(filters[0]);
      src.connect(probe);
      v.__eqHooked = true;
    } catch (e) { v.__eqHooked = true; hookError = String(e && e.message || e); }
  }
  function apply() {
    if (!ctx && !wanted()) return;
    if (!ensureChain()) return;
    var c = cfg(), fx = c.fx || {};
    for (var i = 0; i < filters.length; i++) {
      filters[i].gain.value =
          c.on && c.gains && typeof c.gains[i] === 'number' ? c.gains[i] : 0;
    }
    bassF.gain.value = (fx.bass || 0) * 9;
    clarF.gain.value = (fx.clarity || 0) * 6;
    presF.gain.value = (fx.clarity || 0) * 3;
    side.gain.value = 1 + (fx.wide || 0) * 1.4;
    wet.gain.value = (fx.room || 0) * 0.45;
    boost.gain.value = Math.pow(10, Math.max(0, c.boost || 0) / 20);
    hook();
    syncTap();
    resumeCtx();
    report();
  }
  setInterval(function () {
    if (!ctx) { if (wanted()) apply(); report(); return; }
    hook();
    syncTap();
    resumeCtx();
    report();
  }, 1500);
  // iPhone only starts audio effects after a touch on the page.
  ['touchstart', 'touchend', 'click', 'pointerup'].forEach(function (t) {
    document.addEventListener(t, function () {
      if (!ctx && wanted()) apply(); else resumeCtx();
    }, true);
  });
  document.addEventListener('play', function () {
    if (ctx) { hook(); resumeCtx(); }
    else if (wanted()) apply();
  }, true);
  function level() {
    if (!probe) return -1;
    try {
      var a = new Uint8Array(probe.fftSize), m = 0;
      probe.getByteTimeDomainData(a);
      for (var i = 0; i < a.length; i++) { var d = Math.abs(a[i] - 128); if (d > m) m = d; }
      return m;  // 0 = silence reaches the chain, up to 128 = loud
    } catch (e) { return -2; }
  }
  window.__webEqDiag = function () {
    var v = document.querySelector('video, audio');
    var src = '';
    try { src = v ? (v.currentSrc || v.src || '') : ''; } catch (e) {}
    return JSON.stringify({
      scriptInstalled: true,
      audioContext: !!(window.AudioContext || window.webkitAudioContext),
      mediaSourceApi: !!window.MediaSource,
      managedMediaSource: !!window.ManagedMediaSource,
      ctxState: ctx ? ctx.state : 'not created',
      chainFailed: failed,
      hookError: hookError,
      element: v ? v.tagName : 'none',
      elementHooked: v ? !!v.__eqHooked : false,
      playing: v ? !v.paused : false,
      signal: level(),
      muted: v ? v.muted : null,
      srcKind: src.split(':')[0] + (/m3u8/.test(src) ? ' (HLS)' : ''),
      wanted: wanted(),
      tapMode: tapMode(),
      tap: window.__webTap ? window.__webTap.diag() : 'tap script not installed',
      config: window.__webEqCfg || null
    });
  };
  window.__webEq = { apply: apply };
  apply();
})();
''';

  void pushWebEq() {
    final code = 'window.__webEqCfg=${jsonEncode({
          'tap': Platform.isIOS,
          'off': Platform.isIOS && !eqState.tapOn,
          'on': eqState.enabled,
          'gains': eqState.gains,
          'boost': eqState.boostDb,
          'fx': {
            'wide': eqState.fxWide,
            'bass': eqState.fxBass,
            'clarity': eqState.fxClarity,
            'room': eqState.fxRoom,
          },
        })};if(window.__webEq)window.__webEq.apply();';
    _js(code);
  }

  static const _pauseWebJs =
      "var v=document.querySelector('video');if(v){v.pause();}";

  Future<void> playLocal({
    required String path,
    required String title,
    String? artist,
    String? artPath,
    Duration? startAt,
  }) async {
    await _js(_pauseWebJs);
    _local = true;
    _lastKey = '';
    final item = MediaItem(
      id: path,
      title: title,
      artist: (artist == null || artist.isEmpty) ? null : artist,
      artUri: artPath == null ? null : Uri.file(artPath),
    );
    mediaItem.add(item);
    final Duration? d =
        Platform.isIOS ? await _ios.load(path) : await _player.setFilePath(path);
    eqReady = true;

    await applyEq().timeout(const Duration(seconds: 2), onTimeout: () {});
    mediaItem.add(item.copyWith(duration: d));
    if (startAt != null &&
        startAt > Duration.zero &&
        (d == null || startAt < d)) {
      await _lSeek(startAt);
    }
    _lPlay();
  }

  Future<void> applyEq() async {
    pushWebEq();
    if (!eqReady) return;
    if (Platform.isIOS) {

      try {
        await _ios.applyFx({
          'on': eqState.enabled,
          'gains': eqState.gains,
          'boost': eqState.boostDb,
          'wide': eqState.fxWide,
          'bass': eqState.fxBass,
          'clarity': eqState.fxClarity,
          'room': eqState.fxRoom,
        });
        eqWorks = true;
        boostWorks = true;
        fxNative = {'virtualizer': true, 'bass': true, 'reverb': true};
      } catch (_) {
        eqWorks = false;
      }
      eqState.refresh();
      return;
    }
    try {
      final useEq = eqState.enabled || eqState.fxClarity > 0;
      await equalizer.setEnabled(useEq);
      if (useEq) {
        final params = await equalizer.parameters;
        for (final b in params.bands) {
          final g = (eqState.enabled ? eqState.gainAtHz(b.centerFrequency) : 0) +
              eqState.clarityDbAt(b.centerFrequency);
          await b.setGain(
              g.clamp(params.minDecibels, params.maxDecibels).toDouble());
        }
      }
      eqWorks = true;
    } catch (_) {
      eqWorks = false;
    }

    try {
      await loudness.setEnabled(eqState.boostDb > 0);
      if (eqState.boostDb > 0) await loudness.setTargetGain(eqState.boostDb);
      boostWorks = true;
    } catch (_) {
      boostWorks = false;
    }

    try {
      final id = _player.androidAudioSessionId;
      if (id != null) {
        final r = await _fx.invokeMethod('apply', {
          'session': id,
          'wide': eqState.fxWide,
          'bass': eqState.fxBass,
          'room': eqState.fxRoom,
        });
        if (r is Map) fxNative = Map<String, dynamic>.from(r);
      }
    } catch (_) {}
    eqState.refresh();
  }

  Future<void> stopLocal() async {
    if (!_local) return;
    _local = false;
    _lastKey = '';
    await _lStop();

    mediaItem.add(null);
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    localStopped?.call();
  }

  Future<void> releaseLocal() async {
    if (!_local) return;
    _local = false;
    _lastKey = '';
    await _lStop();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  void _broadcastLocal() {
    final playing = _lPlaying;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_lProc]!,
      playing: playing,
      updatePosition: _lPos,
      bufferedPosition: _lBuffered,
      speed: _lSpeed,
    ));
  }

  @override
  Future<void> play() => _local
      ? _lPlay()
      : _js("var v=document.querySelector('video');if(v){v.play();}");

  @override
  Future<void> pause() => _local ? _lPause() : _js(_pauseWebJs);

  @override
  Future<void> skipToNext() async {
    if (_local) {
      await localNext?.call();
      return;
    }
    await _js(
        "var b=document.querySelector('ytmusic-player-bar .next-button');if(b){b.click();}");
  }

  @override
  Future<void> skipToPrevious() async {
    if (_local) {
      await localPrev?.call();
      return;
    }
    await _js(
        "var b=document.querySelector('ytmusic-player-bar .previous-button');if(b){b.click();}");
  }

  @override
  Future<void> seek(Duration position) => _local
      ? _lSeek(position)
      : _js(
          "var v=document.querySelector('video');if(v){v.currentTime=${position.inMilliseconds / 1000};}");

  @override
  Future<void> stop() async {
    if (_local) {
      await stopLocal();
    } else {
      await pause();
    }
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    await super.stop();
  }

  void onWebState(Map<String, dynamic> d) {
    if (_local) {

      if (d['playing'] != true) return;
      _local = false;
      _lStop();
      _lastKey = '';
      localStopped?.call();
    }
    final title = (d['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) return;
    final artist = (d['artist'] as String?)?.trim() ?? '';
    final songKey = '$title|$artist';
    if (playerOpts.sleepAtSongEnd &&
        playerOpts.armedSong != null &&
        songKey != playerOpts.armedSong) {

      playerOpts.cancelSleep();
      _js(_pauseWebJs);
    }
    webSongKey = songKey;
    final album = (d['album'] as String?)?.trim() ?? '';
    final art = (d['art'] as String?) ?? '';
    final dur = ((d['dur'] as num?) ?? 0).toDouble();
    final pos = ((d['pos'] as num?) ?? 0).toDouble();
    final playing = d['playing'] == true;

    final key = '$title|$artist|$art|${dur.round()}';
    if (key != _lastKey) {
      _lastKey = key;
      mediaItem.add(MediaItem(
        id: key,
        title: title,
        artist: artist.isEmpty ? null : artist,
        album: album.isEmpty ? null : album,
        artUri: art.startsWith('http') ? Uri.tryParse(art) : null,
        duration: dur > 0 ? Duration(milliseconds: (dur * 1000).round()) : null,
      ));
    }

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: playing,
      updatePosition: Duration(milliseconds: (pos * 1000).round()),
      speed: playing ? 1.0 : 0.0,
    ));
  }
}

class YtMusicApp extends StatelessWidget {
  const YtMusicApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: const YtMusicPage(),
      );
}

class YtMusicPage extends StatefulWidget {
  const YtMusicPage({super.key});

  @override
  State<YtMusicPage> createState() => _YtMusicPageState();
}

class _YtMusicPageState extends State<YtMusicPage> with WidgetsBindingObserver {
  late final WebViewController _controller;
  bool _wasPlaying = false;
  bool _playerOpen = false;

  Map<String, dynamic> _now = {};
  String _nowVid = '';
  List<SavedSong> _saved = [];

  List<LocalSong> _localSongs = [];
  int _localIdx = -1;
  List<LocalSong>? _queue;
  List<LocalSong>? _queueOrig;

  List<PlaylistFolder> _playlists = [];

  final ValueNotifier<int> _libTick = ValueNotifier<int>(0);
  void _touch() => _libTick.value++;

  bool _downloading = false;
  double? _dlProgress;

  final DownloadManager _dl = DownloadManager();

  static const MethodChannel _ytdlp = MethodChannel('ytmusicweb/ytdlp');
  DownloadTask? _activeTask;
  String? _playlistUrl;
  String? _activeId;
  bool _batchCancel = false;

  bool _queueRunning = false;
  bool _readingPlaylist = false;
  PendingSong? _activeSong;
  bool _skipCurrent = false;
  DateTime _lastNative = DateTime.now();
  int _lastLogStep = -1;
  bool _ytdlpChecked = false;

  String? _shadowVid;

  String? _resumeVid;
  bool _wantWebPlay = false;
  bool _offlineBusy = false;

  bool _preferOffline = true;

  int _sortMode = 0;
  final Map<String, int> _addedCache = {};

  Map<String, int> _lastPlayed = {};

  bool _wifiOnly = false;

  bool _retryAsk = true;
  bool _retryAuto = false;
  final List<_FailedSong> _failedRound = [];
  bool _retryPromptOpen = false;
  int _autoRound = 0;
  static const int _autoRoundsMax = 5;

  bool _resetWarmOnSession = true;

  String _quality = 'high';

  final Map<String, int> _retries = {};
  final Map<String, String> _resumeIds = {};
  String? _lastAttemptId;
  DateTime _shadowStarted = DateTime.fromMillisecondsSinceEpoch(0);

  static final _vidRe = RegExp(r'^\d+_([A-Za-z0-9_-]{11})\.[A-Za-z0-9]+$');

  bool _smartOn = false;
  int _smartLimit = 5;
  String _smartDay = '';
  int _smartCount = 0;
  Map<String, List<int>> _plays = {};
  final List<Map<String, String>> _smartQueue = [];
  final Set<String> _smartSeen = {};
  bool _smartBusy = false;
  Timer? _smartTimer;
  String _trackVid = '';
  double _trackSecs = 0;
  double _trackPos = 0;
  bool _trackCounted = false;
  bool _trackWasPlaying = false;
  DateTime _trackAt = DateTime.now();

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  Future<void> _loadSmart() async {
    final prefs = await SharedPreferences.getInstance();
    final plays = <String, List<int>>{};
    try {
      final raw = jsonDecode(prefs.getString('smart_plays') ?? '{}');
      if (raw is Map) {
        raw.forEach((k, v) {
          if (v is List) {
            plays[k as String] =
                v.whereType<num>().map((n) => n.toInt()).toList();
          }
        });
      }
    } catch (_) {}
    final queue = <Map<String, String>>[];
    for (final s in prefs.getStringList('smart_queue') ?? <String>[]) {
      try {
        final m = Map<String, dynamic>.from(jsonDecode(s) as Map);
        queue.add(m.map((k, v) => MapEntry(k, v.toString())));
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _smartOn = prefs.getBool('smart_on') ?? false;
      _preferOffline = prefs.getBool('prefer_offline') ?? true;
      _wifiOnly = prefs.getBool('wifi_only') ?? false;
      _retryAsk = prefs.getBool('retry_ask') ?? true;
      _retryAuto = prefs.getBool('retry_auto') ?? false;
      _resetWarmOnSession = prefs.getBool('reset_warm_on_session') ?? true;
      final q = prefs.getString('dl_quality') ?? 'high';
      _quality = (q == 'medium' || q == 'small') ? q : 'high';
      _sortMode = (prefs.getInt('sort_mode') ?? 0).clamp(0, 3) as int;
      _smartLimit = ((prefs.getInt('smart_limit') ?? 5).clamp(1, 50)) as int;
      _smartDay = prefs.getString('smart_day') ?? '';
      _smartCount = prefs.getInt('smart_count') ?? 0;
      _plays = plays;
      _smartQueue
        ..clear()
        ..addAll(queue);
      _smartSeen
        ..clear()
        ..addAll(prefs.getStringList('smart_seen') ?? <String>[]);
    });
    _syncLocalVids();
    _smartKick();
  }

  Future<void> _persistSmart() async {
    _touch();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('smart_on', _smartOn);
    await prefs.setInt('smart_limit', _smartLimit);
    await prefs.setString('smart_day', _smartDay);
    await prefs.setInt('smart_count', _smartCount);
    await prefs.setString('smart_plays', jsonEncode(_plays));
    await prefs.setStringList(
        'smart_queue', _smartQueue.map((q) => jsonEncode(q)).toList());
    await prefs.setStringList('smart_seen', _smartSeen.toList());
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsPage(
        refresh: _libTick,
        offlineCard: () => _PreferOfflineCard(
          on: _preferOffline,
          onToggle: _setPreferOffline,
        ),
        onStorage: _openStorage,
        onBackup: _backup,
        onRestore: _restore,
        onCheckYtDlp: _checkYtDlp,
        downloadCard: () => _DownloadSettingsCard(
          wifiOnly: _wifiOnly,
          quality: _quality,
          onWifiOnly: _setWifiOnly,
          onQuality: _setQuality,
          resetWarm: _resetWarmOnSession,
          onResetWarm: _setResetWarm,
          retryAsk: _retryAsk,
          retryAuto: _retryAuto,
          onRetryAsk: _setRetryAsk,
          onRetryAuto: _setRetryAuto,
        ),
        smartCard: () => _SmartDownloadCard(
          on: _smartOn,
          limit: _smartLimit,
          today: _smartDay == _today() ? _smartCount : 0,
          waiting: _smartQueue.length,
          onToggle: _setSmart,
          onLimit: _setSmartLimit,
        ),
      ),
    ));
  }

  void _setPreferOffline(bool on) {
    setState(() => _preferOffline = on);
    SharedPreferences.getInstance()
        .then((p) => p.setBool('prefer_offline', on));
    _syncLocalVids();
    _touch();
  }

  void _setResetWarm(bool on) {
    setState(() => _resetWarmOnSession = on);
    SharedPreferences.getInstance()
        .then((p) => p.setBool('reset_warm_on_session', on));
    _touch();
  }

  void _setRetryAsk(bool on) {
    setState(() => _retryAsk = on);
    SharedPreferences.getInstance().then((p) => p.setBool('retry_ask', on));
    _touch();
  }

  void _setRetryAuto(bool on) {
    setState(() => _retryAuto = on);
    SharedPreferences.getInstance().then((p) => p.setBool('retry_auto', on));
    _touch();
  }

  void _setWifiOnly(bool on) {
    setState(() => _wifiOnly = on);
    SharedPreferences.getInstance().then((p) => p.setBool('wifi_only', on));
    _touch();
  }

  void _setQuality(String q) {
    setState(() => _quality = q);
    SharedPreferences.getInstance().then((p) => p.setString('dl_quality', q));
    _touch();
  }

  String get _qualityArg =>
      _quality == 'small' ? '128K' : (_quality == 'medium' ? '192K' : '0');

  Future<bool> _onWifi() async {
    try {
      final t = await _ytdlp.invokeMethod<String>('network');
      return t == 'wifi' || t == 'other';
    } catch (_) {
      return true;
    }
  }

  void _setSmart(bool on) {
    setState(() => _smartOn = on);
    _persistSmart();
    if (on) _smartKick();
  }

  void _setSmartLimit(int n) {
    setState(() => _smartLimit = n);
    _persistSmart();
    _smartKick();
  }

  void _trackPlay(Map<String, dynamic> d) {
    if (!_smartOn) return;
    final vid = _reportVid(d);
    if (vid.isEmpty) return;
    final now = DateTime.now();
    final playing = d['playing'] == true;
    final pos = ((d['pos'] as num?) ?? 0).toDouble();
    if (vid != _trackVid) {
      _trackVid = vid;
      _trackSecs = 0;
      _trackCounted = false;
      _trackWasPlaying = false;
    } else if (pos + 15 < _trackPos) {
      _trackSecs = 0;
      _trackCounted = false;
    }
    if (playing && _trackWasPlaying && _shadowVid == null) {
      final gap = now.difference(_trackAt).inMilliseconds / 1000;
      _trackSecs += gap > 6 ? 6.0 : gap;
    }
    _trackAt = now;
    _trackPos = pos;
    _trackWasPlaying = playing;
    if (!_trackCounted && _trackSecs >= 30) {
      _trackCounted = true;
      _recordPlay(vid, d);
    }
  }

  void _recordPlay(String vid, Map<String, dynamic> d) {
    final title = ((d['title'] as String?) ?? '').trim();
    final artist = ((d['artist'] as String?) ?? '').trim();
    if (title.isEmpty || _alreadyHave(vid, title, artist)) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoff = nowMs - 7 * 24 * 3600 * 1000;
    final list = (_plays[vid] ?? <int>[]).where((t) => t > cutoff).toList()
      ..add(nowMs);
    _plays[vid] = list;
    _plays.removeWhere((_, v) => v.every((t) => t <= cutoff));
    final queued = _smartQueue.any((q) => q['id'] == vid);
    if (list.length >= 3 && !queued && !_smartSeen.contains(vid)) {
      _smartQueue.add({
        'id': vid,
        'title': title,
        'artist': artist,
        'art': (d['art'] as String?) ?? '',
      });
      if (mounted) setState(() {});
      _persistSmart();
      _smartKick();
    } else {
      _persistSmart();
    }
  }

  Future<void> _smartKick() async {
    if (_smartBusy) return;
    _smartBusy = true;
    try {
      while (mounted && _smartOn && _smartQueue.isNotEmpty) {
        final today = _today();
        if (_smartDay != today) {
          _smartDay = today;
          _smartCount = 0;
          _persistSmart();
          setState(() {});
        }
        if (_smartCount >= _smartLimit) break;
        final q = _smartQueue.removeAt(0);
        final vid = q['id'] ?? '';
        final title = q['title'] ?? '';
        final artist = q['artist'] ?? '';
        if (vid.isEmpty || _alreadyHave(vid, title, artist)) {
          _persistSmart();
          continue;
        }
        _smartCount++;
        _smartSeen.add(vid);
        _persistSmart();
        if (mounted) setState(() {});

        _enqueue([
          PendingSong(vid, title, artist, null,
              art: q['art'] ?? '', smart: true)
        ]);
      }
    } finally {
      _smartBusy = false;
    }
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('saved_songs') ?? [];
    final list = <SavedSong>[];
    for (final s in raw) {
      try {
        list.add(SavedSong.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    if (mounted) setState(() => _saved = list);
  }

  Future<void> _persistSaved() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'saved_songs', _saved.map((s) => jsonEncode(s.toJson())).toList());
  }

  Future<void> _loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('local_songs') ?? [];
    final list = <LocalSong>[];

    String? musicDir;
    try {
      musicDir = '${(await getApplicationDocumentsDirectory()).path}/music';
    } catch (_) {}
    String fixPath(String old) {
      if (old.isEmpty || File(old).existsSync() || musicDir == null) return old;
      final moved = '$musicDir/${old.split('/').last}';
      return File(moved).existsSync() ? moved : old;
    }

    var rebased = false;
    for (final s in raw) {
      try {
        var song = LocalSong.fromJson(jsonDecode(s) as Map<String, dynamic>);
        final p = fixPath(song.path);
        if (p != song.path) {
          rebased = true;
          song = LocalSong(
              title: song.title,
              artist: song.artist,
              path: p,
              art: fixPath(song.art),
              uploaded: song.uploaded);
        } else if (song.art.isNotEmpty) {
          final a = fixPath(song.art);
          if (a != song.art) {
            rebased = true;
            song = LocalSong(
                title: song.title,
                artist: song.artist,
                path: song.path,
                art: a,
                uploaded: song.uploaded);
          }
        }
        if (File(song.path).existsSync()) list.add(song);
      } catch (_) {}
    }
    if (rebased) {
      await prefs.setStringList(
          'local_songs', list.map((x) => jsonEncode(x.toJson())).toList());
    }
    final played = <String, int>{};
    try {
      final rawPlayed = jsonDecode(prefs.getString('last_played') ?? '{}');
      if (rawPlayed is Map) {
        rawPlayed.forEach((k, v) {
          if (v is num) played[k as String] = v.toInt();
        });
      }
    } catch (_) {}
    _lastPlayed = played;
    if (mounted) setState(() => _localSongs = list);
    _syncLocalVids();
    _touch();
    await _rescanMusic();
  }

  Future<void> _rescanMusic() async {
    try {
      if (_downloading) return;
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/music');
      if (!await dir.exists()) return;
      final known = _localSongs.map((s) => s.path).toSet();

      final prefs = await SharedPreferences.getInstance();
      final saved = <String, SavedSong>{};
      for (final raw in prefs.getStringList('saved_songs') ?? <String>[]) {
        try {
          final s = SavedSong.fromJson(jsonDecode(raw) as Map<String, dynamic>);
          if (s.vid.isNotEmpty) saved[s.vid] = s;
        } catch (_) {}
      }

      final found = <LocalSong>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final path = e.path;
        final lp = path.toLowerCase();
        if (!_audioExts.any((x) => lp.endsWith('.$x')) ||
            known.contains(path)) {
          continue;
        }
        if (await e.length() == 0) continue;
        final name = path.split('/').last;
        final vid = _vidRe.firstMatch(name)?.group(1) ?? '';
        var title = '';
        var artist = '';
        var artPath = File('$path.jpg').existsSync() ? '$path.jpg' : '';
        try {
          final md = readMetadata(e, getImage: artPath.isEmpty);
          title = (md.title ?? '').trim();
          artist = (md.artist ?? '').trim();
          if (artPath.isEmpty && md.pictures.isNotEmpty) {
            final img = File('$path.jpg');
            await img.writeAsBytes(md.pictures.first.bytes);
            artPath = img.path;
          }
        } catch (_) {}
        final sv = saved[vid];
        if (title.isEmpty) title = sv?.title ?? '';
        if (artist.isEmpty) artist = sv?.artist ?? '';
        if (title.isEmpty) {
          title = vid.isNotEmpty
              ? 'Song $vid'
              : name.replaceAll(
                  RegExp(r'\.(mp3|m4a|aac|wav|aiff?|caf|flac)$',
                      caseSensitive: false),
                  '');
        }
        found.add(LocalSong(
            title: title, artist: artist, path: path, art: artPath));
      }
      if (found.isEmpty || !mounted) return;
      setState(() => _localSongs = [..._localSongs, ...found]);
      await _persistLocal();
      _toast('Recovered ${found.length} song(s) from the music folder');
    } catch (_) {}
  }

  Future<void> _persistLocal() async {
    _syncLocalVids();
    _touch();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'local_songs', _localSongs.map((s) => jsonEncode(s.toJson())).toList());
  }

  static const List<String> _audioExts = [
    'mp3', 'm4a', 'aac', 'wav', 'aif', 'aiff', 'caf', 'flac',
  ];

  Future<List<PlatformFile>> _pickAudio() {
    if (Platform.isIOS) {
      return FilePicker.pickFiles(
          type: FileType.custom, allowedExtensions: _audioExts);
    }
    return FilePicker.pickFiles(type: FileType.audio);
  }

  Future<String?> _sniffAudioExt(File f) async {
    try {
      final raf = await f.open();
      final b = await raf.read(16);
      await raf.close();
      if (b.length < 4) return null;
      String at(int i, int n) =>
          String.fromCharCodes(b.skip(i).take(n).toList());
      if (at(0, 3) == 'ID3') return 'mp3';
      if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) {

        return ((b[1] >> 1) & 0x03) == 0 ? 'aac' : 'mp3';
      }
      if (b.length >= 8 && at(4, 4) == 'ftyp') return 'm4a';
      if (at(0, 4) == 'fLaC') return 'flac';
      if (b.length >= 12 && at(0, 4) == 'RIFF' && at(8, 4) == 'WAVE') return 'wav';
      if (b.length >= 12 && at(0, 4) == 'FORM') return 'aiff';
      if (at(0, 4) == 'caff') return 'caf';
      if (at(0, 4) == 'OggS') return 'ogg';
    } catch (_) {}
    return null;
  }

  Future<String?> _savePickedAudio(PlatformFile f, String destBase) async {
    final tmp = File('$destBase.part');
    try {
      final from = f.path;
      var copied = false;
      if (from != null) {
        try {
          await File(from).copy(tmp.path);
          copied = true;
        } catch (_) {}
      }
      if (!copied) await tmp.writeAsBytes(await f.readAsBytes());
      if (await tmp.length() == 0) {
        await tmp.delete();
        return null;
      }
      final sniffed = await _sniffAudioExt(tmp);
      final named = f.name.contains('.')
          ? f.name.substring(f.name.lastIndexOf('.') + 1).toLowerCase()
          : '';
      var ext = sniffed ?? (_audioExts.contains(named) ? named : '');
      if (ext == 'aiff' && named == 'aif') ext = 'aif';
      if (ext.isEmpty && !Platform.isIOS) ext = 'mp3';
      if (ext.isEmpty || (Platform.isIOS && !_audioExts.contains(ext))) {
        await tmp.delete();
        return null;
      }
      final dest = '$destBase.$ext';
      await tmp.rename(dest);
      return dest;
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return null;
    }
  }

  Future<void> _addMusic() async {

    final files = await _pickAudio();
    if (files.isEmpty) return;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/music');
    await dir.create(recursive: true);
    var added = 0;
    var skipped = 0;
    for (final f in files) {
      try {
        final name = f.name;
        var title = name.contains('.')
            ? name.substring(0, name.lastIndexOf('.'))
            : name;
        final stem = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
        final dest = await _savePickedAudio(
            f, '${dir.path}/${DateTime.now().microsecondsSinceEpoch}_$stem');
        if (dest == null) {
          skipped++;
          continue;
        }
        var artist = '';
        var artPath = '';
        try {
          final md = readMetadata(File(dest), getImage: true);
          if ((md.title ?? '').trim().isNotEmpty) title = md.title!.trim();
          artist = (md.artist ?? '').trim();
          if (md.pictures.isNotEmpty) {
            final img = File('$dest.jpg');
            await img.writeAsBytes(md.pictures.first.bytes);
            artPath = img.path;
          }
        } catch (_) {}
        _localSongs = [
          ..._localSongs,
          LocalSong(title: title, artist: artist, path: dest, art: artPath),
        ];
        added++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {});
    await _persistLocal();
    _toast(added > 0
        ? 'Added $added song(s)${skipped > 0 ? ' ($skipped skipped: empty or not a format this phone plays)' : ''}'
        : 'Could not add those files (empty, or not MP3 / M4A / WAV / FLAC / AAC)');
  }

  void _markPlayed(LocalSong s) {
    _lastPlayed[s.path] = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.getInstance()
        .then((p) => p.setString('last_played', jsonEncode(_lastPlayed)));
  }

  Future<void> _removeLocalMany(List<LocalSong> list) async {
    if (list.isEmpty) return;
    final paths = list.map((s) => s.path).toSet();
    final playing = (_localIdx >= 0 && _localIdx < _localSongs.length)
        ? _localSongs[_localIdx]
        : null;
    final playPath = playing?.path;
    final keepPlaying = playPath != null && !paths.contains(playPath);
    if (playPath != null && !keepPlaying) {
      audioHandler.stopLocal();
    }
    for (final s in list) {
      try {
        final f = File(s.path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      if (s.art.isNotEmpty) {
        try {
          final a = File(s.art);
          if (await a.exists()) await a.delete();
        } catch (_) {}
      }
      _lastPlayed.remove(s.path);
      _addedCache.remove(s.path);
    }
    _queue?.removeWhere((x) => paths.contains(x.path));
    for (final f in _playlists) {
      f.paths.removeAll(paths);
    }
    if (!mounted) return;
    setState(() {
      _localSongs = _localSongs.where((x) => !paths.contains(x.path)).toList();
      _localIdx = keepPlaying
          ? _localSongs.indexWhere((x) => x.path == playPath)
          : -1;
    });
    await _persistLocal();
    await _persistPlaylists();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_played', jsonEncode(_lastPlayed));
  }

  Future<String> _checkYtDlp() async {
    if (_queueRunning || _downloading) {
      return 'Downloads are running. Try again when they have finished.';
    }
    if (!await _online()) return 'No internet connection.';
    try {
      final r = await _ytdlp
          .invokeMethod<String>('update')
          .timeout(const Duration(seconds: 90));
      _ytdlpChecked = true;
      final t = (r ?? '').toUpperCase();
      if (t.contains('ALREADY')) return 'yt-dlp is already the newest version.';
      if (t.contains('DONE')) {
        return 'yt-dlp was updated. Try the downloads that failed again.';
      }
      return 'Update finished: ${r ?? 'ok'}';
    } on TimeoutException {
      return 'The check took too long. Check your connection and try again.';
    } on MissingPluginException {
      return 'The yt-dlp part is not installed in this build of the app.';
    } on PlatformException catch (e) {
      return 'The update failed: ${e.message ?? e.code}';
    } catch (e) {
      return 'The update failed: $e';
    }
  }

  static const String _backupApp = 'ytmusicweb-backup';

  static const MethodChannel _backupCh = MethodChannel('ytmusicweb/backup');

  Map<String, dynamic> _songRef(LocalSong s) =>
      {'vid': _vidOf(s), 'title': s.title, 'artist': s.artist};

  List<Map<String, dynamic>> _maps(dynamic v) => (v is List ? v : const [])
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList();

  Map<String, dynamic> _backupData([Map<String, _ZipNames>? names]) {
    Map<String, dynamic> ref(LocalSong s) {
      final m = _songRef(s);
      final z = names?[s.path];
      if (z != null) {
        m['file'] = z.file;
        if (z.art != null) m['art'] = z.art;
      }
      return m;
    }

    return {
      'app': _backupApp,
      'version': names == null ? 1 : 2,
      'created': DateTime.now().toIso8601String(),
      'saved': _saved.map((s) => s.toJson()).toList(),
      'library': _localSongs.map(ref).toList(),
      'folders': [
        for (final f in _playlists)
          {
            'id': f.id,
            'name': f.name,
            'url': f.url,
            'known': f.known.toList(),
            'songs': _localSongs.where((s) => f.paths.contains(s.path)).map(ref).toList(),
          }
      ],
    };
  }

  Future<void> _backup() async {
    final c = await _askBackupOptions();
    if (c == null || !mounted) return;
    if (c.audio) {
      await _backupWithAudio(c);
    } else {
      await _backupListOnly();
    }
  }

  Future<_BackupChoice?> _askBackupOptions() async {
    final sizes = <String, int>{};
    for (final s in _localSongs) {
      try {
        sizes[s.path] = await File(s.path).length();
      } catch (_) {
        sizes[s.path] = 0;
      }
    }
    int bytesOf(Iterable<LocalSong> l) =>
        l.fold<int>(0, (a, s) => a + (sizes[s.path] ?? 0));
    final rows = <_BackupRow>[];
    for (final f in _playlists) {
      final l = _songsOfFolder(f);
      rows.add(_BackupRow(f.id, f.name, l.length, bytesOf(l)));
    }
    final loose = _localSongs
        .where((s) => !_playlists.any((f) => _inFolder(f, s)))
        .toList();
    if (!mounted) return null;
    return showDialog<_BackupChoice>(
      context: context,
      builder: (_) => _BackupOptionsDialog(
        totalSongs: _localSongs.length,
        totalBytes: bytesOf(_localSongs),
        rows: rows,
        looseSongs: loose.length,
        looseBytes: bytesOf(loose),
      ),
    );
  }

  List<LocalSong> _backupSongs(_BackupChoice c) {
    if (c.all) return List.of(_localSongs);
    final out = <LocalSong>[];
    for (final s in _localSongs) {
      final inChosen = _playlists
          .any((f) => c.folderIds.contains(f.id) && _inFolder(f, s));
      final inAny = _playlists.any((f) => _inFolder(f, s));
      if (inChosen || (c.loose && !inAny)) out.add(s);
    }
    return out;
  }

  Future<void> _backupListOnly() async {
    try {
      final bytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent(' ').convert(_backupData())));
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final where = await FilePicker.saveFile(
        dialogTitle: 'Save backup',
        fileName: 'ytmusic-backup-$day.json',
        bytes: bytes,
      );
      if (where == null) return;
      _toast(
          'Backup saved: ${_songsText(_localSongs.length)}, ${_playlists.length} folder(s), ${_saved.length} saved link(s)');
    } catch (e) {
      _toast('Could not save the backup: $e');
    }
  }

  VoidCallback _openProgress(
      String title, ValueNotifier<_Prog> prog, VoidCallback onCancel) {
    var open = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _ProgressDialog(title: title, progress: prog, onCancel: onCancel),
    );
    return () {
      if (open && mounted) {
        open = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    };
  }

  Future<void> _backupWithAudio(_BackupChoice c) async {
    final jobs = <_AudioJob>[];
    final used = <String>{};
    var total = 0;
    for (final s in _backupSongs(c)) {
      int len;
      try {
        final f = File(s.path);
        if (!await f.exists()) continue;
        len = await f.length();
      } catch (_) {
        continue;
      }
      if (len == 0) continue;
      final base =
          s.path.split('/').last.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      var name = 'music/$base';
      var n = 1;
      while (!used.add(name)) {
        name = 'music/${n++}_$base';
      }
      String? art;
      if (s.art.isNotEmpty) {
        try {
          if (await File(s.art).exists()) art = '$name.jpg';
        } catch (_) {}
      }
      jobs.add(_AudioJob(s, name, art, len));
      total += len;
    }
    if (jobs.isEmpty) {
      _toast('None of the chosen songs has an audio file on this phone');
      return;
    }
    if (!mounted) return;

    var cancelled = false;
    final prog = ValueNotifier<_Prog>(const _Prog('Getting ready...', null));
    final closeProgress = _openProgress('Backing up audio', prog, () {
      cancelled = true;
      prog.value = const _Prog('Cancelling...', null);
    });

    String? zipPath;
    ZipWriter? zw;
    try {
      final tmp = await getTemporaryDirectory();
      final day = DateTime.now().toIso8601String().substring(0, 10);
      zipPath = '${tmp.path}/ytmusic-backup-$day.zip';
      try {
        await File(zipPath).delete();
      } catch (_) {}
      zw = await ZipWriter.create(zipPath);

      final names = <String, _ZipNames>{};
      var done = 0, added = 0, failed = 0, addedBytes = 0;
      var shown = 0.0;
      for (final j in jobs) {
        if (cancelled) break;
        final label =
            '${added + failed + 1} of ${jobs.length}\n${j.song.title.isEmpty ? j.name : j.song.title}';
        prog.value = _Prog(label, math.min(1.0, done / total));
        try {
          await zw.addFile(j.name, File(j.song.path), onBytes: (n) {
            done += n;
            final f = math.min(1.0, done / total);
            if (f - shown >= 0.005) {
              shown = f;
              prog.value = _Prog(label, f);
            }
          });
          String? artName;
          if (j.art != null) {
            try {
              await zw.addFile(j.art!, File(j.song.art));
              artName = j.art;
            } catch (_) {}
          }
          names[j.song.path] = _ZipNames(j.name, artName);
          added++;
          addedBytes += j.size;
        } catch (_) {
          failed++;
        }
      }
      if (cancelled) {
        _toast('Backup cancelled');
        return;
      }
      if (added == 0) {
        _toast('Could not read any of the audio files');
        return;
      }
      await zw.addBytes(
          'backup.json',
          utf8.encode(
              const JsonEncoder.withIndent(' ').convert(_backupData(names))));
      await zw.close();
      zw = null;

      prog.value = const _Prog('Choose where to save the backup...', null);
      bool saved;
      try {
        saved = (await _backupCh.invokeMethod<bool>('exportFile', {
              'path': zipPath,
            })) ??
            false;
      } on MissingPluginException {

        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/Backups');
        await dir.create(recursive: true);
        final dest = '${dir.path}/${zipPath.split('/').last}';
        await File(zipPath).copy(dest);
        _toast('Backup saved to $dest');
        return;
      }
      if (!saved) {
        _toast('Backup not saved');
        return;
      }
      _toast('Backup saved: ${_songsText(added)} with audio (${_fmtBytes(addedBytes)})'
          '${failed > 0 ? ', $failed could not be read' : ''}');
    } on FileSystemException catch (e) {
      final full = (e.osError?.errorCode == 28) ||
          e.message.toLowerCase().contains('space');
      _toast(full
          ? 'Not enough free space on this phone to build the backup'
          : 'Could not build the backup: ${e.message}');
    } catch (e) {
      _toast('Could not save the backup: $e');
    } finally {
      await zw?.abort();
      closeProgress();
      if (zipPath != null) {
        try {
          await File(zipPath).delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _restore() async {
    Map<String, dynamic> data;
    ZipReader? zip;
    String? pickedPath;
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty) return;
      pickedPath = files.first.path;
      Object? j;
      if (pickedPath != null && await looksLikeZip(pickedPath)) {
        zip = await ZipReader.open(pickedPath);
        final m = zip.find('backup.json');
        if (m == null) throw const FormatException();
        j = jsonDecode(utf8.decode(await zip.readBytes(m)));
      } else {
        j = jsonDecode(utf8.decode(await files.first.readAsBytes()));
      }
      if (j is! Map || j['app'] != _backupApp) throw const FormatException();
      data = Map<String, dynamic>.from(j);
    } catch (_) {
      await zip?.close();
      _toast('That is not a backup file made by this app');
      return;
    }
    try {
      await _restoreData(data, zip);
    } finally {
      await zip?.close();

      try {
        final tmp = await getTemporaryDirectory();
        if (pickedPath != null && pickedPath.startsWith(tmp.path)) {
          await File(pickedPath).delete();
        }
      } catch (_) {}
    }
  }

  Future<List<int>> _extractZipSongs(
      ZipReader zip, List<_ZipSong> items) async {
    var cancelled = false;
    final prog = ValueNotifier<_Prog>(const _Prog('Getting ready...', null));
    final closeProgress = _openProgress('Restoring audio', prog, () {
      cancelled = true;
      prog.value = const _Prog('Cancelling...', null);
    });
    var ok = 0, bad = 0, done = 0, total = 0;
    for (final z in items) {
      total += zip.find(z.file)?.size ?? 0;
    }
    final added = <LocalSong>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/music');
      await dir.create(recursive: true);
      var shown = 0.0;
      var i = 0;
      for (final z in items) {
        if (cancelled) break;
        i++;
        final entry = zip.find(z.file);
        final ext = z.file.contains('.')
            ? z.file.substring(z.file.lastIndexOf('.') + 1).toLowerCase()
            : '';
        if (entry == null || !_audioExts.contains(ext)) {
          bad++;
          continue;
        }
        final label =
            '$i of ${items.length}\n${z.title.isEmpty ? z.file : z.title}';
        prog.value = _Prog(label, total == 0 ? null : math.min(1.0, done / total));

        final base = z.file
            .split('/')
            .last
            .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        var dest = '${dir.path}/$base';
        if (File(dest).existsSync()) {

          final m = RegExp(r'^\d+_(.+)$').firstMatch(base);
          final stamp = DateTime.now().millisecondsSinceEpoch + i;
          dest = '${dir.path}/${stamp}_${m != null ? m.group(1) : base}';
        }
        try {
          await zip.extractTo(entry, dest, onBytes: (n) {
            done += n;
            final f = total == 0 ? 0.0 : math.min(1.0, done / total);
            if (f - shown >= 0.005) {
              shown = f;
              prog.value = _Prog(label, f);
            }
          });
        } catch (_) {
          bad++;
          continue;
        }
        var artPath = '';
        if (z.art.isNotEmpty) {
          final ae = zip.find(z.art);
          if (ae != null) {
            try {
              await zip.extractTo(ae, '$dest.jpg');
              artPath = '$dest.jpg';
            } catch (_) {}
          }
        }
        var title = z.title;
        var artist = z.artist;
        try {
          final md = readMetadata(File(dest), getImage: artPath.isEmpty);
          if (title.isEmpty) title = (md.title ?? '').trim();
          if (artist.isEmpty) artist = (md.artist ?? '').trim();
          if (artPath.isEmpty && md.pictures.isNotEmpty) {
            await File('$dest.jpg').writeAsBytes(md.pictures.first.bytes);
            artPath = '$dest.jpg';
          }
        } catch (_) {}
        if (title.isEmpty) {
          title = base.replaceAll(RegExp(r'\.[A-Za-z0-9]+$'), '');
        }
        added.add(
            LocalSong(title: title, artist: artist, path: dest, art: artPath));
        ok++;
      }
    } catch (_) {

    } finally {
      closeProgress();
    }
    if (added.isNotEmpty && mounted) {
      setState(() => _localSongs = [..._localSongs, ...added]);
      await _persistLocal();
    }
    return [ok, bad];
  }

  Future<void> _restoreData(Map<String, dynamic> data, ZipReader? zip) async {
    if (!mounted) return;

    final savedIn = _maps(data['saved']).map(SavedSong.fromJson).toList();
    final libraryIn = _maps(data['library']);
    final foldersIn = _maps(data['folders']);

    final missing = <PendingSong>[];
    final zipSongs = <_ZipSong>[];
    final seen = <String>{};
    final zipSeen = <String>{};
    var noLink = 0;
    void check(Map<String, dynamic> m, String? folderId) {
      final vid = (m['vid'] as String?) ?? '';
      final title = (m['title'] as String?) ?? '';
      final artist = (m['artist'] as String?) ?? '';
      if (_findLocal(vid, title, artist) >= 0) return;
      final file = (m['file'] as String?) ?? '';
      final inZip = zip != null && file.isNotEmpty && zip.find(file) != null;
      if (inZip && zipSeen.add(vid.isNotEmpty ? vid : 't:$title|$artist')) {
        zipSongs.add(_ZipSong(vid, title, artist, file, (m['art'] as String?) ?? ''));
      }
      if (vid.isEmpty) {
        if (!inZip) noLink++;
        return;
      }
      if (seen.add(vid)) missing.add(PendingSong(vid, title, artist, folderId));
    }

    for (final fj in foldersIn) {
      final id = (fj['id'] as String?) ?? '';
      for (final sj in _maps(fj['songs'])) {
        check(sj, id.isEmpty ? null : id);
      }
    }
    for (final m in libraryIn) {
      check(m, null);
    }

    final zipVids =
        zipSongs.map((z) => z.vid).where((v) => v.isNotEmpty).toSet();
    final leftover = missing.where((p) => !zipVids.contains(p.vid)).toList();
    final hasAudio = zipSongs.isNotEmpty;
    final audioBytes =
        zipSongs.fold<int>(0, (a, z) => a + (zip?.find(z.file)?.size ?? 0));

    final when = DateTime.tryParse((data['created'] as String?) ?? '');
    final ask = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: SingleChildScrollView(
          child: Text(
              '${when == null ? '' : 'Made on ${when.toIso8601String().substring(0, 10)}.\n'}'
              'It has ${_songsText(libraryIn.length)}, ${foldersIn.length} folder(s) and ${savedIn.length} saved link(s).\n\n'
              '${hasAudio ? '${_songsText(zipSongs.length)} with audio in this backup are not on this phone (${_fmtBytes(audioBytes)}).' : (missing.isEmpty ? 'All its songs are already on this phone.' : '${_songsText(missing.length)} are not on this phone.')}'
              '${hasAudio && leftover.isNotEmpty ? '\n${_songsText(leftover.length)} more are in the list but their audio is not in this backup.' : ''}'
              '${noLink > 0 ? '\n$noLink added by hand cannot be downloaded again.' : ''}\n\n'
              'Nothing is deleted: the backup is added to what you have now.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, 0),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, 1),
              child: const Text('Restore list')),
          if (!hasAudio && missing.isNotEmpty)
            TextButton(
                onPressed: () => Navigator.pop(c, 2),
                child: Text('Restore + download ${missing.length}')),
          if (hasAudio)
            TextButton(
                onPressed: () => Navigator.pop(c, 3),
                child: Text('Restore + ${zipSongs.length} audio')),
          if (hasAudio && leftover.isNotEmpty)
            TextButton(
                onPressed: () => Navigator.pop(c, 4),
                child: Text(
                    'Audio + download ${leftover.length} more')),
        ],
      ),
    );
    if (ask == null || ask == 0 || !mounted) return;

    var audioDone = 0, audioFailed = 0;
    if ((ask == 3 || ask == 4) && zip != null) {
      final r = await _extractZipSongs(zip, zipSongs);
      audioDone = r[0];
      audioFailed = r[1];
      if (!mounted) return;
    }

    final newSaved = savedIn.where((s) => !_saved.any((x) => s.vid.isNotEmpty
        ? x.vid == s.vid
        : (x.title == s.title && x.artist == s.artist))).toList();
    _saved = [..._saved, ...newSaved];

    var created = 0;
    final idMap = <String, String>{};
    for (final fj in foldersIn) {
      final backupId = (fj['id'] as String?) ?? '';
      var id = backupId;
      if (id.isEmpty) id = 'bk${DateTime.now().microsecondsSinceEpoch}';
      final url = (fj['url'] as String?) ?? '';
      final known = ((fj['known'] as List?) ?? const [])
          .whereType<String>()
          .toSet();
      PlaylistFolder? f = _playlistById(id);
      if (f == null && url.isNotEmpty) {
        for (final x in _playlists) {
          if (x.url == url) f = x;
        }
      }
      if (f == null) {
        f = PlaylistFolder(
            id: id, name: (fj['name'] as String?) ?? 'Playlist', url: url);
        _playlists = [..._playlists, f];
        created++;
      }
      idMap[backupId] = f.id;
      f.known.addAll(known);
      for (final sj in _maps(fj['songs'])) {
        final i = _findLocal((sj['vid'] as String?) ?? '',
            (sj['title'] as String?) ?? '', (sj['artist'] as String?) ?? '');
        if (i >= 0) f.paths.add(_localSongs[i].path);
      }
    }

    final fixed = [
      for (final m in missing)
        PendingSong(m.vid, m.title, m.artist,
            m.folderId == null ? null : idMap[m.folderId])
    ];

    await _persistSaved();
    await _persistPlaylists();
    if (mounted) setState(() {});
    var queued = 0;
    final List<PendingSong> toDownload = ask == 2
        ? fixed
        : ask == 4
            ? fixed.where((p) => !zipVids.contains(p.vid)).toList()
            : const <PendingSong>[];
    if (toDownload.isNotEmpty) queued = _enqueue(toDownload);
    _toast('Restored: ${newSaved.length} saved link(s), $created new folder(s)'
        '${audioDone > 0 ? ', ${_songsText(audioDone)} with audio' : ''}'
        '${audioFailed > 0 ? ' ($audioFailed audio could not be restored)' : ''}'
        '${queued > 0 ? ', downloading $queued song(s)' : ''}');
  }

  void _openStorage() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StoragePage(
        songs: () => List.of(_localSongs),
        addedMs: _addedMs,
        lastPlayedMs: (s) => _lastPlayed[s.path],
        onDelete: _removeLocalMany,
      ),
    ));
  }

  Future<bool> _playLocal(int i, {Duration? start}) async {
    if (i < 0 || i >= _localSongs.length) return false;
    final s = _localSongs[i];
    setState(() => _localIdx = i);
    _touch();
    _markPlayed(s);
    try {
      await audioHandler.playLocal(
        path: s.path,
        title: s.title,
        artist: s.artist,
        artPath: s.art.isEmpty ? null : s.art,
        startAt: start,
      );
      return true;
    } catch (e) {
      var why = _errText(e).replaceAll('\n', ' ');
      if (why.length > 110) why = '${why.substring(0, 110)}...';
      _toast('Could not play this file ($why)');
      return false;
    }
  }

  Future<bool> _playQueue(List<LocalSong> queue, int pos) {
    if (pos < 0 || pos >= queue.length) return Future.value(false);
    _shadowVid = null;
    _resumeVid = null;
    final first = queue[pos];
    _queueOrig = List.of(queue);
    _queue = playerOpts.shuffle ? _shuffledFirst(queue, first) : List.of(queue);
    return _playLocal(_localSongs.indexOf(first));
  }

  Future<bool> _shuffleQueue(List<LocalSong> list) {
    if (list.isEmpty) return Future.value(false);
    playerOpts.setShuffle(true, apply: false);
    final pick = (List.of(list)..shuffle()).first;
    return _playQueue(list, list.indexOf(pick));
  }

  List<LocalSong> _shuffledFirst(List<LocalSong> q, LocalSong? first) {
    final rest = q.where((x) => !identical(x, first)).toList()..shuffle();
    return [if (first != null && q.contains(first)) first, ...rest];
  }

  void _applyShuffle() {
    final q = _queue;
    if (q == null || q.isEmpty) return;
    final cur = (_localIdx >= 0 && _localIdx < _localSongs.length)
        ? _localSongs[_localIdx]
        : null;
    if (playerOpts.shuffle) {
      _queueOrig ??= List.of(q);
      _queue = _shuffledFirst(q, cur);
    } else {
      final live = _localSongs.map((s) => s.path).toSet();
      _queue = (_queueOrig ?? q).where((x) => live.contains(x.path)).toList();
    }
  }

  void _onLocalEnded() {
    if (_localSongs.isEmpty) return;
    if (playerOpts.repeat == 2 && _localIdx >= 0) {
      _playLocal(_localIdx);
      return;
    }
    if (playerOpts.repeat == 0) {
      final q = (_queue != null && _queue!.isNotEmpty) ? _queue! : _localSongs;
      final cur = (_localIdx >= 0 && _localIdx < _localSongs.length)
          ? _localSongs[_localIdx]
          : null;
      final pos = cur == null ? -1 : q.indexOf(cur);
      if (pos >= 0 && pos == q.length - 1) {
        audioHandler.stopLocal();
        return;
      }
    }
    _stepLocal(1);
  }

  void _stepLocal(int delta) {
    if (_localSongs.isEmpty) return;
    final q = (_queue != null && _queue!.isNotEmpty) ? _queue! : _localSongs;
    final cur = (_localIdx >= 0 && _localIdx < _localSongs.length)
        ? _localSongs[_localIdx]
        : null;
    var pos = cur == null ? -1 : q.indexOf(cur);
    if (pos < 0) {
      pos = delta > 0 ? 0 : q.length - 1;
    } else {
      pos = (pos + delta) % q.length;
    }
    _playLocal(_localSongs.indexOf(q[pos]));
  }

  void _removeLocal(LocalSong s) {
    final idx = _localSongs.indexOf(s);
    if (idx == _localIdx) {
      audioHandler.stopLocal();
      _localIdx = -1;
    } else if (idx >= 0 && idx < _localIdx) {
      _localIdx--;
    }
    try {
      File(s.path).deleteSync();
      if (s.art.isNotEmpty) File(s.art).deleteSync();
    } catch (_) {}
    _queue?.remove(s);
    for (final f in _playlists) {
      f.paths.remove(s.path);
    }
    setState(() => _localSongs = _localSongs.where((x) => x != s).toList());
    _persistLocal();
    _persistPlaylists();
  }

  String _vidOf(LocalSong s) =>
      _vidRe.firstMatch(s.path.split('/').last)?.group(1) ?? '';

  int _localIndexByVid(String vid) =>
      vid.isEmpty ? -1 : _localSongs.indexWhere((s) => _vidOf(s) == vid);

  int _findLocal(String vid, String title, String artist) {
    final i = _localIndexByVid(vid);
    if (i >= 0) return i;
    if (title.isEmpty) return -1;
    return _localSongs
        .indexWhere((s) => s.title == title && s.artist == artist);
  }

  void _syncLocalVids() {

    final vids = _preferOffline
        ? _localSongs.map(_vidOf).where((v) => v.isNotEmpty).toList()
        : <String>[];

    final keys = _preferOffline
        ? _localSongs
            .where((s) => s.title.trim().isNotEmpty && s.artist.trim().isNotEmpty)
            .map((s) => {'t': s.title, 'a': s.artist})
            .toList()
        : <Map<String, String>>[];
    _controller
        .runJavaScript('window.__localVids=${jsonEncode(vids)};'
            'window.__localKeys=${jsonEncode(keys)};')
        .catchError((_) {});
  }

  String _reportVid(Map<String, dynamic> d) {
    final c = (d['cvid'] as String?) ?? '';
    return c.isNotEmpty ? c : ((d['vid'] as String?) ?? '');
  }

  Future<bool> _online() async {
    try {
      final r = await InternetAddress.lookup('music.youtube.com')
          .timeout(const Duration(seconds: 3));
      return r.isNotEmpty && r.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startShadow(int i, String vid,
      {Duration? start}) async {
    _shadowVid = vid;
    _resumeVid = vid;
    if (i >= 0 && i < _localSongs.length) _queue = _queueFor(_localSongs[i]);
    _shadowStarted = DateTime.now();
    final ok = await _playLocal(i, start: start);
    if (!ok && _shadowVid == vid) {

      _shadowVid = null;
      _resumeVid = null;
      if (mounted) setState(() {});
      _controller
          .runJavaScript('window.__allowWeb=${jsonEncode(vid)};'
              "var v=document.querySelector('video');if(v){v.play();}")
          .catchError((_) {});
    }
  }

  void _onShadowPlay(String message) {
    var vid = '', lt = '', la = '';
    try {
      final m = jsonDecode(message) as Map;
      vid = (m['vid'] as String?) ?? '';
      lt = (m['lt'] as String?) ?? '';
      la = (m['la'] as String?) ?? '';
    } catch (_) {}
    if (vid.isEmpty) return;
    if (_shadowVid == vid) {

      if (DateTime.now().difference(_shadowStarted).inMilliseconds < 1500) {
        return;
      }
      if (audioHandler.playbackState.value.playing) {
        audioHandler.pause();
      } else {
        audioHandler.play();
      }
      return;
    }
    var i = _localIndexByVid(vid);
    if (i < 0 && lt.isNotEmpty) {
      i = _localSongs.indexWhere((s) => s.title == lt && s.artist == la);
    }
    if (i >= 0) {
      _startShadow(i, vid);
    } else if (lt.isNotEmpty) {

      _controller
          .runJavaScript('window.__allowWeb=${jsonEncode(vid)};'
              "var v=document.querySelector('video');if(v){v.play();}")
          .catchError((_) {});
    }
  }

  bool _onWebReport(Map<String, dynamic> d) {
    final playing = d['playing'] == true;
    if (playing) _wantWebPlay = false;
    final vid = _reportVid(d);

    if (_shadowVid != null) {
      if (vid == _shadowVid || !playing) return false;

      _shadowVid = null;
      _resumeVid = null;
      return true;
    }

    final offline = d['online'] == false || d['stalled'] == true;
    if (playing && offline) _maybeGoOffline(d, vid);
    return true;
  }

  Future<void> _maybeGoOffline(Map<String, dynamic> d, String vid) async {
    if (_offlineBusy) return;
    _offlineBusy = true;
    try {

      if (d['online'] != false && await _online()) return;
      if (_shadowVid != null) return;
      final title = ((d['title'] as String?) ?? '').trim();
      final artist = ((d['artist'] as String?) ?? '').trim();
      final i = _findLocal(vid, title, artist);
      if (i < 0) return;
      final pos = ((d['pos'] as num?) ?? 0).toDouble();
      _toast('Offline: playing the downloaded copy');
      await _startShadow(i, vid.isNotEmpty ? vid : 'offline',
          start: Duration(milliseconds: (pos * 1000).round()));
    } finally {
      _offlineBusy = false;
    }
  }

  Future<void> _webStep(bool next) async {
    final old = _resumeVid;
    if (!await _online()) {
      _shadowVid = null;
      _stepLocal(next ? 1 : -1);
      return;
    }
    _shadowVid = null;
    _resumeVid = null;
    _wantWebPlay = true;
    await audioHandler.releaseLocal();
    if (mounted) setState(() => _localIdx = -1);
    _touch();
    if (next) {
      await audioHandler.skipToNext();
    } else {
      await audioHandler.skipToPrevious();
    }

    for (final ms in [800, 2000, 4000]) {
      await Future.delayed(Duration(milliseconds: ms));
      if (!_wantWebPlay || !mounted) return;
      if (_reportVid(_now) == old) continue;
      _controller.runJavaScript(_resumeJs).catchError((_) {});
    }
    _wantWebPlay = false;
  }

  Future<void> _shadowPrev() async {
    if (audioHandler.playbackState.value.position >
        const Duration(seconds: 3)) {
      await audioHandler.seek(Duration.zero);
    } else {
      await _webStep(false);
    }
  }

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method != 'progress') return null;
    final t = _activeTask;
    if (t == null) return null;
    final a = Map<String, dynamic>.from(call.arguments as Map);
    _lastNative = DateTime.now();
    final pct = (a['progress'] as num?)?.toDouble() ?? -1;
    final eta = (a['eta'] as num?)?.toInt() ?? -1;
    final line = ((a['line'] as String?) ?? '').trim();

    if (pct >= 0 && t.status != DlStatus.saving) {
      t.status = DlStatus.downloading;
      t.pct = pct;
      t.etaSec = eta >= 0 ? eta : null;
      if (mounted) setState(() => _dlProgress = pct / 100);
      final step = pct ~/ 10;
      if (step > _lastLogStep) {
        _lastLogStep = step;
        _dl.log('Downloading ${pct.round()}%');
      }
    }

    if (line.isNotEmpty && !line.contains('% of')) {
      if (line.contains('[ExtractAudio]') || line.contains('[ffmpeg]')) {
        t.status = DlStatus.saving;
      }
      _dl.log(line.length > 160 ? '${line.substring(0, 160)}...' : line,
          error: line.startsWith('ERROR'));
    }
    _dl.changed();
    return null;
  }

  Future<void> _downloadCurrent() async {
    final title = ((_now['title'] as String?) ?? '').trim();
    final artist = ((_now['artist'] as String?) ?? '').trim();
    final art = (_now['art'] as String?) ?? '';
    final vid = _nowVid;
    if (title.isEmpty || vid.isEmpty) {
      _toast('Nothing is playing yet');
      return;
    }
    if (_alreadyHave(vid, title, artist)) {
      _toast('Already on this device');
      return;
    }
    if (_activeSong?.vid == vid) {
      _toast('This song is downloading now');
      return;
    }
    if (_dl.pending.any((p) => p.vid == vid)) {
      _toast('This song is already waiting in the download list');
      return;
    }
    final busy = _queueRunning;
    _enqueue([PendingSong(vid, title, artist, null, art: art)]);
    _toast(busy
        ? 'Added "$title" to the download list (${_dl.pending.length} waiting)'
        : 'Downloading "$title"... follow it in Download tab > Downloading');
  }

  Future<void> _offerSaveFailed({
    required String vid,
    required String title,
    required String artist,
    required String art,
  }) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final exists = _saved.any((s) =>
        (vid.isNotEmpty && s.vid == vid) ||
        (s.title == title && s.artist == artist));
    if (exists) {
      _toast(
          'Download failed. This song is already in your saved list: tap its upload icon to add the MP3.');
      return;
    }
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Song failed to download'),
        content: Text(
            '"$title" could not be downloaded.\n\nIf you want, you can save it, download the MP3 yourself, and add it later: open the Download tab, find it in the saved list, and tap the upload icon.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (save != true || !mounted) return;
    final song = SavedSong(vid: vid, title: title, artist: artist, art: art);
    setState(() => _saved = [song, ..._saved]);
    _persistSaved();
    _toast('Saved. Add its MP3 later from the Download tab.');
  }

  bool get _nowDownloaded {
    final title = ((_now['title'] as String?) ?? '').trim();
    if (title.isEmpty) return false;
    return _alreadyHave(
        _nowVid, title, ((_now['artist'] as String?) ?? '').trim());
  }

  bool get _nowActive => _nowVid.isNotEmpty && _activeSong?.vid == _nowVid;
  bool get _nowWaiting =>
      _nowVid.isNotEmpty && _dl.pending.any((p) => p.vid == _nowVid);

  bool _alreadyHave(String vid, String title, String artist) =>
      _localSongs.any((s) =>
          (vid.isNotEmpty && s.path.contains('_$vid.')) ||
          (s.title == title && s.artist == artist));

  Future<DownloadTask> _downloadVideo({
    required String vid,
    required String title,
    String artist = '',
    String art = '',
    bool toast = true,
    String? folderId,
    String? resumeId,
  }) async {
    final task = _dl.start(title, artist, folderId: folderId);
    _activeTask = task;
    _lastLogStep = -1;
    _lastNative = DateTime.now();
    Timer? watchdog;
    String? outPath;
    final id = resumeId ?? '${DateTime.now().microsecondsSinceEpoch}_$vid';
    _activeId = id;
    _lastAttemptId = id;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/music');
      await dir.create(recursive: true);

      task.status = DlStatus.preparing;
      _dl.changed();
      _dl.log(Platform.isIOS
          ? 'Starting download...'
          : _ytdlpChecked
          ? 'Starting yt-dlp...'
          : 'Starting yt-dlp (the first run unpacks it and checks for an update, this can take a minute)...');

      watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
        final idle = DateTime.now().difference(_lastNative).inSeconds;
        if (idle >= 10) _dl.log('No output for ${idle}s, still working...');
      });

      outPath = Platform.isIOS
          ? await _downloadWithDart(vid, id, dir, task)
          : await _ytdlp.invokeMethod<String>('download', {
        'url': 'https://music.youtube.com/watch?v=$vid',
        'dir': dir.path,
        'id': id,
        'update': !_ytdlpChecked,
        'quality': _qualityArg,
      }).timeout(const Duration(minutes: 10), onTimeout: () {
        _cancelDownload(id);
        throw TimeoutException('Gave up after 10 minutes');
      });
      watchdog.cancel();

      final f = File(outPath ?? '');
      if (outPath == null || !f.existsSync() || f.lengthSync() == 0) {
        throw Exception('yt-dlp finished but no MP3 file was created');
      }
      task.total = f.lengthSync();
      task.received = task.total;
      task.pct = 100;
      _dl.log('MP3 ready (${(task.total / 1048576).toStringAsFixed(1)} MB)');

      task.status = DlStatus.saving;
      _dl.changed();
      _dl.log('Saving cover art...');
      var artPath = '';
      final artUrl = art.startsWith('http')
          ? art
          : 'https://i.ytimg.com/vi/$vid/hqdefault.jpg';
      try {
        final img =
            await http.get(Uri.parse(artUrl)).timeout(const Duration(seconds: 20));
        if (img.statusCode == 200) {
          final cover = File('$outPath.jpg');
          await cover.writeAsBytes(img.bodyBytes);
          artPath = cover.path;
        }
      } catch (_) {}
      _dl.log(artPath.isEmpty ? 'No cover art (continuing)' : 'Cover art saved');

      _localSongs = [
        ..._localSongs,
        LocalSong(title: title, artist: artist, path: outPath, art: artPath),
      ];
      await _persistLocal();
      task.status = DlStatus.done;
      task.finishedAt = DateTime.now();
      _dl.log('Done: "$title" added to On this device');
      if (mounted) {
        setState(() {});
        if (toast) _toast('Saved "$title" to this device');
      }
    } on MissingPluginException {
      _failDownload(
          task,
          'The yt-dlp part is not installed in the Android app yet. Follow the setup steps (YtDlpBridge.kt).',
          toast: toast);
    } on PlatformException catch (e) {
      _failDownload(task, e.message ?? e.code, toast: toast);
    } catch (e) {
      _failDownload(task, e.toString(), toast: toast);
    } finally {
      watchdog?.cancel();
      _ytdlpChecked = true;
      _activeTask = null;
      _activeId = null;
      _dl.changed();
    }
    return task;
  }

  final Map<String, VoidCallback> _dartCancels = {};
  void _cancelDownload(String id) {
    _dartCancels[id]?.call();
    if (!Platform.isIOS) {
      _ytdlp.invokeMethod('cancel', {'id': id}).catchError((_) {});
    }
  }

  static const String _uaIos =
      'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';
  static const String _uaSafari =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';

  String _uaForLink(Uri url) {
    final c = (url.queryParameters['c'] ?? '').toUpperCase();
    if (c == 'IOS') return _uaIos;
    if (c == 'ANDROID_VR') {
      return 'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
    }
    if (c == 'ANDROID') {
      return 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip';
    }
    return _uaSafari;
  }

  Future<({Uri url, int size, bool post, List<int> body, bool ump})?> _pageAudioLink(
      String vid,
      {bool quiet = false,
      Future<Object> Function(String js)? run}) async {
    try {

      run ??= audioHandler.runJsResult;
      if (run == null) return null;
      var t = (await run('JSON.stringify(window.__gv && window.__gv.audio || null)')
              .timeout(const Duration(seconds: 6)))
          .toString();
      if (t.startsWith('"')) t = jsonDecode(t) as String;
      final d = jsonDecode(t);
      if (d is! Map) {
        if (!quiet) _dl.log('The page has not fetched audio for a song yet');
        return null;
      }
      if ('${d['vid']}' != vid) {
        if (!quiet) _dl.log('The page link is for another song (play this one first)');
        return null;
      }
      final mime = '${d['mime']}';
      if (!mime.contains('mp4')) {
        if (!quiet) _dl.log(
            'The page is streaming $mime (itag ${d['itag']}), which iPhone cannot play. Skip to the next song and back, then try again');
        return null;
      }
      final size = int.tryParse('${d['clen']}') ?? 0;
      if (size <= 0) return null;

      final clean = '${d['url']}'.replaceAll(RegExp(r'[&?](range|rn|rbuf)=[^&]*'), '');
      final fixed = clean.contains('?') ? clean : clean.replaceFirst('&', '?');
      final post = '${d['method']}'.toUpperCase() == 'POST';
      var body = <int>[];
      final b64 = '${d['body'] ?? ''}';
      if (b64.isNotEmpty) {
        try {
          body = base64Decode(b64);
        } catch (_) {}
      }
      return (
          url: Uri.parse(fixed),
          size: size,
          post: post,
          body: body,
          ump: d['ump'] == true);
    } catch (_) {
      return null;
    }
  }

  static const int _warmNeedSecs = 15;
  bool _dlWarm = !Platform.isIOS;
  int _warmSecs = 0;
  Timer? _warmTimer;

  static const _signedInJs =
      "(function(){try{if(window.ytcfg&&ytcfg.get&&ytcfg.get('LOGGED_IN'))return true;}catch(e){}return /(^|; )(SAPISID|__Secure-3PAPISID)=/.test(document.cookie);})()";

  Future<void> _initWarmup() async {
    if (!Platform.isIOS) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('dl_warm') == true) {
        _dlWarm = true;
        return;
      }
    } catch (_) {}
    _dlWarm = false;
    _warmTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted || _dlWarm) return;
      try {
        final playing = (await _controller
                .runJavaScriptReturningResult(_isPlayingJs)
                .timeout(const Duration(seconds: 3)))
            .toString();
        if (playing == 'true' || playing == '1') _warmSecs++;
        var why = '';
        if (_warmSecs >= _warmNeedSecs) {
          why = 'listened for $_warmNeedSecs seconds';
        } else {
          final signed = (await _controller
                  .runJavaScriptReturningResult(_signedInJs)
                  .timeout(const Duration(seconds: 3)))
              .toString();
          if (signed == 'true' || signed == '1') why = 'signed in to YouTube Music';
        }
        if (why.isNotEmpty) await _finishWarmup(why);
      } catch (_) {}
    });
  }

  Future<void> _restartWarmup() async {
    if (!Platform.isIOS) return;
    _warmTimer?.cancel();
    _warmTimer = null;
    _warmSecs = 0;
    _dlWarm = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('dl_warm');
    } catch (_) {}
    _dl.log('Page session reset: download warm-up starts again (15 s).');
    _dl.changed();
    if (mounted) setState(() {});
    await _initWarmup();
  }

  Future<void> _finishWarmup(String why) async {
    _warmTimer?.cancel();
    _warmTimer = null;
    _dlWarm = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('dl_warm', true);
    } catch (_) {}
    _dl.log('Download warm-up done ($why). Downloads can start.');
    _dl.changed();
    if (mounted) setState(() {});
  }

  WebViewController? _dlWeb;
  bool _dlWebOn = false;
  bool _dlSessionCopied = false;

  Future<WebViewController> _ensureDownloadWeb() async {
    var c = _dlWeb;
    if (c == null) {
      PlatformWebViewControllerCreationParams p =
          const PlatformWebViewControllerCreationParams();
      if (WebViewPlatform.instance is WebKitWebViewPlatform) {
        p = WebKitWebViewControllerCreationParams(
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        );
      }
      final nc = WebViewController.fromPlatformCreationParams(p);
      c = nc;
      _dlWeb = nc;
      await nc.setJavaScriptMode(JavaScriptMode.unrestricted);
      await nc.setBackgroundColor(Colors.black);
      await nc.setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          nc.runJavaScript(WebAudioHandler.gvHookJs);
        },
        onPageFinished: (_) {
          nc.runJavaScript(_adBlockJs);
          nc.runJavaScript(WebAudioHandler.gvHookJs);
        },
      ));
      if (Platform.isIOS) {
        await nc.setUserAgent(_uaSafari);
      }
      _dlSessionCopied = false;
    }

    if (!_dlWebOn && mounted) {
      setState(() => _dlWebOn = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await _copySessionToDownloadWeb(c);
    return c;
  }

  Future<void> _copySessionToDownloadWeb(WebViewController dl) async {
    if (_dlSessionCopied) return;
    try {

      Future<String> readMain(String js) async {
        final r = await _controller
            .runJavaScriptReturningResult(js)
            .timeout(const Duration(seconds: 6));
        var t = r.toString();
        if (t.startsWith('"')) t = jsonDecode(t) as String;
        return t;
      }

      final onMusic = await readMain('location.hostname');
      if (!onMusic.contains('youtube.com')) {
        _dl.log('Download page: the main page is not on YouTube Music yet, session not copied');
        return;
      }
      final cookieText = await readMain('document.cookie');
      final storage = await readMain(
          "(function(){var o={};try{for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);o[k]=localStorage.getItem(k);}}catch(e){}return JSON.stringify(o);})()");

      await dl.loadRequest(Uri.parse('https://music.youtube.com'));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final st = (await dl
                .runJavaScriptReturningResult(
                    "document.readyState+'|'+location.hostname")
                .timeout(const Duration(seconds: 5),
                    onTimeout: () => ''))
            .toString()
            .replaceAll('"', '');
        if (st.startsWith('complete|music.youtube.com')) break;
      }

      final have = ((await dl.runJavaScriptReturningResult('document.cookie'))
              .toString()
              .replaceAll('"', ''))
          .split(';')
          .map((e) => e.trim().split('=').first)
          .where((e) => e.isNotEmpty)
          .toSet();
      var added = 0;
      final jar = WebViewCookieManager();
      for (final part in cookieText.split(';')) {
        final i = part.indexOf('=');
        if (i <= 0) continue;
        final name = part.substring(0, i).trim();
        final value = part.substring(i + 1).trim();
        if (name.isEmpty || have.contains(name)) continue;
        await jar.setCookie(WebViewCookie(
            name: name, value: value, domain: '.youtube.com', path: '/'));
        added++;
      }

      if (storage.length > 2) {
        await dl.runJavaScript(
            "(function(){try{var o=${jsonEncode(storage)};o=JSON.parse(o);for(var k in o){if(localStorage.getItem(k)===null)localStorage.setItem(k,o[k]);}}catch(e){}})()");
      }
      if (added > 0) {
        _dl.log('Download page: copied $added cookie(s) from the main page');
        await dl.reload();
      }
      _dlSessionCopied = true;
    } catch (e) {
      _dl.log('Download page: could not copy the session ($e)');
    }
  }

  Future<void> _closeDownloadWeb() async {
    final c = _dlWeb;
    _dlWeb = null;
    _dlSessionCopied = false;
    if (mounted && _dlWebOn) setState(() => _dlWebOn = false);
    try {
      await c?.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
  }

  bool _lastPageSabr = false;

  Future<({Uri url, int size, bool post, List<int> body, bool ump})?>
      _openInPageForLink(String vid) async {
    _lastPageSabr = false;
    final WebViewController web;
    try {
      web = await _ensureDownloadWeb();
    } catch (e) {
      _dl.log('Could not start the download page ($e)');
      return null;
    }
    Future<Object> run(String js) => web.runJavaScriptReturningResult(js);
    Future<String> ask(String js) async {
      try {
        final r = await run(js);
        return r.toString().replaceAll('"', '');
      } catch (e) {
        return 'error: $e';
      }
    }

    try {

      final ready = DateTime.now().add(const Duration(seconds: 30));
      var pageReady = false;
      while (DateTime.now().isBefore(ready)) {
        try {
          await web.runJavaScript(WebAudioHandler.gvHookJs);
        } catch (_) {}
        final st = await ask(
            "document.readyState+'|'+(window.__gv?'hook':'nohook')+'|'+location.hostname");
        if (st.startsWith('complete|hook|music.youtube.com')) {
          pageReady = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      if (!pageReady) {
        _dl.log('The download page was not ready after 30 s (${await ask("document.readyState+'|'+location.href.slice(0,60)")})');
      }

      final cur = await ask(
          "(function(){try{var p=document.getElementById('movie_player');return p&&p.getVideoData?p.getVideoData().video_id:''}catch(e){return ''}})()");
      if (cur != vid) {

        try {
          await web.runJavaScript('if(window.__gv){window.__gv.audio=null;}');
        } catch (_) {}
        await web.loadRequest(Uri.parse('https://music.youtube.com/watch?v=$vid'));
      }

      var until = DateTime.now().add(const Duration(seconds: 45));
      var started = DateTime.now();
      var reloaded = false;
      while (DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        try {
          await web.runJavaScript(WebAudioHandler.gvHookJs);
          await web.runJavaScript(
              "var v=document.querySelector('video');if(v){v.muted=true;v.volume=0;if(v.paused){v.play();}}");
        } catch (_) {}
        final l = await _pageAudioLink(vid, quiet: true, run: run);
        if (l != null) return l;

        if (DateTime.now().difference(started).inSeconds >= 10) {
          final counts = await ask(
              "(function(){var l=(window.__gv&&window.__gv.log)||[];var s=0,p=0;l.forEach(function(e){if(e.sabr)s++;else if(e.mime)p++;});return s+'|'+p;})()");
          final parts = counts.split('|');
          final sabrN = parts.length == 2 ? (int.tryParse(parts[0]) ?? 0) : 0;
          final plainN = parts.length == 2 ? (int.tryParse(parts[1]) ?? 0) : 0;
          if (sabrN >= 2 && plainN == 0) {
            if (!reloaded) {
              reloaded = true;
              _dl.log('The download page is using YouTube\'s new streaming mode. Reloading it once...');
              try {
                await web.reload();
              } catch (_) {}
              started = DateTime.now();
              until = DateTime.now().add(const Duration(seconds: 40));
            } else {
              _lastPageSabr = true;
              break;
            }
          }
        }
      }
      if (_lastPageSabr) return null;
      var diag = await ask('window.__gvDiag ? window.__gvDiag() : "hook missing"');
      if (diag.length > 700) diag = diag.substring(0, 700);
      _dl.log('Download page report after 45 s: $diag');
    } catch (e) {
      _dl.log('Opening the song in the download page failed ($e)');
    } finally {
      try {
        await web.runJavaScript(
            "var v=document.querySelector('video');if(v){v.pause();}");
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _hlsManifestFor(String vid) async {
    final clients = <Map<String, dynamic>>[
      {
        'clientName': 'IOS',
        'clientVersion': '20.10.4',
        'deviceMake': 'Apple',
        'deviceModel': 'iPhone16,2',
        'osName': 'iPhone',
        'osVersion': '18.3.2.22D82',
        'hl': 'en',
        'gl': 'US',
        'userAgent': _uaIos,
      },
      {
        'clientName': 'IOS',
        'clientVersion': '19.05.36',
        'deviceModel': 'iPhone14,5',
        'osVersion': '16.5',
        'hl': 'en',
        'gl': 'US',
        'userAgent':
            'com.google.ios.youtube/19.05.36 (iPhone14,5; U; CPU iOS 16_5 like Mac OS X)',
      },
    ];
    const hosts = ['youtubei.googleapis.com', 'www.youtube.com'];
    for (final c in clients) {
      for (final host in hosts) {
        try {
          final res = await http
              .post(
                Uri.parse('https://$host/youtubei/v1/player?prettyPrint=false'),
                headers: {
                  'Content-Type': 'application/json',
                  'User-Agent': '${c['userAgent']}',
                  'X-YouTube-Client-Name': '5',
                  'X-YouTube-Client-Version': '${c['clientVersion']}',
                },
                body: jsonEncode({
                  'context': {'client': c},
                  'videoId': vid,
                  'contentCheckOk': true,
                  'racyCheckOk': true,
                }),
              )
              .timeout(const Duration(seconds: 20));
          if (res.statusCode != 200) {
            _dl.log('Player request ${c['clientVersion']}@$host: HTTP ${res.statusCode}');
            continue;
          }
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          final sd = data is Map ? data['streamingData'] : null;
          final hls = sd is Map ? (sd['hlsManifestUrl'] ?? sd['hlsManifestURL']) : null;
          if (hls is String && hls.isNotEmpty) {
            _dl.log('Got the HLS playlist (iPhone app ${c['clientVersion']})');
            return hls;
          }
          final ps = data is Map ? data['playabilityStatus'] : null;
          _dl.log(
              'No HLS from ${c['clientVersion']}@$host (${ps is Map ? '${ps['status']}: ${ps['reason'] ?? ''}' : 'no status'}; streamingData: ${sd is Map ? sd.keys.join(',') : 'none'})');
        } catch (e) {
          _dl.log('Player request ${c['clientVersion']}@$host failed ($e)');
        }
      }
    }
    return null;
  }

  Uri? _hlsPickAudio(Uri base, String master, String quality) {
    final audioOnly = <({int bw, Uri uri})>[];
    final renditions = <Uri>[];
    final muxed = <({int bw, Uri uri})>[];
    final lines = const LineSplitter().convert(master);
    Map<String, String> attrs(String l) {
      final m = <String, String>{};
      for (final x in RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)')
          .allMatches(l.substring(l.indexOf(':') + 1))) {
        var v = x.group(2)!;
        if (v.startsWith('"')) v = v.substring(1, v.length - 1);
        m[x.group(1)!] = v;
      }
      return m;
    }

    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].trim();
      if (l.startsWith('#EXT-X-MEDIA:')) {
        final a = attrs(l);
        if (a['TYPE'] == 'AUDIO' && a['URI'] != null) {
          renditions.add(base.resolve(a['URI']!));
        }
      } else if (l.startsWith('#EXT-X-STREAM-INF:')) {
        final a = attrs(l);
        final bw = int.tryParse(a['BANDWIDTH'] ?? '') ?? 0;
        var j = i + 1;
        while (j < lines.length &&
            (lines[j].trim().isEmpty || lines[j].trim().startsWith('#'))) {
          j++;
        }
        if (j >= lines.length) continue;
        final u = base.resolve(lines[j].trim());
        final codecs = a['CODECS'] ?? '';
        if (codecs.contains('mp4a') &&
            !RegExp(r'avc1|vp0?9|av01|hvc1|hev1').hasMatch(codecs)) {
          audioOnly.add((bw: bw, uri: u));
        } else {
          muxed.add((bw: bw, uri: u));
        }
      }
    }
    int byBw(({int bw, Uri uri}) a, ({int bw, Uri uri}) b) => a.bw.compareTo(b.bw);
    if (audioOnly.isNotEmpty) {
      audioOnly.sort(byBw);
      return quality == 'small'
          ? audioOnly.first.uri
          : (quality == 'medium'
              ? audioOnly[audioOnly.length ~/ 2].uri
              : audioOnly.last.uri);
    }
    if (renditions.isNotEmpty) return renditions.last;
    if (muxed.isNotEmpty) {
      muxed.sort(byBw);
      return muxed.first.uri;
    }
    return null;
  }

  Uint8List _umpMedia(Uint8List d) {
    final out = BytesBuilder(copy: false);
    var i = 0;
    int? varint() {
      if (i >= d.length) return null;
      final b = d[i];
      final n = b < 128 ? 1 : b < 192 ? 2 : b < 224 ? 3 : b < 240 ? 4 : 5;
      if (i + n > d.length) return null;
      int v;
      switch (n) {
        case 1:
          v = b;
          break;
        case 2:
          v = (b & 0x3f) + 64 * d[i + 1];
          break;
        case 3:
          v = (b & 0x1f) + 32 * (d[i + 1] + 256 * d[i + 2]);
          break;
        case 4:
          v = (b & 0x0f) + 16 * (d[i + 1] + 256 * (d[i + 2] + 256 * d[i + 3]));
          break;
        default:
          v = d[i + 1] + 256 * (d[i + 2] + 256 * (d[i + 3] + 256 * d[i + 4]));
      }
      i += n;
      return v;
    }

    while (i < d.length) {
      final type = varint();
      final size = varint();
      if (type == null || size == null || i + size > d.length) break;
      if (type == 21 && size > 1) {
        out.add(Uint8List.sublistView(d, i + 1, i + size));
      }
      i += size;
    }
    return out.takeBytes();
  }

  Uint8List _tsToAdts(Uint8List d, Set<int> pids) {
    final out = BytesBuilder(copy: false);
    for (var i = 0; i + 188 <= d.length; i += 188) {
      if (d[i] != 0x47) continue;
      final pusi = (d[i + 1] & 0x40) != 0;
      final pid = ((d[i + 1] & 0x1F) << 8) | d[i + 2];
      final afc = (d[i + 3] >> 4) & 3;
      if (afc == 0 || afc == 2) continue;
      var p = i + 4;
      if (afc == 3) p += 1 + d[i + 4];
      final end = i + 188;
      if (p >= end) continue;
      if (pusi) {
        if (end - p >= 9 && d[p] == 0 && d[p + 1] == 0 && d[p + 2] == 1) {
          final sid = d[p + 3];
          if (sid >= 0xC0 && sid <= 0xDF) {
            pids.add(pid);
            p += 9 + d[p + 8];
            if (p < end) out.add(Uint8List.sublistView(d, p, end));
          } else {
            pids.remove(pid);
          }
        }
        continue;
      }
      if (pids.contains(pid)) out.add(Uint8List.sublistView(d, p, end));
    }
    return out.takeBytes();
  }

  Future<({Uri url, int size})?> _iosAppAudioLink(String vid, int wantBytes,
      {required bool smallest, required bool middle}) async {
    final res = await http
        .post(
          Uri.parse(
              'https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false'),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': _uaIos,
            'X-YouTube-Client-Name': '5',
            'X-YouTube-Client-Version': '20.10.4',
          },
          body: jsonEncode({
            'context': {
              'client': {
                'clientName': 'IOS',
                'clientVersion': '20.10.4',
                'deviceMake': 'Apple',
                'deviceModel': 'iPhone16,2',
                'osName': 'iPhone',
                'osVersion': '18.3.2.22D82',
                'hl': 'en',
                'gl': 'US',
                'userAgent': _uaIos,
              },
            },
            'videoId': vid,
            'contentCheckOk': true,
            'racyCheckOk': true,
          }),
        )
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) return null;
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final formats = (data is Map ? data['streamingData'] : null) is Map
        ? (data['streamingData']['adaptiveFormats'] as List? ?? const [])
        : const [];
    final audio = <Map<String, dynamic>>[];
    for (final f in formats) {
      if (f is! Map) continue;
      final mime = '${f['mimeType'] ?? ''}';
      if (!mime.startsWith('audio/mp4')) continue;
      if (f['url'] is! String || f['contentLength'] == null) continue;
      audio.add(Map<String, dynamic>.from(f));
    }
    if (audio.isEmpty) return null;
    audio.sort((a, b) =>
        ((a['bitrate'] as num?) ?? 0).compareTo((b['bitrate'] as num?) ?? 0));
    Map<String, dynamic> pick = smallest
        ? audio.first
        : (middle ? audio[audio.length ~/ 2] : audio.last);
    for (final f in audio) {

      if (int.tryParse('${f['contentLength']}') == wantBytes) pick = f;
    }
    final size = int.tryParse('${pick['contentLength']}') ?? 0;
    if (size <= 0) return null;
    return (url: Uri.parse(pick['url'] as String), size: size);
  }

  Future<String> _downloadWithDart(
      String vid, String id, Directory dir, DownloadTask task) async {
    final yt = yt_explode.YoutubeExplode();
    var cancelled = false;
    final hooks = <VoidCallback>[];
    _dartCancels[id] = () {
      cancelled = true;
      for (final h in List.of(hooks)) {
        h();
      }
    };
    void check() {
      if (cancelled) throw Exception('Cancelled');
    }

    final out = File('${dir.path}/$id.m4a');
    var outPath = out.path;
    var rawAdts = false;
    IOSink? sink;
    try {
      _dl.log('Asking YouTube for the audio streams...');
      yt_explode.StreamInfo? info;
      Object? infoError;
      try {
        final manifest = await yt.videos.streamsClient
            .getManifest(vid)
            .timeout(const Duration(seconds: 60));
        check();
        final aac = manifest.audioOnly
            .where((s) => s.container == yt_explode.StreamContainer.mp4)
            .toList()
          ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
        if (aac.isEmpty) {
          throw Exception('YouTube gave no audio stream the iPhone can play');
        }
        info = _quality == 'small'
            ? aac.first
            : (_quality == 'medium' ? aac[aac.length ~/ 2] : aac.last);
      } catch (e) {
        check();
        infoError = e;
        var why = e.toString().split('\n').first;
        if (why.length > 90) why = '${why.substring(0, 90)}...';
        _dl.log('The library could not read this song ($why). Trying the page link...');
      }

      var total = info?.size.totalBytes ?? (1 << 30);
      var link = info?.url ?? Uri.parse('about:blank');
      if (info != null) {
        _dl.log(
            'Downloading ${(info.bitrate.kiloBitsPerSecond).round()} kbps AAC (${(total / 1048576).toStringAsFixed(1)} MB)');
      }
      task.status = DlStatus.downloading;
      task.total = total;
      _dl.changed();

      var got = 0, step = -1;
      final clock = Stopwatch()..start();
      void progress() {
        task.received = got;
        task.total = total;
        if (total > 0) task.pct = got * 100 / total;
        final secs = clock.elapsedMilliseconds / 1000;
        if (secs > 0.5) task.speedKBs = got / 1024 / secs;
        final st = total > 0 ? (got * 10 ~/ total) : 0;
        if (st > step) {
          step = st;
          _dl.log('Downloaded ${st * 10}%');
        }
        _dl.changed();
      }

      Future<void> restart() async {
        await sink?.close();
        sink = out.openWrite();
        got = 0;
        step = -1;
      }

      sink = out.openWrite();

      Future<void> viaLibrary() async {
        final done = Completer<void>();
        var lastData = DateTime.now();
        Timer? idle;
        StreamSubscription<List<int>>? sub;
        void finish([Object? err]) {
          idle?.cancel();
          if (done.isCompleted) return;
          if (err == null) {
            done.complete();
          } else {
            done.completeError(err);
          }
        }

        sub = yt.videos.streamsClient.get(info!).listen((chunk) {
          lastData = DateTime.now();
          sink!.add(chunk);
          got += chunk.length;
          progress();
        }, onError: (Object e) => finish(e), onDone: () => finish(),
            cancelOnError: true);
        final hook = () {
          sub?.cancel();
          finish(Exception('Cancelled'));
        };
        hooks.add(hook);
        idle = Timer.periodic(const Duration(seconds: 2), (_) {
          if (DateTime.now().difference(lastData).inSeconds >= 12) {
            sub?.cancel();
            finish(TimeoutException('no data for 12 seconds'));
          }
        });
        try {
          await done.future;
        } finally {
          idle?.cancel();
          hooks.remove(hook);

          sub?.cancel();
        }
      }

      Future<void> viaPieces(Uri start, String ua,
          {required bool refresh,
          bool post = false,
          bool ump = false,
          List<int> postBody = const []}) async {
        final client = http.Client();
        final hook = () => client.close();
        hooks.add(hook);
        var url = start;
        final web = ua == _uaSafari;
        try {
          const piece = 1024 * 1024;
          while (got < total) {
            check();
            final end = math.min(got + piece, total) - 1;
            Object? lastErr;
            http.Response? ok;
            Uint8List? okData;
            for (var attempt = 0; attempt < 4 && ok == null; attempt++) {
              check();
              if (attempt == 2 && refresh) {
                try {
                  final fresh = await yt.videos.streamsClient
                      .getManifest(vid)
                      .timeout(const Duration(seconds: 30));
                  for (final s in fresh.audioOnly) {
                    if (s.container == yt_explode.StreamContainer.mp4 &&
                        s.size.totalBytes == total) {
                      url = s.url;
                      ua = _uaForLink(url);
                      break;
                    }
                  }
                } catch (_) {}
              }
              final asQuery = post || attempt.isOdd;
              final target =
                  asQuery ? Uri.parse('$url&range=$got-$end') : url;
              try {
                final hdrs = {
                  'User-Agent': ua,
                  'Accept': '*/*',
                  'Accept-Language': 'en-US,en;q=0.9',
                  if (!asQuery) 'Range': 'bytes=$got-$end',
                  if (web) 'Origin': 'https://music.youtube.com',
                  if (web) 'Referer': 'https://music.youtube.com/',
                };
                final res = await (post
                        ? client.post(target, headers: hdrs, body: postBody)
                        : client.get(target, headers: hdrs))
                    .timeout(const Duration(seconds: 25));
                check();
                if ((res.statusCode == 200 || res.statusCode == 206) &&
                    res.bodyBytes.isNotEmpty) {
                  if (res.statusCode == 200 && got > 0 && !asQuery) {
                    lastErr = 'YouTube ignored the range request';
                  } else {
                    final data = ump ? _umpMedia(res.bodyBytes) : res.bodyBytes;
                    if (data.isEmpty) {
                      lastErr = 'no audio inside the reply';
                    } else {
                      ok = res;
                      okData = data;
                    }
                  }
                } else {
                  lastErr = 'HTTP ${res.statusCode}';
                }
              } on TimeoutException {
                lastErr = 'timeout';
              } catch (e) {
                check();
                lastErr = e;
              }
              if (ok == null) {
                await Future<void>.delayed(const Duration(milliseconds: 400));
              }
            }
            if (ok == null) {
              throw Exception('YouTube refused the download ($lastErr)');
            }
            sink!.add(okData!);
            got += okData.length;
            progress();
            if (ok.statusCode == 200 && okData.length >= total) break;
          }
        } finally {
          hooks.remove(hook);
          client.close();
        }
      }

      Object? failure = infoError;

      var page = await _pageAudioLink(vid, quiet: true);
      if (page == null) {
        _dl.log('Opening this song in the YouTube page to get its link...');
        page = await _openInPageForLink(vid);
        check();
      }
      if (page != null) {
        _dl.log('Using the audio link from the YouTube page...');
        final keepTotal = total;
        total = page.size;
        try {
          await viaPieces(page.url, _uaSafari,
              refresh: false,
              post: page.post,
              ump: page.ump,
              postBody: page.body);
        } catch (e) {
          check();
          _dl.log('Page link failed ($e)');
        }
        if (got < total) {
          total = keepTotal;
          await restart();
        }
      } else {
        _dl.log('Could not get a link from the YouTube page for this song');
        if (_lastPageSabr) {
          throw Exception(
              'YouTube is giving this session its new streaming mode, which cannot be downloaded yet. Go to Sound tab > Reset page session, wait for the page to load, play a song and try again.');
        }
        if (info == null) {
          failure = Exception(
              'Could not get this song. Play it in the Music tab for a few seconds (let any ad finish), then download it again.');
        }
      }

      Future<bool> viaHls() async {
        _dl.log('Asking YouTube for the HLS playlist...');
        final manifestUrl = await _hlsManifestFor(vid);
        check();
        if (manifestUrl == null) throw Exception('YouTube gave no HLS playlist');
        final client = http.Client();
        final hook = () => client.close();
        hooks.add(hook);
        try {
          Future<http.Response> fetch(Uri u) async {
            Object? err;
            for (var a = 0; a < 3; a++) {
              check();
              try {
                final r = await client
                    .get(u, headers: {'User-Agent': _uaIos})
                    .timeout(const Duration(seconds: 25));
                check();
                if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) return r;
                err = 'HTTP ${r.statusCode}';
              } on TimeoutException {
                err = 'timeout';
              } catch (e) {
                check();
                err = e;
              }
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
            throw Exception('HLS: $err');
          }

          final base = Uri.parse(manifestUrl);
          var text = utf8.decode((await fetch(base)).bodyBytes, allowMalformed: true);
          var mediaBase = base;
          if (!text.contains('#EXTINF')) {
            final pick = _hlsPickAudio(base, text, _quality);
            if (pick == null) throw Exception('no audio playlist in the HLS list');
            mediaBase = pick;
            text = utf8.decode((await fetch(pick)).bodyBytes, allowMalformed: true);
          }
          Uri? init;
          final segs = <Uri>[];
          for (final l in const LineSplitter().convert(text)) {
            final t = l.trim();
            if (t.isEmpty) continue;
            if (t.startsWith('#EXT-X-MAP:')) {
              final m = RegExp(r'URI="([^"]+)"').firstMatch(t);
              if (m != null) init = mediaBase.resolve(m.group(1)!);
            } else if (!t.startsWith('#')) {
              segs.add(mediaBase.resolve(t));
            }
          }
          if (segs.isEmpty) throw Exception('the HLS playlist has no parts');
          _dl.log('HLS: ${segs.length} parts');
          await restart();
          var raw = false;
          final pids = <int>{};
          if (init != null) {
            final r = await fetch(init);
            sink!.add(r.bodyBytes);
            got += r.bodyBytes.length;
          }
          for (var i = 0; i < segs.length; i++) {
            final r = await fetch(segs[i]);
            var bytes = r.bodyBytes;
            if (i == 0 && init == null && bytes[0] == 0x47) raw = true;
            if (raw) bytes = _tsToAdts(bytes, pids);
            sink!.add(bytes);
            got += bytes.length;
            total = got * segs.length ~/ (i + 1);
            progress();
          }
          total = got;
          return raw;
        } finally {
          hooks.remove(hook);
          client.close();
        }
      }

      if (got < total) {
        final keepTotal = total;
        try {
          rawAdts = await viaHls();
        } catch (e) {
          check();
          _dl.log('HLS failed ($e)');
          total = keepTotal;
          rawAdts = false;
          await restart();
        }
      }
      try {
        if (info != null && got < total) await viaLibrary();
      } catch (e) {
        check();
        _dl.log('Direct stream failed ($e). Trying small pieces...');
      }
      if (info != null && got < total) {
        try {
          await viaPieces(link, _uaForLink(link), refresh: true);
        } catch (e) {
          check();
          failure = e;
          _dl.log('Small pieces failed ($e). Trying the iPhone app link...');
        }
      }
      if (got < total) {
        try {
          final alt = await _iosAppAudioLink(vid, total,
              smallest: _quality == 'small', middle: _quality == 'medium');
          check();
          if (alt == null) throw Exception('no audio link from the iPhone app endpoint');
          if (alt.size != total) {
            total = alt.size;
            await restart();
          }
          link = alt.url;
          await viaPieces(link, _uaIos, refresh: false);
          failure = null;
        } catch (e) {
          check();
          _dl.log('iPhone app link failed ($e)');
          failure ??= e;
        }
      }
      await sink?.close();
      sink = null;
      check();
      if (got < total) {
        final f = failure;
        throw f is Exception ? f : Exception(f ?? 'Download ended early ($got of $total bytes)');
      }
      if (rawAdts) {

        outPath = '${dir.path}/$id.aac';
        await out.rename(outPath);
      }
      return outPath;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      _dartCancels.remove(id);
      yt.close();
    }
  }

  String _errText(Object e) =>
      e is PlatformException ? (e.message ?? e.code) : e.toString();

  Future<void> _loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('playlists') ?? [];
    final list = <PlaylistFolder>[];
    for (final s in raw) {
      try {
        list.add(PlaylistFolder.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    if (mounted) setState(() => _playlists = list);
    _touch();
  }

  Future<void> _persistPlaylists() async {
    if (mounted) setState(() {});
    _touch();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'playlists', _playlists.map((f) => jsonEncode(f.toJson())).toList());
  }

  PlaylistFolder? _playlistById(String id) {
    for (final f in _playlists) {
      if (f.id == id) return f;
    }
    return null;
  }

  bool _inFolder(PlaylistFolder f, LocalSong s) =>
      f.paths.contains(s.path) || f.known.contains(_vidOf(s));

  List<LocalSong> _songsOfFolder(PlaylistFolder f) =>
      _localSongs.where((s) => _inFolder(f, s)).toList();

  List<LocalSong>? _queueFor(LocalSong s) {
    for (final f in _playlists) {
      if (_inFolder(f, s)) return _songsOfFolder(f);
    }
    return null;
  }

  PlaylistFolder _newPlaylist(_PlaylistData pl, String url) {
    final listId = Uri.tryParse(url)?.queryParameters['list'] ?? '';
    final f = PlaylistFolder(
      id: pl.id,
      name: pl.title.isNotEmpty ? pl.title : 'Playlist',
      url: listId.isNotEmpty
          ? 'https://music.youtube.com/playlist?list=$listId'
          : url,
    );
    _playlists = [..._playlists, f];
    _persistPlaylists();
    return f;
  }

  void _refreshPlaylist(PlaylistFolder f, _PlaylistData pl) {
    if (pl.title.isNotEmpty) f.name = pl.title;
    for (final s in pl.songs) {
      final i = _findLocal(s['id']!, s['title']!, s['artist'] ?? '');
      if (i >= 0) {
        f.known.add(s['id']!);
        f.paths.add(_localSongs[i].path);
      }
    }
    _persistPlaylists();
  }

  void _removePlaylist(PlaylistFolder f) {
    _playlists = _playlists.where((x) => x != f).toList();
    _persistPlaylists();
    _toast('Folder removed. The songs are still in the Download folder.');
  }

  void _setSort(int mode) {
    setState(() => _sortMode = mode);
    SharedPreferences.getInstance().then((p) => p.setInt('sort_mode', mode));
    _touch();
  }

  int _addedMs(LocalSong s) {
    return _addedCache.putIfAbsent(s.path, () {
      final name = s.path.split('/').last;
      final m = RegExp(r'^(\d+)_').firstMatch(name);
      final v = m == null ? null : int.tryParse(m.group(1)!);
      if (v != null && v > 1000000000000000 && v < 4000000000000000) {
        return v ~/ 1000;
      }
      try {
        return File(s.path).lastModifiedSync().millisecondsSinceEpoch;
      } catch (_) {
        return 0;
      }
    });
  }

  List<LocalSong> _sorted(List<LocalSong> list) {
    int byTitle(LocalSong a, LocalSong b) =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase());
    switch (_sortMode) {
      case 1:
        list.sort((a, b) {
          final c = _addedMs(a).compareTo(_addedMs(b));
          return c != 0 ? c : byTitle(a, b);
        });
        break;
      case 2:
        list.sort(byTitle);
        break;
      case 3:
        list.sort((a, b) {
          final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          return c != 0 ? c : byTitle(a, b);
        });
        break;
      default:
        list.sort((a, b) {
          final c = _addedMs(b).compareTo(_addedMs(a));
          return c != 0 ? c : byTitle(a, b);
        });
    }
    return list;
  }

  void _openFolder(PlaylistFolder? f) {
    final search = ValueNotifier<String>('');
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FolderPage(
        query: search,
        onShuffle: _shuffleQueue,
        title: f?.name ?? 'Download',
        refresh: Listenable.merge([_libTick, _dl]),
        songs: () => _sorted(
            f == null ? List.of(_localSongs) : _songsOfFolder(f)),
        sortMode: () => _sortMode,
        onSort: _setSort,
        playing: () => (_localIdx >= 0 && _localIdx < _localSongs.length)
            ? _localSongs[_localIdx]
            : null,
        onPlay: _playQueue,
        onRemove: _removeLocal,
        onReplace: _replaceUploaded,
        onUpdate: f == null
            ? null
            : () => _downloadPlaylistFrom(f.url, folder: f),
        manager: _dl,
        folderId: f?.id,
      ),
    ));
  }

  Future<_PlaylistData> _readPlaylistDart(String url) async {
    final id = Uri.tryParse(url)?.queryParameters['list'] ?? url;
    var title = '';
    var songs = <Map<String, String>>[];
    final yt = yt_explode.YoutubeExplode();
    try {
      try {
        final p = await yt.playlists.get(id).timeout(const Duration(seconds: 30));
        title = p.title.trim();
      } catch (e) {
        _dl.log('Could not read the playlist name ($e)');
      }

      songs = await _readPlaylistBrowse(id);
      _dl.log('YouTube Music request found ${songs.length} songs');
      if (songs.isNotEmpty) return _PlaylistData(id, title, songs);
      try {
        final seen = <String>{};
        var unavailable = 0;
        await for (final v
            in yt.playlists.getVideos(id).timeout(const Duration(seconds: 60))) {
          final vid = v.id.value;
          final t = v.title.trim();
          if (vid.length != 11 ||
              t.isEmpty ||
              t == '[Private video]' ||
              t == '[Deleted video]') {
            unavailable++;
            continue;
          }
          if (!seen.add(vid)) continue;
          songs.add({'id': vid, 'title': t, 'artist': v.author});
        }
        if (unavailable > 0) {
          _dl.log('Skipping $unavailable private or deleted entries');
        }
      } catch (e) {
        _dl.log('youtube_explode could not list the songs ($e)');
      }
    } finally {
      yt.close();
    }
    _dl.log('youtube_explode found ${songs.length} songs');
    return _PlaylistData(id, title, songs);
  }

  String _runsText(dynamic t) {
    if (t is! Map) return '';
    final s = t['simpleText'];
    if (s is String) return s.trim();
    final runs = t['runs'];
    if (runs is List) {
      return runs.map((r) => r is Map ? '${r['text'] ?? ''}' : '').join().trim();
    }
    return '';
  }

  Future<List<Map<String, String>>> _readPlaylistBrowse(String id) async {
    final songs = <Map<String, String>>[];
    final seen = <String>{};
    const version = '1.20250929.03.00';
    final context = <String, dynamic>{
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': version,
        'hl': 'en',
        'gl': 'US',
      },
    };
    Future<dynamic> post(Map<String, dynamic> body) async {
      final res = await http
          .post(
            Uri.parse(
                'https://music.youtube.com/youtubei/v1/browse?prettyPrint=false'),
            headers: {
              'Content-Type': 'application/json',
              'X-YouTube-Client-Name': '67',
              'X-YouTube-Client-Version': version,
            },
            body: jsonEncode({'context': context, ...body}),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        _dl.log('Playlist request: HTTP ${res.statusCode}');
        return null;
      }
      return jsonDecode(utf8.decode(res.bodyBytes));
    }

    final tokens = <String>[];
    void walk(dynamic n) {
      if (n is List) {
        for (final e in n) {
          walk(e);
        }
        return;
      }
      if (n is! Map) return;
      final item = n['musicResponsiveListItemRenderer'];
      if (item is Map) {
        final vid = item['playlistItemData']?['videoId'];
        final cols = item['flexColumns'];
        if (vid is String && vid.length == 11 && cols is List && cols.isNotEmpty) {
          String col(int i) {
            if (i >= cols.length || cols[i] is! Map) return '';
            return _runsText(
                cols[i]['musicResponsiveListItemFlexColumnRenderer']?['text']);
          }

          final t = col(0);
          if (t.isNotEmpty &&
              t != '[Private video]' &&
              t != '[Deleted video]' &&
              seen.add(vid)) {
            songs.add({'id': vid, 'title': t, 'artist': col(1)});
          }
        }
      }

      final c = n['continuationItemRenderer'];
      if (c is Map) {
        final t = c['continuationEndpoint']?['continuationCommand']?['token'];
        if (t is String) tokens.add(t);
      }
      final nx = n['nextContinuationData'];
      if (nx is Map && nx['continuation'] is String) {
        tokens.add(nx['continuation'] as String);
      }
      for (final v in n.values) {
        walk(v);
      }
    }

    try {
      var data = await post({'browseId': 'VL$id'});
      final used = <String>{};
      var pages = 0;
      while (data != null && pages < 200) {
        tokens.clear();
        walk(data);
        pages++;
        if (tokens.isEmpty) break;
        final token = tokens.last;
        if (!used.add(token)) break;
        data = await post({'continuation': token});
      }
    } catch (e) {
      _dl.log('YouTube Music request failed ($e)');
    }
    return songs;
  }

  Future<_PlaylistData> _readPlaylist(String url) async {
    if (Platform.isIOS) return _readPlaylistDart(url);
    final raw = await _ytdlp
        .invokeMethod<String>('list', {'url': url})
        .timeout(const Duration(seconds: 120));
    final text = (raw ?? '').trim();
    final start = text.indexOf('{');
    if (start < 0) throw Exception('YouTube returned nothing for that link');
    final data = jsonDecode(text.substring(start));
    final qid = Uri.tryParse(url)?.queryParameters['list'] ?? '';
    final rootId = (data is Map && data['id'] is String) ? data['id'] as String : '';
    final rootTitle =
        (data is Map && data['title'] is String) ? (data['title'] as String).trim() : '';

    final songs = <Map<String, String>>[];
    final seen = <String>{};
    var unavailable = 0;
    void walk(dynamic node) {
      if (node is! Map) return;
      final entries = node['entries'];
      if (entries is List) {
        for (final e in entries) {
          walk(e);
        }
        return;
      }
      final id = node['id'];
      final title = ((node['title'] as String?) ?? '').trim();
      if (id is! String || id.length != 11) return;
      if (title.isEmpty ||
          title == '[Private video]' ||
          title == '[Deleted video]') {
        unavailable++;
        return;
      }
      if (!seen.add(id)) return;
      songs.add({
        'id': id,
        'title': title,
        'artist': (node['channel'] ?? node['uploader'] ?? '').toString(),
      });
    }

    walk(data);
    if (unavailable > 0) {
      _dl.log('Skipping $unavailable private or deleted entries');
    }
    return _PlaylistData(
        qid.isNotEmpty ? qid : (rootId.isNotEmpty ? rootId : url),
        rootTitle,
        songs);
  }

  Future<String?> _askPlaylistUrl() async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add playlist'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste a public or unlisted playlist link, or a channel\'s Videos page. Private playlists do not work (set them to Unlisted first).',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: 'https://...',
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste),
                  onPressed: () async {
                    final d = await Clipboard.getData(Clipboard.kTextPlain);
                    if (d?.text != null) c.text = d!.text!.trim();
                  },
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Find songs')),
        ],
      ),
    );
  }

  void _endReading() {
    _readingPlaylist = false;
    _dl.readingStatus = null;
    _dl.changed();
  }

  Future<void> _persistQueue() async {
    final items = <PendingSong>[
      if (_activeSong != null && !_batchCancel) _activeSong!,
      ..._dl.pending,
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'dl_queue', items.map((p) => jsonEncode(p.toJson())).toList());
  }

  void _queueChanged() {
    _persistQueue();
    if (!_queueRunning && _dl.pending.isEmpty && _dl.onResume != null) {
      _dl.batchStatus = null;
      _dl.onStopBatch = null;
      _dl.onResume = null;
      _dl.changed();
    }
    if (mounted) setState(() {});
  }

  void _cancelCurrent() {
    final s = _activeSong;
    if (s == null) return;
    _skipCurrent = true;
    _dl.log('Cancelling "${s.title}"...');
    final id = _activeId;
    if (id != null) _cancelDownload(id);
  }

  int _enqueue(Iterable<PendingSong> songs) {
    var n = 0;
    for (final s in songs) {
      if (s.vid.isEmpty) continue;
      if (_activeSong?.vid == s.vid || _dl.pending.any((p) => p.vid == s.vid)) {
        continue;
      }
      if (_alreadyHave(s.vid, s.title, s.artist)) continue;
      _dl.pending.add(s);
      n++;
    }
    if (n > 0) {
      _persistQueue();
      _dl.changed();
      if (mounted) setState(() {});
    }
    _pumpQueue();
    return n;
  }

  Future<void> _loadQueue() async {
    await _cleanLeftovers();
    final prefs = await SharedPreferences.getInstance();
    final back = <PendingSong>[];
    for (final raw in prefs.getStringList('dl_queue') ?? <String>[]) {
      try {
        final p = PendingSong.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (p.vid.isEmpty) continue;
        if (_alreadyHave(p.vid, p.title, p.artist)) {
          _linkToFolder(p);
          continue;
        }
        if (_activeSong?.vid == p.vid || _dl.pending.any((q) => q.vid == p.vid)) {
          continue;
        }
        back.add(p);
      } catch (_) {}
    }
    if (!mounted) return;
    _dl.pending.insertAll(0, back);
    _persistQueue();
    if (back.isNotEmpty) {
      _dl.log('Carrying on with ${back.length} song(s) from last time');
      _toast('Carrying on with ${back.length} download(s) from last time');
    }
    _dl.changed();
    _pumpQueue();
  }

  Future<void> _cleanLeftovers() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/music');
      if (!await dir.exists()) return;
      final keep = _localSongs.map((s) => s.path).toSet();
      final raw = RegExp(r'^\d+_[a-z0-9_-]{11}\.(webm|m4a|opus)$');
      await for (final e in dir.list()) {
        if (e is! File || keep.contains(e.path)) continue;
        final name = e.path.split('/').last.toLowerCase();
        if (name.contains('.part') ||
            name.endsWith('.ytdl') ||
            raw.hasMatch(name)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _linkToFolder(PendingSong s) {
    final id = s.folderId;
    if (id == null) return;
    final f = _playlistById(id);
    if (f == null) return;
    final li = _findLocal(s.vid, s.title, s.artist);
    if (li < 0) return;
    f.known.add(s.vid);
    f.paths.add(_localSongs[li].path);
    _persistPlaylists();
  }

  Future<void> _pumpQueue() async {
    if (_queueRunning || !mounted || _dl.pending.isEmpty) return;
    _queueRunning = true;
    _batchCancel = false;
    _dl.onResume = null;
    _dl.onStopBatch = _confirmStop;
    _dl.onCancelCurrent = _cancelCurrent;
    var saved = 0, failed = 0, strikes = 0, n = 0;
    var pausedReason = '';
    var wasStopped = false;
    var waitKind = '';
    var outdatedHint = false;
    try {
      while (mounted && _dl.pending.isNotEmpty && !_batchCancel) {

        if (!_dlWarm) {
          final left = math.max(0, _warmNeedSecs - _warmSecs);
          _dl.batchStatus =
              'Play a song for $left more second(s) (or sign in to YouTube Music) so downloads work';
          _dl.changed();
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        final wifiBlocked = _wifiOnly && !await _onWifi();
        final offline = !wifiBlocked && !await _online();
        if (wifiBlocked || offline) {
          final kind = wifiBlocked ? 'wifi' : 'net';
          _dl.batchStatus = wifiBlocked
              ? 'Waiting for Wi-Fi (Wi-Fi only is on)'
              : 'Waiting for internet';
          if (waitKind != kind) {
            waitKind = kind;
            _dl.log(wifiBlocked
                ? 'Waiting for Wi-Fi: ${_dl.pending.length} song(s) will download when connected'
                : 'No internet: ${_dl.pending.length} song(s) will download when it is back');
          }
          _dl.changed();
          await Future.delayed(const Duration(seconds: 5));
          continue;
        }
        waitKind = '';
        final s = _dl.pending.removeAt(0);
        _activeSong = s;
        _skipCurrent = false;
        _persistQueue();
        if (_alreadyHave(s.vid, s.title, s.artist)) {
          _linkToFolder(s);
          _activeSong = null;
          _persistQueue();
          continue;
        }
        n++;
        _dl.batchStatus = 'Download list: song $n of ${n + _dl.pending.length}';
        _dl.changed();
        if (mounted) {
          setState(() {
            _downloading = true;
            _dlProgress = null;
          });
        }
        final t = await _downloadVideo(
          vid: s.vid,
          title: s.title,
          artist: s.artist,
          art: s.art,
          toast: false,
          folderId: s.folderId,
          resumeId: _resumeIds[s.vid],
        );
        _activeSong = null;
        _persistQueue();
        if (_batchCancel) break;
        if (_skipCurrent && t.status != DlStatus.done) {

          _skipCurrent = false;
          t.error = 'Cancelled by you';
          _dl.log('Cancelled: "${s.title}"');
          _retries.remove(s.vid);
          _resumeIds.remove(s.vid);
          continue;
        }
        _skipCurrent = false;
        if (t.status == DlStatus.done) {
          saved++;
          strikes = 0;
          _retries.remove(s.vid);
          _resumeIds.remove(s.vid);
          _linkToFolder(s);
          _failedRound.removeWhere((f) => f.song.vid == s.vid);
          if (s.smart) {
            _toast('Smart download: saved "${s.title}"');
          } else if (s.folderId == null) {
            _toast('Saved "${s.title}" to this device');
          }
        } else {
          final err = (t.error ?? '').toLowerCase();
          final netErr = _isNetworkError(err);
          final lostWifi = _wifiOnly && !await _onWifi();
          if (lostWifi || (netErr && !await _online())) {

            if (_lastAttemptId != null) _resumeIds[s.vid] = _lastAttemptId!;
            _dl.pending.insert(0, s);
            _persistQueue();
            _dl.log(lostWifi
                ? 'Wi-Fi lost: "${s.title}" goes back to the list'
                : 'Internet lost: "${s.title}" goes back to the list');
            n--;
            continue;
          }
          final tries = _retries[s.vid] ?? 0;
          if (netErr && tries < _retryDelays.length) {

            _retries[s.vid] = tries + 1;
            if (_lastAttemptId != null) _resumeIds[s.vid] = _lastAttemptId!;
            _dl.pending.insert(0, s);
            _persistQueue();
            final secs = _retryDelays[tries];
            _dl.log(
                'Connection problem: trying "${s.title}" again in ${secs}s (retry ${tries + 1} of ${_retryDelays.length})');
            n--;
            for (var k = secs; k > 0 && !_batchCancel; k--) {
              _dl.batchStatus = 'Connection problem: retrying in ${k}s';
              _dl.changed();
              await Future.delayed(const Duration(seconds: 1));
            }
            continue;
          }
          final doomed = _resumeIds.remove(s.vid) ?? _lastAttemptId;
          _retries.remove(s.vid);
          if (doomed != null) _dropPartials(doomed);
          failed++;
          strikes++;
          if (s.folderId != null && !s.smart) {
            _failedRound.removeWhere((f) => f.song.vid == s.vid);
            _failedRound.add(_FailedSong(s, (t.why ?? t.error ?? 'Unknown error')));
          }
          if (_looksOutdated(err) && !outdatedHint) {
            outdatedHint = true;
            _dl.log(
                Platform.isIOS
                    ? 'This looks like YouTube changed something. Try again later.'
                    : 'This looks like YouTube changed something. Try Settings > Check for yt-dlp update.',
                error: true);
          }
          if (err.contains('sign in to confirm') ||
              err.contains('rate limit') ||
              err.contains('too many requests') ||
              err.contains('429') ||
              err.contains('try again later')) {
            pausedReason =
                'YouTube seems to be limiting this connection. Try again later, or on mobile data.';
            break;
          }
          if (strikes >= 3) {
            pausedReason = 'Paused after 3 failures in a row.';
            break;
          }
          if (s.folderId == null && !s.smart && mounted) {
            _offerSaveFailed(
                vid: s.vid, title: s.title, artist: s.artist, art: s.art);
          }
        }

        if (_dl.pending.isNotEmpty && !_batchCancel) {
          final next = _dl.pending.first;
          final secs = (next.folderId != null || next.smart) ? 8 : 2;
          _dl.batchStatus =
              'Download list: pausing before song ${n + 1} of ${n + _dl.pending.length}';
          _dl.changed();
          for (var k = 0; k < secs && !_batchCancel; k++) {
            await Future.delayed(const Duration(seconds: 1));
          }
        }
      }
    } finally {
      _queueRunning = false;
      _activeSong = null;
      _skipCurrent = false;
      _dl.onCancelCurrent = null;
      if (_dl.pending.isEmpty) {
        _retries.clear();
        _resumeIds.clear();
      }
      final stopped = _batchCancel;
      wasStopped = stopped;
      _batchCancel = false;
      if (pausedReason.isNotEmpty && _dl.pending.isNotEmpty && mounted) {
        _dl.batchStatus = 'Paused: $pausedReason';
        _dl.onResume = () {
          _dl.onResume = null;
          _pumpQueue();
        };
      } else {
        _dl.batchStatus = null;
        _dl.onStopBatch = null;
        _dl.onResume = null;
      }
      if (outdatedHint && mounted) {
        _toast(Platform.isIOS
            ? 'Downloads may be failing because YouTube changed. Try again later.'
            : 'Downloads may be failing because YouTube changed. Try Settings > Check for yt-dlp update.');
      }
      if (saved + failed > 0) {
        final summary = 'Download list: $saved saved, $failed failed'
            '${stopped ? ' (stopped by you)' : ''}';
        _dl.log(summary);
        if (pausedReason.isNotEmpty) _dl.log(pausedReason, error: true);
        if (pausedReason.isNotEmpty) {
          _toast(pausedReason);
        } else if (saved + failed > 1) {
          _toast(summary);
        }
      }
      _persistQueue();
      _dl.changed();
      if (mounted) {
        setState(() {
          _downloading = false;
          _dlProgress = null;
        });
      }

      if (_dl.pending.isEmpty) _closeDownloadWeb();
    }

    if (!wasStopped && mounted && _dl.pending.isEmpty) {
      await _afterQueue(pausedReason.isNotEmpty);
    }
  }

  Future<void> _afterQueue(bool limited) async {

    _failedRound.removeWhere(
        (f) => _alreadyHave(f.song.vid, f.song.title, f.song.artist));
    if (_failedRound.isEmpty) {
      _autoRound = 0;
      return;
    }
    if (_retryPromptOpen) return;

    if (_retryAuto && !limited && _autoRound < _autoRoundsMax) {
      _autoRound++;
      final list = _failedRound.map((f) => f.song).toList();
      _toast(
          'Retrying ${list.length} failed song(s) in 15 s (try $_autoRound of $_autoRoundsMax)');
      _dl.log('Automatic retry $_autoRound of $_autoRoundsMax: ${list.length} song(s)');
      await Future.delayed(const Duration(seconds: 15));
      if (!mounted || _queueRunning || _dl.pending.isNotEmpty) return;
      _failedRound.clear();
      _enqueue(list);
      return;
    }
    final gaveUp = _retryAuto && !limited;
    if (!_retryAsk && !gaveUp) {

      for (final f in _failedRound) {
        _dl.log('Failed: "${f.song.title}" (${f.reason})', error: true);
      }
      _failedRound.clear();
      return;
    }
    await _askRetryFailed(gaveUp: gaveUp, limited: limited);
  }

  Future<void> _askRetryFailed(
      {required bool gaveUp, required bool limited}) async {
    _retryPromptOpen = true;
    var always = false;
    try {
      final shown = List<_FailedSong>.of(_failedRound);
      final res = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: Text('${shown.length} song(s) did not download'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (gaveUp)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                          'They still failed after the automatic tries.',
                          style: TextStyle(fontSize: 12, color: Colors.white70)),
                    ),
                  if (limited)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                          'YouTube seems to be limiting this connection, so waiting a while before trying again helps.',
                          style: TextStyle(fontSize: 12, color: Colors.white70)),
                    ),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(ctx).size.height * 0.4),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final f in shown)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.error_outline,
                                  size: 20, color: Colors.redAccent),
                              title: Text(f.song.title,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  [
                                    if (f.song.artist.isNotEmpty) f.song.artist,
                                    f.reason,
                                  ].join(' · '),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (!gaveUp)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: always,
                      onChanged: (v) => setD(() => always = v ?? false),
                      title: const Text(
                          'Do not ask again: retry automatically until everything is downloaded',
                          style: TextStyle(fontSize: 13)),
                      subtitle: const Text(
                          'You can change this in Settings.',
                          style: TextStyle(fontSize: 11)),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Not now')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text('Download again (${shown.length})')),
            ],
          ),
        ),
      );
      if (res == true) {
        if (always) _setRetryAuto(true);
        _autoRound = 0;
        final list = _failedRound.map((f) => f.song).toList();
        _failedRound.clear();
        _enqueue(list);
      } else {
        for (final f in _failedRound) {
          _dl.log('Failed: "${f.song.title}" (${f.reason})', error: true);
        }
        _failedRound.clear();
        _autoRound = 0;
      }
    } finally {
      _retryPromptOpen = false;
    }
  }

  static const List<int> _retryDelays = [5, 15, 30];

  bool _looksOutdated(String e) {
    const words = [
      'unable to extract',
      'nsig',
      'signature extraction',
      'requested format is not available',
      'no video formats',
      'http error 403',
      'please report this issue',
      'yt-dlp -u',
      'update yt-dlp',
      'sabr',
    ];
    return words.any(e.contains);
  }

  bool _isNetworkError(String e) {
    if (e.contains('http error 4') ||
        e.contains('unavailable') ||
        e.contains('private video') ||
        e.contains('sign in')) {
      return false;
    }
    const words = [
      'unable to download',
      'timed out',
      'timeout',
      'gave up after',
      'connection',
      'network is unreachable',
      'no route to host',
      'name or service not known',
      'temporary failure in name resolution',
      'unable to resolve',
      'unknownhost',
      'getaddrinfo',
      'urlopen error',
      'incompleteread',
      'remote end closed',
      'broken pipe',
      'transporterror',
      'ssl',
    ];
    return words.any(e.contains);
  }

  Future<void> _dropPartials(String id) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/music');
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.path.split('/').last;
        if (!name.startsWith('$id.')) continue;
        if (name == '$id.mp3' ||
            name == '$id.mp3.jpg' ||
            name == '$id.m4a' ||
            name == '$id.m4a.jpg') {
          continue;
        }
        try {
          await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _confirmStop() async {
    final n = _dl.pending.length + (_activeSong != null ? 1 : 0);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel all downloads?'),
        content: Text(n > 0
            ? 'This cancels the download and removes the $n song(s) in the list.'
            : 'This clears the download list.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep going')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel all')),
        ],
      ),
    );
    if (ok == true) _stopQueue();
  }

  void _stopQueue() {
    _batchCancel = true;
    _dl.pending.clear();
    _dl.log('Stopping (you tapped Stop)...');
    final id = _activeId;
    if (id != null) _cancelDownload(id);
    if (!_queueRunning) {

      _batchCancel = false;
      _dl.batchStatus = null;
      _dl.onStopBatch = null;
      _dl.onResume = null;
    }
    _persistQueue();
    _dl.changed();
  }

  Future<void> _addPlaylist() async {
    if (_readingPlaylist) {
      _toast('Still reading another playlist, one moment');
      return;
    }
    final url = await _askPlaylistUrl();
    if (url == null || url.isEmpty) return;
    if (!url.startsWith('http')) {
      _toast('That does not look like a link');
      return;
    }
    await _downloadPlaylistFrom(url);
  }

  Future<void> _downloadPlaylistFrom(String url, {PlaylistFolder? folder}) async {
    if (_readingPlaylist) {
      _toast('Still reading another playlist, one moment');
      return;
    }
    _readingPlaylist = true;
    _dl.readingStatus = 'Reading the playlist...';
    _dl.changed();
    _dl.log('Reading playlist: $url');

    _PlaylistData pl;
    try {
      pl = await _readPlaylist(url);
    } catch (e) {
      final msg = _errText(e);
      _dl.log('Could not read that link: $msg', error: true);
      _endReading();
      _toast('Could not read that playlist. If it is private, set it to Unlisted in YouTube Music first (edit playlist > privacy).');
      return;
    }

    final songs = pl.songs;

    final target = folder ?? _playlistById(pl.id);
    final known = target?.known ?? <String>{};
    final todo = songs
        .where((s) =>
            !_alreadyHave(s['id']!, s['title']!, s['artist'] ?? ''))
        .toList();
    final removedBefore =
        todo.map((s) => s['id']!).where(known.contains).toSet();
    _dl.log('Found ${songs.length} songs, ${todo.length} not on this device');
    if (songs.isEmpty) {
      _endReading();
      _toast('No songs found. Use a playlist link or a channel\'s Videos page.');
      return;
    }
    if (todo.isEmpty) {

      final pf = target ?? _newPlaylist(pl, url);
      _refreshPlaylist(pf, pl);
      _endReading();
      _toast(folder != null
          ? '"${pf.name}" is up to date'
          : 'All ${songs.length} songs are already on this device. Folder "${pf.name}" is ready.');
      return;
    }
    if (!mounted) {
      _endReading();
      return;
    }

    final picks = await showDialog<List<Map<String, String>>>(
      context: context,
      builder: (ctx) => _SongPickDialog(
        playlistName: target?.name ?? pl.title,
        songs: songs,
        downloaded: {
          for (var i = 0; i < songs.length; i++)
            if (_alreadyHave(
                songs[i]['id']!, songs[i]['title']!, songs[i]['artist'] ?? ''))
              i
        },
        removedBefore: removedBefore,
      ),
    );
    if (picks == null || picks.isEmpty) {
      _dl.log('Playlist download cancelled');
      _endReading();
      return;
    }

    final f = target ?? _newPlaylist(pl, url);
    _refreshPlaylist(f, pl);

    final added = _enqueue(picks.map((s) => PendingSong(
        s['id']!, s['title']!, s['artist'] ?? '', f.id,
        art: s['art'] ?? '')));
    _endReading();
    _toast(added > 0
        ? 'Added $added song(s) to the download list'
        : 'Those songs are already in the download list');
  }

  void _failDownload(DownloadTask task, String message, {bool toast = true}) {
    task.status = DlStatus.failed;
    task.error = message;
    final ex = explainDownloadError(message);
    task.why = ex.why;
    task.fixes = ex.fixes;
    task.offerReset = ex.reset;
    task.finishedAt = DateTime.now();
    _dl.log('FAILED: $message', error: true);
    if (mounted && toast) {
      _toast('Download failed: ${ex.why} See Download tab > Downloading for fixes.');
    }
  }

  void _saveCurrent() {
    final title = ((_now['title'] as String?) ?? '').trim();
    if (title.isEmpty) {
      _toast('Nothing is playing yet');
      return;
    }
    final song = SavedSong(
      vid: _nowVid,
      title: title,
      artist: ((_now['artist'] as String?) ?? '').trim(),
      art: (_now['art'] as String?) ?? '',
    );
    final exists = _saved.any((s) =>
        (song.vid.isNotEmpty && s.vid == song.vid) ||
        (s.title == song.title && s.artist == song.artist));
    if (exists) {
      _toast('Already in Downloads');
      return;
    }
    setState(() => _saved = [song, ..._saved]);
    _persistSaved();
    _toast('Saved to Downloads');
  }

  bool _uploadBusy = false;
  final ValueNotifier<String> _dlQuery = ValueNotifier<String>('');
  final ValueNotifier<int> _dlFilter = ValueNotifier<int>(0);
  final TextEditingController _dlSearchCtl = TextEditingController();

  String _extOf(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0 || i == name.length - 1) return 'mp3';
    final e = name.substring(i + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{2,5}$').hasMatch(e) ? e : 'mp3';
  }

  Future<void> _uploadForSaved(SavedSong s) async {
    if (_uploadBusy) return;
    if (_alreadyHave(s.vid, s.title, s.artist)) {
      _toast('Already on this device');
      return;
    }
    final files = await _pickAudio();
    if (files.isEmpty) return;
    _uploadBusy = true;
    try {
      final f = files.first;
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/music');
      await dir.create(recursive: true);
      final tag = s.vid.length == 11 ? s.vid : 'saved';
      final dest = await _savePickedAudio(
          f, '${dir.path}/${DateTime.now().microsecondsSinceEpoch}_$tag');
      if (dest == null) throw Exception('Not a file this phone can play');
      var artPath = '';
      final artUrl = s.art.startsWith('http')
          ? s.art
          : (s.vid.length == 11
              ? 'https://i.ytimg.com/vi/${s.vid}/hqdefault.jpg'
              : '');
      if (artUrl.isNotEmpty) {
        try {
          final img = await http
              .get(Uri.parse(artUrl))
              .timeout(const Duration(seconds: 20));
          if (img.statusCode == 200) {
            final cover = File('$dest.jpg');
            await cover.writeAsBytes(img.bodyBytes);
            artPath = cover.path;
          }
        } catch (_) {}
      }
      if (artPath.isEmpty) {
        try {
          final md = readMetadata(File(dest), getImage: true);
          if (md.pictures.isNotEmpty) {
            final img = File('$dest.jpg');
            await img.writeAsBytes(md.pictures.first.bytes);
            artPath = img.path;
          }
        } catch (_) {}
      }
      _localSongs = [
        ..._localSongs,
        LocalSong(
            title: s.title,
            artist: s.artist,
            path: dest,
            art: artPath,
            uploaded: true),
      ];
      _saved = _saved.where((x) => x != s).toList();
      if (mounted) setState(() {});
      await _persistLocal();
      await _persistSaved();
      _toast('"${s.title}" is now a downloaded song');
    } catch (_) {
      _toast('Could not add that file');
    } finally {
      _uploadBusy = false;
    }
  }

  Future<void> _replaceUploaded(LocalSong song) async {
    if (_uploadBusy || !mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace the MP3?'),
        content: Text(
            'Pick the right file for "${song.title}". The current MP3 is replaced.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Pick file')),
        ],
      ),
    );
    if (go != true) return;
    final files = await _pickAudio();
    if (files.isEmpty) return;
    _uploadBusy = true;
    try {
      final bytes = await files.first.readAsBytes();
      final idx = _localSongs.indexOf(song);
      if (idx >= 0 && idx == _localIdx) {
        audioHandler.stopLocal();
        _localIdx = -1;
      }
      await File(song.path).writeAsBytes(bytes);
      if (mounted) setState(() {});
      _touch();
      _toast('MP3 replaced for "${song.title}"');
    } catch (_) {
      _toast('Could not replace the file');
    } finally {
      _uploadBusy = false;
    }
  }

  void _removeSaved(SavedSong s) {
    setState(() => _saved = _saved.where((x) => x != s).toList());
    _persistSaved();
  }

  void _playSaved(SavedSong s) {
    if (s.vid.isEmpty) {
      _toast('This song has no link saved');
      return;
    }
    _lastWebTab = 0;
    setState(() => _tab = 0);
    _controller.loadRequest(Uri.parse('https://music.youtube.com/watch?v=${s.vid}'));
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  static const _adBlockJs = r'''
(function () {
  if (window.__adBlockInstalled) return;
  window.__adBlockInstalled = true;

  // 1) Hide banners and "Try Premium" pop-ups.
  const style = document.createElement('style');
  style.textContent = `
    ytmusic-mealbar-promo-renderer,
    ytmusic-statement-banner-renderer,
    ytmusic-upsell-dialog-renderer,
    .ytp-ad-module, .ytp-ad-overlay-container, .ytp-ad-player-overlay,
    #player-ads, .video-ads { display: none !important; }
  `;
  document.head.appendChild(style);

  // 2) Remove the ad data from the site's answers before the player sees it.
  //    The site asks for every song with fetch; ads come inside that answer.
  const strip = (o, depth) => {
    if (!o || typeof o !== 'object' || (depth || 0) > 6) return;
    if (o.adPlacements) o.adPlacements = [];
    if (o.playerAds) o.playerAds = [];
    if (o.adSlots) o.adSlots = [];
    if (o.adBreakHeartbeatParams) delete o.adBreakHeartbeatParams;
    for (const k in o) {
      const v = o[k];
      if (v && typeof v === 'object') strip(v, (depth || 0) + 1);
    }
  };
  try {
    const origParse = JSON.parse;
    JSON.parse = function (t, r) {
      const v = origParse.call(this, t, r);
      try {
        if (v && typeof v === 'object' &&
            (v.adPlacements || v.playerAds || v.adSlots)) strip(v, 0);
      } catch (e) {}
      return v;
    };
  } catch (e) {}
  try {
    const origFetch = window.fetch;
    window.fetch = async function () {
      const res = await origFetch.apply(this, arguments);
      try {
        const a0 = arguments[0];
        const url = typeof a0 === 'string' ? a0 : ((a0 && a0.url) || '');
        if (/\/youtubei\/v1\/(player|next)/.test(url)) {
          const text = await res.clone().text();
          if (/adPlacements|playerAds|adSlots/.test(text)) {
            const j = JSON.parse(text);
            strip(j, 0);
            return new Response(JSON.stringify(j), {
              status: res.status,
              statusText: res.statusText,
              headers: res.headers,
            });
          }
        }
      } catch (e) {}
      return res;
    };
  } catch (e) {}

  // 3) If an ad still gets through: skip it, speed it up and mute it, then
  //    put the sound back to normal for the song.
  let inAd = false;
  function adShowing() {
    const player = document.querySelector('#movie_player, ytmusic-player');
    if (player && (player.classList.contains('ad-showing') ||
                   player.classList.contains('ad-interrupting'))) return true;
    return !!document.querySelector(
        '.ytp-ad-player-overlay, .ytp-ad-text, .ytp-ad-preview-container');
  }
  function handleAd() {
    try {
      const video = document.querySelector('video');
      const dialog = document.querySelector('ytmusic-upsell-dialog-renderer');
      if (dialog) {
        const close = dialog.querySelector(
            '#dismiss-button, .dismiss-button, button[aria-label="Close"], button[aria-label="No thanks"]');
        if (close) close.click();
      }
      const skip = document.querySelector(
          '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-container button');
      if (skip) skip.click();

      if (adShowing()) {
        inAd = true;
        if (video) {
          video.muted = true;
          video.playbackRate = 16;
          if (isFinite(video.duration) && video.duration > 0) {
            video.currentTime = video.duration;
          }
        }
      } else if (inAd) {
        inAd = false;
        if (video) {
          video.muted = false;
          video.playbackRate = 1;
        }
      }
    } catch (e) {}
  }

  new MutationObserver(handleAd).observe(document.body,
      { childList: true, subtree: true, attributes: true });
  setInterval(handleAd, 400);
})();
''';

  static const _keepAliveJs = r'''
(function () {
  if (window.__bgPlayInstalled) return;
  window.__bgPlayInstalled = true;
  const def = (obj, prop, val) => {
    try { Object.defineProperty(obj, prop, { get: () => val, configurable: true }); } catch (e) {}
  };
  def(document, 'hidden', false);
  def(document, 'webkitHidden', false);
  def(document, 'visibilityState', 'visible');
  def(document, 'webkitVisibilityState', 'visible');
  const stop = (e) => e.stopImmediatePropagation();
  ['visibilitychange', 'webkitvisibilitychange'].forEach((t) => {
    document.addEventListener(t, stop, true);
    window.addEventListener(t, stop, true);
  });
  window.addEventListener('blur', stop, true);
  window.addEventListener('pagehide', stop, true);
  // Stop the site's "Changes you made may not be saved" leave-page prompt.
  window.addEventListener('beforeunload', stop, true);
  try {
    Object.defineProperty(window, 'onbeforeunload',
        { get: () => null, set: () => {}, configurable: true });
  } catch (e) {}
})();
''';

  static const _shadowJs = r'''
(function () {
  if (window.__shadowInstalled) return;
  window.__shadowInstalled = true;
  window.__localVids = window.__localVids || [];
  window.__localKeys = window.__localKeys || [];
  const norm = function (x) {
    return (x || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
  };
  // Same title and (about) the same artist as a downloaded song.
  window.__metaMatch = function () {
    try {
      if (!window.__localKeys.length) return null;
      const p = document.getElementById('movie_player');
      if (!p || !p.getVideoData) return null;
      const d = p.getVideoData();
      if (!d || !d.title) return null;
      const t = norm(d.title);
      const au = norm((d.author || '').replace(/\s*-\s*topic\s*$/i, ''));
      if (!t || !au) return null;
      for (const k of window.__localKeys) {
        if (norm(k.t) !== t) continue;
        const na = norm(k.a);
        const fa = norm((k.a || '').split(/,|&| feat\.? | ft\.? /i)[0]);
        if (!na || !fa) continue;
        if (au.indexOf(fa) >= 0 || na.indexOf(au) >= 0) return k;
      }
    } catch (e) {}
    return null;
  };
  window.__curVid = function () {
    try {
      const p = document.getElementById('movie_player');
      if (p && p.getVideoData) {
        const d = p.getVideoData();
        if (d && d.video_id) return d.video_id;
      }
    } catch (e) {}
    return new URL(location.href).searchParams.get('v') || '';
  };
  // media events do not bubble, so listen in the capture phase
  document.addEventListener('playing', function (e) {
    try {
      const v = e.target;
      if (!v || v.tagName !== 'VIDEO' || !window.ShadowPlay) return;
      const id = window.__curVid();
      if (!id) return;
      if (window.__allowWeb && window.__allowWeb !== id) window.__allowWeb = '';
      if (window.__allowWeb === id) return;
      let hit = null;
      if (window.__localVids.indexOf(id) < 0) {
        // Not the same upload: try the same song by title + artist.
        hit = window.__metaMatch();
        if (!hit) return;
      }
      v.pause();
      ShadowPlay.postMessage(JSON.stringify(
        hit ? { vid: id, lt: hit.t, la: hit.a } : { vid: id }));
    } catch (err) {}
  }, true);
})();
''';

  static const _nowPlayingJs = r'''
(function () {
  if (window.__nowPlayingInstalled) return;
  window.__nowPlayingInstalled = true;
  const text = (sel) => {
    const e = document.querySelector(sel);
    return e ? (e.textContent || '').trim() : '';
  };
  let lastKey = '';
  let ticks = 0;
  let lastT = -1, lastMove = Date.now();
  function report() {
    if (!window.NowPlaying) return;
    const v = document.querySelector('video');
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    const title = (md && md.title) || text('ytmusic-player-bar .title');
    const artist = (md && md.artist) || text('ytmusic-player-bar .byline');
    const album = (md && md.album) || '';
    let art = '';
    if (md && md.artwork && md.artwork.length) {
      art = md.artwork[md.artwork.length - 1].src;
    } else {
      const img = document.querySelector('ytmusic-player-bar img');
      if (img && img.src) art = img.src;
    }
    const playing = !!(v && !v.paused && !v.ended);
    const dur = v && isFinite(v.duration) ? v.duration : 0;
    const cvid = (window.__curVid && window.__curVid()) || '';
    const t = v ? v.currentTime : 0;
    if (t !== lastT) { lastT = t; lastMove = Date.now(); }
    const stalled = playing && (Date.now() - lastMove > 4000);
    const online = navigator.onLine !== false;
    const key = [title, artist, art, playing, Math.round(dur), cvid, stalled,
                 online].join('|');
    ticks++;
    // send when something changed, otherwise every 5 seconds to keep the position right
    if (key !== lastKey || ticks >= 5) {
      lastKey = key;
      ticks = 0;
      NowPlaying.postMessage(JSON.stringify({
        title: title, artist: artist, album: album, art: art,
        playing: playing, pos: v ? v.currentTime : 0, dur: dur,
        vid: new URL(location.href).searchParams.get('v') || '',
        cvid: cvid, stalled: stalled, online: online
      }));
    }
  }
  setInterval(report, 1000);
})();
''';

  static const _playerPageJs = r'''
(function () {
  if (window.__playerPageInstalled) return;
  window.__playerPageInstalled = true;
  let last = null;
  function isOpen() {
    const layout = document.querySelector('ytmusic-app-layout');
    if (layout) {
      for (const a of layout.getAttributeNames()) {
        if (/player.?page.?open/i.test(a)) return true;
      }
      const st = layout.getAttribute('player-ui-state') ||
          layout.getAttribute('player-ui-state_') || '';
      if (/PLAYER_PAGE_OPEN|FULLSCREEN/i.test(st)) return true;
    }
    const page = document.querySelector('ytmusic-player-page');
    if (page) {
      const r = page.getBoundingClientRect();
      if (r.height > 0 && r.top <= 1 && page.offsetParent !== null &&
          !page.hasAttribute('hidden')) {
        const bar = document.querySelector('ytmusic-player-bar');
        if (page.hasAttribute('player-page-open_') ||
            page.hasAttribute('opened')) return true;
      }
    }
    return false;
  }
  function check() {
    if (!window.PlayerPage) return;
    const open = isOpen();
    if (open !== last) {
      last = open;
      PlayerPage.postMessage(open ? 'open' : 'closed');
    }
  }
  setInterval(check, 400);
})();
''';

  static const _pageUrlJs = r'''
(function () {
  if (window.__pageUrlInstalled) return;
  window.__pageUrlInstalled = true;
  let last = '';
  function check() {
    if (!window.PageUrl) return;
    const u = location.href;
    if (u !== last) {
      last = u;
      PageUrl.postMessage(u);
    }
  }
  setInterval(check, 500);
})();
''';

  static const _isPlayingJs =
      "(function(){var v=document.querySelector('video');return !!(v && !v.paused && !v.ended);})()";

  static const _resumeJs =
      "(function(){var v=document.querySelector('video');if(v && v.paused && !v.ended){v.play();}})()";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSaved();
    _initWarmup();

    PlatformWebViewControllerCreationParams webParams =
        const PlatformWebViewControllerCreationParams();
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      webParams = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    }
    _controller = WebViewController.fromPlatformCreationParams(webParams)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('NowPlaying', onMessageReceived: (msg) {
        try {
          final data = jsonDecode(msg.message);
          if (data is Map<String, dynamic>) {
            final wasDownloaded = _nowDownloaded;
            _now = data;
            final v = (data['vid'] as String?) ?? '';
            if (v.isNotEmpty) _nowVid = v;

            if (mounted && wasDownloaded != _nowDownloaded) setState(() {});
            _trackPlay(data);

            if (_onWebReport(data)) audioHandler.onWebState(data);
          }
        } catch (_) {}
      })
      ..addJavaScriptChannel('PlayerPage', onMessageReceived: (msg) {
        final open = msg.message == 'open';
        if (mounted && open != _playerOpen) setState(() => _playerOpen = open);
      })
      ..addJavaScriptChannel('ShadowPlay',
          onMessageReceived: (msg) => _onShadowPlay(msg.message))
      ..addJavaScriptChannel('EqStatus', onMessageReceived: (msg) {
        audioHandler.webEqStatus = msg.message;
        eqState.refresh();
      })
      ..addJavaScriptChannel('PageUrl', onMessageReceived: (msg) {

        String? link;
        final uri = Uri.tryParse(msg.message);
        if (uri != null &&
            uri.host.contains('music.youtube.com') &&
            uri.path == '/playlist') {
          final id = uri.queryParameters['list'] ?? '';
          if (id.isNotEmpty) link = 'https://music.youtube.com/playlist?list=$id';
        }
        if (mounted && link != _playlistUrl) setState(() => _playlistUrl = link);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          _controller.runJavaScript(_keepAliveJs);
          _controller.runJavaScript(WebAudioHandler.webTapJs);
          _controller.runJavaScript(WebAudioHandler.gvHookJs);
        },
        onPageFinished: (_) {
          _controller.runJavaScript(_keepAliveJs);
          _controller.runJavaScript(_adBlockJs);
          _controller.runJavaScript(WebAudioHandler.webTapJs);
          _controller.runJavaScript(WebAudioHandler.webEqJs);
          _controller.runJavaScript(WebAudioHandler.gvHookJs);
          audioHandler.pushWebEq();
          _controller.runJavaScript(_shadowJs);
          _controller.runJavaScript(_nowPlayingJs);
          _controller.runJavaScript(_playerPageJs);
          _syncLocalVids();
          _controller.runJavaScript(_pageUrlJs);
        },
      ))
      ..loadRequest(Uri.parse('https://music.youtube.com'));
    if (Platform.isIOS) {

      _controller.setUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1');
    }
    audioHandler.resetPageSession = () async {
      await WebViewCookieManager().clearCookies();
      await _controller.clearLocalStorage();
      await _controller.clearCache();
      await _controller.loadRequest(Uri.parse('https://music.youtube.com'));
      await _closeDownloadWeb();
      if (_resetWarmOnSession) await _restartWarmup();
    };
    audioHandler.runJs = (js) => _controller.runJavaScript(js);
    audioHandler.runJsResult = (js) => _controller.runJavaScriptReturningResult(js);
    audioHandler.localNext = () async {
      if (_shadowVid != null || _resumeVid != null) {
        await _webStep(true);
      } else {
        _stepLocal(1);
      }
    };
    audioHandler.localPrev = () async {
      if (_shadowVid != null) {
        await _shadowPrev();
      } else {
        _stepLocal(-1);
      }
    };
    audioHandler.localEnded = () async {
      if (_shadowVid != null || _resumeVid != null) {
        await _webStep(true);
      } else {
        _onLocalEnded();
      }
    };
    playerOpts.onShuffleChanged = _applyShuffle;
    playerOpts.load();
    eqState.load();
    audioHandler.localStopped = () {
      _shadowVid = null;
      _resumeVid = null;
      if (mounted) setState(() => _localIdx = -1);
      _touch();
    };
    _dl.onQueueChanged = _queueChanged;
    _loadPlaylists();
    _loadLocal().then((_) => _loadQueue());
    _loadSmart();
    _smartTimer =
        Timer.periodic(const Duration(minutes: 5), (_) => _smartKick());
    _ytdlp.setMethodCallHandler(_onNative);
  }

  @override
  void dispose() {
    playerOpts.onShuffleChanged = null;
    WidgetsBinding.instance.removeObserver(this);
    _smartTimer?.cancel();
    _warmTimer?.cancel();
    _dlQuery.dispose();
    _dlFilter.dispose();
    _dlSearchCtl.dispose();
    _dl.dispose();
    _libTick.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.inactive) {

      try {
        final r = await _controller.runJavaScriptReturningResult(_isPlayingJs);
        _wasPlaying = r.toString() == 'true';
      } catch (_) {}
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {

      if (_wasPlaying) {
        for (final ms in [300, 1200]) {
          await Future.delayed(Duration(milliseconds: ms));
          _controller.runJavaScript(_resumeJs);
        }
      }
    } else if (state == AppLifecycleState.resumed) {
      _controller.runJavaScript(_keepAliveJs);
    }
  }

  int _tab = 0;
  int _lastWebTab = 0;

  bool get _appTab => _tab >= 3;

  static const _labels = ['Home', 'Explore', 'Library'];

  void _goTo(String label) {
    final l = label.toLowerCase().replaceAll("'", '');
    _controller.runJavaScript('''
(function () {
  var want = '$l';
  var items = document.querySelectorAll(
      'ytmusic-guide-entry-renderer, ytmusic-pivot-bar-item-renderer');
  for (var i = 0; i < items.length; i++) {
    var el = items[i];
    var text = (el.getAttribute('title') || el.textContent || '')
        .replace(/\\s+/g, ' ').trim().toLowerCase();
    if (text === want || text.indexOf(want + ' ') === 0) {
      var target = el.querySelector('a, tp-yt-paper-item') || el;
      target.click();
      return;
    }
  }
})();
''');
  }

  void _onNavTap(int i) {
    final backToSame = _appTab && i == _lastWebTab;
    setState(() => _tab = i);
    if (i < _labels.length) {
      _lastWebTab = i;
      if (!backToSame) _goTo(_labels[i]);
    }
  }

  Widget? _bottomBar() {

    final hideNav = _playerOpen && !_appTab;
    final offline = _shadowVid != null;
    final onDevice = _localIdx >= 0;

    final showMini = _appTab ? true : (hideNav ? offline : onDevice);
    final label = offline
        ? 'Playing offline version'
        : (onDevice ? 'Playing from this device' : null);
    final mini = showMini ? MiniPlayer(label: label) : null;
    if (hideNav) {
      return mini == null ? null : SafeArea(top: false, child: mini);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mini != null) mini,
        NavigationBar(
              backgroundColor: const Color(0xFF121212),
              selectedIndex: _tab,
              onDestinationSelected: _onNavTap,
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: 'Home'),
                NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
                NavigationDestination(
                    icon: Icon(Icons.library_music_outlined),
                    selectedIcon: Icon(Icons.library_music),
                    label: 'Library'),
                NavigationDestination(
                    icon: Icon(Icons.download_outlined),
                    selectedIcon: Icon(Icons.download),
                    label: 'Download'),
                NavigationDestination(
                    icon: Icon(Icons.graphic_eq),
                    selectedIcon: Icon(Icons.equalizer),
                    tooltip: 'Personalize sound',
                    label: 'Sound'),
              ],
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [

              if (_dlWebOn && _dlWeb != null)
                Positioned(
                  left: -4000,
                  top: 0,
                  width: 360,
                  height: 640,
                  child: ExcludeSemantics(
                    child: IgnorePointer(
                        child: WebViewWidget(controller: _dlWeb!)),
                  ),
                ),
              IndexedStack(
                index: _tab == 3 ? 1 : (_tab == 4 ? 2 : 0),
                children: [
                  WebViewWidget(controller: _controller),
                  DownloadPage(
                    playlists: _playlists,
                    songsOf: (f) => f == null ? _localSongs : _songsOfFolder(f),
                    onAdd: _addMusic,
                    onOpenFolder: _openFolder,
                    onRemoveFolder: _removePlaylist,
                    songs: _saved,
                    onPlay: _playSaved,
                    onRemove: _removeSaved,
                    onUpload: _uploadForSaved,
                    query: _dlQuery,
                    filter: _dlFilter,
                    searchController: _dlSearchCtl,
                    onPlayLocal: _playQueue,
                    onRemoveLocal: _removeLocal,
                    onReplaceLocal: _replaceUploaded,
                    manager: _dl,
                    onAddPlaylist: _addPlaylist,
                    onOpenSettings: _openSettings,
                  ),
                  const PersonalizeSoundPage(),
                ],
              ),

              if (_playlistUrl != null && !_playerOpen && !_appTab)
                Positioned(
                  right: 12,
                  bottom: 84,
                  child: FloatingActionButton.extended(
                    heroTag: 'dlPlaylist',
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    onPressed: _readingPlaylist
                        ? null
                        : () => _downloadPlaylistFrom(_playlistUrl!),
                    icon: const Icon(Icons.download),
                    label: Text(
                        _readingPlaylist ? 'Reading...' : 'Download playlist'),
                  ),
                ),

              if (_playerOpen && !_appTab)
                Positioned(
                  right: 12,
                  top: 56,
                  child: Column(
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'downloadSong',
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        tooltip: _nowDownloaded
                            ? 'Downloaded'
                            : _nowActive
                                ? 'Downloading'
                                : _nowWaiting
                                    ? 'Waiting in the download list'
                                    : 'Download to this device',
                        onPressed: _downloadCurrent,
                        child: _nowActive
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    value: _dlProgress,
                                    color: Colors.black),
                              )
                            : _nowDownloaded
                                ? const Icon(Icons.download_done,
                                    color: Color(0xFF1DB954))
                                : _nowWaiting
                                    ? const Icon(Icons.schedule)
                                    : const Icon(Icons.download),
                      ),
                      const SizedBox(height: 10),
                      FloatingActionButton.small(
                        heroTag: 'saveSong',
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        tooltip: 'Save link',
                        onPressed: _saveCurrent,
                        child: const Icon(Icons.bookmark_add_outlined),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: _bottomBar(),
      );
}

enum DlStatus { preparing, downloading, saving, done, failed }

({String why, List<String> fixes, bool reset}) explainDownloadError(String raw) {
  final e = raw.toLowerCase();
  bool has(List<String> words) => words.any(e.contains);
  if (has(['new streaming mode'])) {
    return (
      why:
          'YouTube is giving this session its newer streaming mode, which the app cannot download from.',
      fixes: [
        'Sound tab > Reset page session (it signs you out). Wait for the page to load, play a song, then download again.',
        'Or sign in to YouTube Music (with or without Premium), play a song, then download.',
        'Last resort: delete the app and install it again.',
      ],
      reset: true,
    );
  }
  if (has(['could not get this song', 'could not get a link', 'no usable link'])) {
    return (
      why: 'The app could not get this song\'s audio link from the YouTube page.',
      fixes: [
        'Play the song in the Music tab for 10 to 20 seconds (let any ad finish), then tap download.',
        'After opening the app, wait for the page to finish loading first.',
        'Check your internet. If a VPN is on, try turning it off or picking another server.',
        'Sound tab > Reset page session, then try again.',
      ],
      reset: true,
    );
  }
  if (has(['http 403', 'refused the download'])) {
    return (
      why: 'YouTube refused to send the audio.',
      fixes: [
        'Play the song in the Music tab first, then download it while it is playing.',
        'Sign in to YouTube Music, then try again.',
        'Sound tab > Reset page session, then try again.',
        'Turn the VPN off or on, or pick another server.',
      ],
      reset: true,
    );
  }
  if (has(['unplayable', 'not available', 'private video', 'age-restricted', 'age restricted', 'sign in to confirm'])) {
    return (
      why:
          'This song cannot be played right now (removed, private, age-restricted, or blocked in your country).',
      fixes: [
        'Try another version of the song (a different upload).',
        'Try a VPN set to another country.',
        'If it is age-restricted, sign in to YouTube Music.',
      ],
      reset: false,
    );
  }
  if (has(['timeout', 'socket', 'connection', 'clientexception', 'host lookup', 'network'])) {
    return (
      why: 'The connection to YouTube dropped or was too slow.',
      fixes: [
        'Check your Wi-Fi or mobile data, then try again.',
        'If a VPN is on, turn it off or pick another server.',
        'Move closer to the router, or try again in a minute.',
      ],
      reset: false,
    );
  }
  if (has(['no space', 'filesystem', 'disk'])) {
    return (
      why: 'There is not enough free storage on this iPhone.',
      fixes: [
        'Free some space in iPhone Settings > General > iPhone Storage.',
        'Delete songs you no longer need (Storage page in this app).',
      ],
      reset: false,
    );
  }
  if (has(['cancelled', 'canceled'])) {
    return (why: 'You cancelled this download.', fixes: const [], reset: false);
  }
  if (has(['no mp3 file', 'not a file this phone can play', 'no audio'])) {
    return (
      why: 'The audio was fetched but is empty or not in a format this phone can play.',
      fixes: [
        'Try downloading the song again.',
        'Try another version of the song.',
      ],
      reset: false,
    );
  }
  return (
    why: 'Something unexpected went wrong.',
    fixes: [
      'Try the download again.',
      'Play the song in the Music tab first, then download it.',
      'Use Copy in the Log below and send it to the developer.',
    ],
    reset: false,
  );
}

class DownloadTask {
  final int id;
  final String title, artist;
  final String? folderId;
  DlStatus status = DlStatus.preparing;
  int received = 0, total = 0;
  double speedKBs = 0;
  double? pct;
  int? etaSec;
  String? error;

  String? why;
  List<String> fixes = const [];
  bool offerReset = false;
  final DateTime startedAt = DateTime.now();
  DateTime? finishedAt;

  DownloadTask(this.id, this.title, this.artist, {this.folderId});

  bool get finished => status == DlStatus.done || status == DlStatus.failed;
  double? get progress =>
      pct != null ? pct! / 100 : (total > 0 ? received / total : null);

  String get statusLabel {
    switch (status) {
      case DlStatus.preparing:
        return 'Asking YouTube for the audio...';
      case DlStatus.downloading:
        return 'Downloading';
      case DlStatus.saving:
        return 'Converting to MP3 and saving...';
      case DlStatus.done:
        return 'Finished';
      case DlStatus.failed:
        return 'Failed';
    }
  }
}

class LogLine {
  final DateTime time;
  final String text;
  final bool error;
  const LogLine(this.time, this.text, this.error);
}

class _SongPickDialog extends StatefulWidget {
  final String playlistName;
  final List<Map<String, String>> songs;
  final Set<int> downloaded;
  final Set<String> removedBefore;

  const _SongPickDialog({
    required this.playlistName,
    required this.songs,
    required this.downloaded,
    required this.removedBefore,
  });

  @override
  State<_SongPickDialog> createState() => _SongPickDialogState();
}

class _SongPickDialogState extends State<_SongPickDialog> {
  final Set<int> _on = {};

  Set<int> get _missing => {
        for (var i = 0; i < widget.songs.length; i++)
          if (!widget.downloaded.contains(i)) i
      };

  @override
  Widget build(BuildContext context) {
    final n = _on.length;
    final minutes = (n * 25 / 60).ceil();
    final have = widget.downloaded.length;
    final missing = widget.songs.length - have;
    final onlyMissing = _on.length == missing &&
        missing > 0 &&
        _on.every((i) => !widget.downloaded.contains(i));
    final allOn = _on.length == widget.songs.length;
    final h = MediaQuery.of(context).size.height;
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      title: Text(
          widget.playlistName.isEmpty ? 'Choose songs' : widget.playlistName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: double.maxFinite,
        height: h * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    '${widget.songs.length} songs · $have downloaded · $missing not downloaded',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: missing == 0
                        ? null
                        : () => setState(() {
                              _on
                                ..clear()
                                ..addAll(_missing);
                            }),
                    child: Text(onlyMissing
                        ? 'Not downloaded ✓'
                        : 'Select not downloaded ($missing)'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (allOn) {
                        _on.clear();
                      } else {
                        _on
                          ..clear()
                          ..addAll(List<int>.generate(
                              widget.songs.length, (i) => i));
                      }
                    }),
                    child: Text(allOn ? 'Clear' : 'Select all'),
                  ),
                  if (n > 0 && !allOn)
                    TextButton(
                      onPressed: () => setState(_on.clear),
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: widget.songs.length,
                itemBuilder: (_, i) {
                  final song = widget.songs[i];
                  final artist = song['artist'] ?? '';
                  final removed = widget.removedBefore.contains(song['id']);
                  final isHave = widget.downloaded.contains(i);
                  return CheckboxListTile(
                    dense: true,
                    value: _on.contains(i),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _on.add(i);
                      } else {
                        _on.remove(i);
                      }
                    }),
                    secondary: Icon(
                        isHave ? Icons.check_circle : Icons.circle_outlined,
                        size: 20,
                        color: isHave ? Colors.greenAccent : Colors.white38),
                    title: Text(song['title'] ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: isHave ? Colors.white60 : null)),
                    subtitle: Text(
                        [
                          if (artist.isNotEmpty) artist,
                          if (isHave) 'Downloaded',
                          if (removed) 'removed earlier',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  );
                },
              ),
            ),
            if (n > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    'About $minutes min. Keep the app open and the screen on.',
                    style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: n == 0
              ? null
              : () => Navigator.pop(context, [
                    for (var i = 0; i < widget.songs.length; i++)
                      if (_on.contains(i)) widget.songs[i]
                  ]),
          child: Text(n == 0 ? 'Download' : 'Download $n'),
        ),
      ],
    );
  }
}

class PendingSong {
  final String vid, title, artist, art;
  final String? folderId;
  final bool smart;
  const PendingSong(this.vid, this.title, this.artist, this.folderId,
      {this.art = '', this.smart = false});

  Map<String, dynamic> toJson() => {
        'vid': vid,
        'title': title,
        'artist': artist,
        'art': art,
        'folder': folderId,
        'smart': smart,
      };

  factory PendingSong.fromJson(Map<String, dynamic> j) => PendingSong(
        (j['vid'] as String?) ?? '',
        (j['title'] as String?) ?? '',
        (j['artist'] as String?) ?? '',
        j['folder'] as String?,
        art: (j['art'] as String?) ?? '',
        smart: j['smart'] == true,
      );
}

class DownloadManager extends ChangeNotifier {
  final List<DownloadTask> tasks = [];
  final List<LogLine> logs = [];
  int _nextId = 1;

  String? batchStatus;
  String? readingStatus;
  VoidCallback? onStopBatch;
  VoidCallback? onResume;
  VoidCallback? onCancelCurrent;
  VoidCallback? onQueueChanged;
  final List<PendingSong> pending = [];

  List<DownloadTask> activeFor(String? folderId) => tasks
      .where((t) => !t.finished && (folderId == null || t.folderId == folderId))
      .toList();

  List<PendingSong> pendingFor(String? folderId) => pending
      .where((p) => folderId == null || p.folderId == folderId)
      .toList();

  void moveToFront(PendingSong p) {
    if (pending.isEmpty || identical(pending.first, p)) return;
    if (pending.remove(p)) {
      pending.insert(0, p);
      notifyListeners();
      onQueueChanged?.call();
    }
  }

  void cancelFolder(String? folderId) {
    final before = pending.length;
    pending.removeWhere((p) => folderId == null || p.folderId == folderId);
    final active = activeFor(folderId).isNotEmpty;
    if (before != pending.length) {
      notifyListeners();
      onQueueChanged?.call();
    }
    if (active) onCancelCurrent?.call();
  }

  void removePending(PendingSong p) {
    if (pending.remove(p)) {
      notifyListeners();
      onQueueChanged?.call();
    }
  }

  DownloadTask start(String title, String artist, {String? folderId}) {
    final t = DownloadTask(_nextId++, title, artist, folderId: folderId);
    tasks.insert(0, t);
    log('Started: "$title"');
    return t;
  }

  void log(String text, {bool error = false}) {
    logs.add(LogLine(DateTime.now(), text, error));
    if (logs.length > 300) logs.removeRange(0, logs.length - 300);
    notifyListeners();
  }

  void changed() => notifyListeners();

  void clearFinished() {
    tasks.removeWhere((t) => t.finished);
    notifyListeners();
  }

  void clearLog() {
    logs.clear();
    notifyListeners();
  }

  String get summary {
    final active = tasks.where((t) => !t.finished).toList();
    if (batchStatus != null) {
      return active.isEmpty ? batchStatus! : '${batchStatus!} · ${active.first.title}';
    }
    if (active.isEmpty) {
      return tasks.isEmpty
          ? 'Nothing downloading'
          : 'Nothing downloading · ${tasks.length} recent';
    }
    final t = active.first;
    final p = t.progress;
    final tail = (t.status == DlStatus.downloading && p != null)
        ? '${(p * 100).round()}%'
        : t.statusLabel;
    return '${t.title} · $tail';
  }
}

class DownloadingPage extends StatelessWidget {
  final DownloadManager manager;
  const DownloadingPage({super.key, required this.manager});

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _clock(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  static String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);

  static Widget _taskCard(DownloadTask t, {VoidCallback? onCancel}) {
    final failed = t.status == DlStatus.failed;
    final done = t.status == DlStatus.done;

    double? value;
    if (done) {
      value = 1;
    } else if (failed) {
      value = 0;
    } else if (t.status == DlStatus.downloading) {
      value = t.progress;
    }

    String detail;
    if (failed) {
      detail = t.error ?? 'Unknown error';
    } else if (done) {
      detail = 'Finished · MP3 · ${_mb(t.total)} MB';
    } else if (t.status == DlStatus.downloading && t.pct != null) {
      detail =
          '${t.pct!.round()}%${t.etaSec != null ? ' · about ${t.etaSec}s left' : ''}';
    } else if (t.status == DlStatus.downloading && t.total > 0) {
      detail =
          '${((t.received / t.total) * 100).round()}% · ${_mb(t.received)} / ${_mb(t.total)} MB · ${t.speedKBs.round()} KB/s';
    } else {
      detail = 'Started ${_clock(t.startedAt)}';
    }

    final color = failed
        ? Colors.redAccent
        : done
            ? Colors.greenAccent
            : Colors.white70;

    return Card(
      color: const Color(0xFF1A1A1A),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    failed
                        ? Icons.error_outline
                        : done
                            ? Icons.check_circle
                            : Icons.downloading,
                    color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (onCancel != null && !t.finished)
                  IconButton(
                    tooltip: 'Cancel this download',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: onCancel,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(t.statusLabel, style: TextStyle(color: color)),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 6,
                color: failed
                    ? Colors.redAccent
                    : done
                        ? Colors.greenAccent
                        : null,
              ),
            ),
            const SizedBox(height: 6),
            if (failed && t.why != null) ...[
              Text(t.why!,
                  style: const TextStyle(fontSize: 14, color: Colors.white)),
              if (t.fixes.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('How to fix it:',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70)),
                for (final f in t.fixes)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('•  ',
                            style: TextStyle(color: Colors.white70)),
                        Expanded(
                            child: Text(f,
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.white70))),
                      ],
                    ),
                  ),
              ],
              if (t.offerReset)
                Builder(
                  builder: (ctx) => TextButton.icon(
                    onPressed: () async {
                      String msg;
                      try {
                        await audioHandler.resetPageSession?.call();
                        msg =
                            'Done. Wait for the page to load, play a song, then download.';
                      } catch (e) {
                        msg = 'Could not reset: $e';
                      }
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx)
                            .showSnackBar(SnackBar(content: Text(msg)));
                      }
                    },
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Reset page session (signs you out)'),
                  ),
                ),
              const SizedBox(height: 6),
              Text('Technical details: $detail',
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
            ] else
              Text(detail,
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Downloading'),
        actions: [
          IconButton(
            tooltip: 'Clear finished',
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: manager.clearFinished,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final tasks = manager.tasks;
          final logs = manager.logs;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (manager.batchStatus != null)
                Card(
                  color: const Color(0xFF1A1A1A),
                  margin: const EdgeInsets.only(bottom: 14),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                    child: Row(
                      children: [
                        const Icon(Icons.queue_music, color: Colors.amber),
                        const SizedBox(width: 10),
                        Expanded(child: Text(manager.batchStatus!)),
                        if (manager.onResume != null)
                          TextButton(
                            onPressed: manager.onResume,
                            child: const Text('Resume'),
                          ),
                        TextButton(
                          onPressed: manager.onStopBatch,
                          child: const Text('Cancel all'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (manager.readingStatus != null)
                Card(
                  color: const Color(0xFF1A1A1A),
                  margin: const EdgeInsets.only(bottom: 14),
                  child: ListTile(
                    leading: const Icon(Icons.search, color: Colors.amber),
                    title: Text(manager.readingStatus!),
                  ),
                ),
              if (manager.pending.isNotEmpty) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text('Waiting (${manager.pending.length})',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                    ),
                    TextButton(
                      onPressed: () {
                        final n = manager.pending.length;
                        manager.pending.clear();
                        manager.changed();
                        manager.onQueueChanged?.call();
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(SnackBar(
                              content: Text('Removed $n waiting song(s)')));
                      },
                      child: const Text('Clear waiting'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final p in List.of(manager.pending))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    onTap: () => manager.moveToFront(p),
                    leading: Icon(
                        identical(p, manager.pending.first)
                            ? Icons.skip_next
                            : Icons.schedule,
                        color: Colors.white38),
                    title: Text(p.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(identical(p, manager.pending.first)
                        ? 'Next up'
                        : 'Tap to download next'),
                    trailing: IconButton(
                      tooltip: 'Remove from the list',
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => manager.removePending(p),
                    ),
                  ),
                const SizedBox(height: 16),
              ],
              const Text('Current and recent',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (tasks.isEmpty)
                const Text(
                    'Nothing downloading. Tap the download button on the player page.',
                    style: TextStyle(color: Colors.white38)),
              for (final t in tasks)
                _taskCard(t, onCancel: manager.onCancelCurrent),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                    child: Text('Log',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                  ),
                  TextButton.icon(
                    onPressed: logs.isEmpty
                        ? null
                        : () {
                            final text = logs
                                .map((l) => '[${_clock(l.time)}] ${l.text}')
                                .join('\n');
                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(const SnackBar(
                                  content: Text('Log copied')));
                          },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                  ),
                  TextButton.icon(
                    onPressed: logs.isEmpty ? null : manager.clearLog,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Clear'),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF121212),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: logs.isEmpty
                    ? const Text('Nothing logged yet.',
                        style: TextStyle(color: Colors.white38))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [

                          for (final l in logs.reversed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${_clock(l.time)}  ${l.text}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: l.error
                                      ? Colors.redAccent
                                      : Colors.white70,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  final Listenable refresh;
  final Widget Function() smartCard;
  final Widget Function() offlineCard;
  final VoidCallback onStorage;
  final Widget Function() downloadCard;
  final VoidCallback onBackup, onRestore;
  final Future<String> Function() onCheckYtDlp;

  const SettingsPage({
    super.key,
    required this.refresh,
    required this.smartCard,
    required this.offlineCard,
    required this.onStorage,
    required this.downloadCard,
    required this.onBackup,
    required this.onRestore,
    required this.onCheckYtDlp,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Settings'),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: refresh,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              offlineCard(),
              const SizedBox(height: 12),
              downloadCard(),
              const SizedBox(height: 12),
              smartCard(),
              const SizedBox(height: 12),
              _StorageCard(onTap: onStorage),
              const SizedBox(height: 12),
              _BackupCard(onBackup: onBackup, onRestore: onRestore),

              if (!Platform.isIOS) ...[
                const SizedBox(height: 12),
                _YtDlpCard(onCheck: onCheckYtDlp),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PreferOfflineCard extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onToggle;

  const _PreferOfflineCard({required this.on, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1A1A),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: on,
          onChanged: onToggle,
          title: const Text('Play downloaded version',
              style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text(
              'When a song is also downloaded, play the downloaded copy instead of streaming it. Turn off to always stream. Without internet, downloaded songs still play.'),
        ),
      ),
    );
  }
}

class _SmartDownloadCard extends StatelessWidget {
  final bool on;
  final int limit, today, waiting;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onLimit;

  const _SmartDownloadCard({
    required this.on,
    required this.limit,
    required this.today,
    required this.waiting,
    required this.onToggle,
    required this.onLimit,
  });

  static const int warnAbove = 10;

  @override
  Widget build(BuildContext context) {
    final high = limit > warnAbove;
    return Card(
      color: const Color(0xFF1A1A1A),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: on,
              onChanged: onToggle,
              title: const Text('Smart download',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                  'Downloads a song by itself after you play it 3 times in 7 days.'),
            ),
            if (on) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Expanded(child: Text('Songs per day')),
                  Text('$limit',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: high ? Colors.orangeAccent : null)),
                ],
              ),
              Slider(
                value: limit.toDouble(),
                min: 1,
                max: 50,
                divisions: 49,
                label: '$limit',
                onChanged: (v) => onLimit(v.round()),
              ),
              Text(
                'Today: $today of $limit'
                '${waiting > 0 ? ' · $waiting waiting' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
              const SizedBox(height: 6),
              if (high)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0x33FFAB40),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: Colors.orangeAccent, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Risk: a high number can make YouTube limit or block this connection, so downloads fail until you wait or change network. It also fills your storage and uses a lot of mobile data. The default of 5 per day is the safe choice.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                )
              else
                const Text(
                  'Default is 5 per day. Higher numbers raise the risk of YouTube limiting you.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              const SizedBox(height: 6),
              const Text(
                'Songs over the limit wait for the next day. It only works while the app is open.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DownloadSettingsCard extends StatelessWidget {
  final bool wifiOnly;
  final String quality;
  final ValueChanged<bool> onWifiOnly;
  final ValueChanged<String> onQuality;
  final bool resetWarm;
  final ValueChanged<bool> onResetWarm;
  final bool retryAsk, retryAuto;
  final ValueChanged<bool> onRetryAsk, onRetryAuto;

  const _DownloadSettingsCard({
    required this.retryAsk,
    required this.retryAuto,
    required this.onRetryAsk,
    required this.onRetryAuto,
    required this.wifiOnly,
    required this.quality,
    required this.onWifiOnly,
    required this.onQuality,
    required this.resetWarm,
    required this.onResetWarm,
  });

  static const _hints = {
    'high': 'Best quality, biggest files: about 1.8 MB per minute of music.',
    'medium': '192 kbps: about 1.4 MB per minute. A good middle choice.',
    'small':
        '128 kbps: about 1 MB per minute. Roughly half the space of High and fine for most listening.',
  };

  static const _iosHints = {
    'high': 'Best quality YouTube offers, biggest files.',
    'medium': 'A middle choice between size and quality.',
    'small': 'Smallest files YouTube offers. Fine for most listening.',
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1A1A),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: wifiOnly,
              onChanged: onWifiOnly,
              title: const Text('Download over Wi-Fi only',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                  'On mobile data, downloads (including Smart download) wait and carry on by themselves when Wi-Fi is back.'),
            ),
            if (Platform.isIOS) ...[
              const Divider(height: 24),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: resetWarm,
                onChanged: onResetWarm,
                title: const Text('Reset 15-second wait on page reset',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text(
                    'When you reset the page session (Personalize sound), downloads wait for 15 seconds of music or a sign-in again, like on a fresh install.'),
              ),
            ],
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: retryAsk,
              onChanged: onRetryAsk,
              title: const Text('Ask about failed songs',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                  'When a playlist download has finished, list the songs that failed and ask if you want to download them again.'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: retryAuto,
              onChanged: onRetryAuto,
              title: const Text('Retry failed songs automatically',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                  'No question: failed songs are downloaded again by themselves until everything is saved (up to 5 tries, then you are asked).'),
            ),
            const Divider(height: 24),
            const Text('Download quality',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'high', label: Text('High')),
                  ButtonSegment(value: 'medium', label: Text('Medium')),
                  ButtonSegment(value: 'small', label: Text('Small')),
                ],
                selected: {quality},
                onSelectionChanged: (v) => onQuality(v.first),
              ),
            ),
            const SizedBox(height: 8),
            Text(
                Platform.isIOS
                    ? (_iosHints[quality] ?? '')
                    : (_hints[quality] ?? ''),
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 4),
            const Text(
                'Applies to new downloads. Songs already on the phone keep their quality.',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}

class _BackupCard extends StatelessWidget {
  final VoidCallback onBackup, onRestore;
  const _BackupCard({required this.onBackup, required this.onRestore});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1A1A),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Back up and restore',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
                'Saves your song list, saved links and playlist folders to a file, so a reinstall does not lose how they are organised. You can also include the music files themselves (all songs, or only some playlists) in one .zip; without them, songs missing after a restore can be downloaded again.',
                style: TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onBackup,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Back up'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onRestore,
                    icon: const Icon(Icons.download_for_offline_outlined),
                    label: const Text('Restore'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _YtDlpCard extends StatefulWidget {
  final Future<String> Function() onCheck;
  const _YtDlpCard({required this.onCheck});

  @override
  State<_YtDlpCard> createState() => _YtDlpCardState();
}

class _YtDlpCardState extends State<_YtDlpCard> {
  bool _busy = false;
  String _msg = '';

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _msg = '';
    });
    final r = await widget.onCheck();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msg = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1A1A),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('yt-dlp (the downloader)',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
                'YouTube changes often and downloads can stop working until yt-dlp is updated. The app checks once each time it starts; use this if downloads keep failing.',
                style: TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _run,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.system_update_alt),
                  label: Text(_busy ? 'Checking...' : 'Check for yt-dlp update'),
                ),
              ],
            ),
            if (_msg.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_msg, style: const TextStyle(fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  final VoidCallback onTap;
  const _StorageCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1A1A),
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: const Icon(Icons.storage_rounded),
        title: const Text('Storage',
            style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: const Text(
            'See how much space downloads use and delete the biggest or unplayed songs.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

String _fmtBytes(int b) {
  if (b < 1024) return '$b B';
  final kb = b / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

class StoragePage extends StatefulWidget {
  final List<LocalSong> Function() songs;
  final int Function(LocalSong) addedMs;
  final int? Function(LocalSong) lastPlayedMs;
  final Future<void> Function(List<LocalSong>) onDelete;

  const StoragePage({
    super.key,
    required this.songs,
    required this.addedMs,
    required this.lastPlayedMs,
    required this.onDelete,
  });

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  static const int _idleDays = 90;
  static const int _biggestCount = 10;
  static const int _dayMs = 24 * 3600 * 1000;

  List<LocalSong> _songs = [];
  Map<String, int> _sizes = {};
  bool _loading = true;
  bool _deleting = false;
  int _sort = 0;
  final Set<String> _sel = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final songs = widget.songs();
    final sizes = <String, int>{};
    for (final s in songs) {
      var n = 0;
      try {
        n += await File(s.path).length();
      } catch (_) {}
      if (s.art.isNotEmpty) {
        try {
          n += await File(s.art).length();
        } catch (_) {}
      }
      sizes[s.path] = n;
    }
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _sizes = sizes;
      _loading = false;
      _sel.removeWhere((p) => !sizes.containsKey(p));
    });
  }

  int _size(LocalSong s) => _sizes[s.path] ?? 0;

  int _lastUsed(LocalSong s) {
    final p = widget.lastPlayedMs(s) ?? 0;
    final a = widget.addedMs(s);
    return p > a ? p : a;
  }

  int _idle(LocalSong s) {
    final d =
        ((DateTime.now().millisecondsSinceEpoch - _lastUsed(s)) / _dayMs)
            .floor();
    return d < 0 ? 0 : d;
  }

  List<LocalSong> get _biggest =>
      (List.of(_songs)..sort((a, b) => _size(b).compareTo(_size(a))))
          .take(_biggestCount)
          .toList();

  List<LocalSong> get _idleSongs =>
      _songs.where((s) => _idle(s) >= _idleDays).toList();

  List<LocalSong> get _shown {
    final l = List.of(_songs);
    if (_sort == 0) {
      l.sort((a, b) => _size(b).compareTo(_size(a)));
    } else {
      l.sort((a, b) => _lastUsed(a).compareTo(_lastUsed(b)));
    }
    return l;
  }

  int _bytesOf(Iterable<LocalSong> l) => l.fold(0, (n, s) => n + _size(s));

  String _when(LocalSong s) {
    final played = widget.lastPlayedMs(s);
    final d = _idle(s);
    final ago = d == 0 ? 'today' : (d == 1 ? '1 day ago' : '$d days ago');
    return played == null || played < widget.addedMs(s)
        ? 'Not played · added $ago'
        : 'Played $ago';
  }

  void _selectBiggest() {
    setState(() {
      _sel
        ..clear()
        ..addAll(_biggest.map((s) => s.path));
      _sort = 0;
    });
  }

  void _selectIdle() {
    setState(() {
      _sel
        ..clear()
        ..addAll(_idleSongs.map((s) => s.path));
      _sort = 1;
    });
  }

  Future<void> _deleteSelected() async {
    final chosen = _songs.where((s) => _sel.contains(s.path)).toList();
    if (chosen.isEmpty) return;
    final bytes = _bytesOf(chosen);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${_songsText(chosen.length)}?'),
        content: Text(
            'This frees ${_fmtBytes(bytes)}. The files are removed from the phone and from every folder. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    await widget.onDelete(chosen);
    if (!mounted) return;
    _sel.clear();
    setState(() {
      _deleting = false;
      _loading = true;
    });
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(
              'Deleted ${_songsText(chosen.length)} · freed ${_fmtBytes(bytes)}')));
  }

  @override
  Widget build(BuildContext context) {
    final total = _bytesOf(_songs);
    final idle = _idleSongs;
    final selBytes = _bytesOf(_songs.where((s) => _sel.contains(s.path)));
    final shown = _shown;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Storage'),
      ),
      bottomNavigationBar: _sel.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _deleting ? null : _deleteSelected,
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(
                      'Delete ${_sel.length} · ${_fmtBytes(selBytes)}'),
                ),
              ),
            ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _songs.isEmpty
                ? const Center(
                    child: Text('No downloaded songs',
                        style: TextStyle(color: Colors.white54)))
                : ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_fmtBytes(total),
                                style: const TextStyle(
                                    fontSize: 34, fontWeight: FontWeight.bold)),
                            Text(
                                'used by ${_songsText(_songs.length)}'
                                '${_songs.isEmpty ? '' : ' · average ${_fmtBytes(total ~/ _songs.length)}'}',
                                style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            ActionChip(
                              avatar: const Icon(Icons.data_usage, size: 18),
                              label: Text(
                                  'Select ${_biggest.length} biggest · ${_fmtBytes(_bytesOf(_biggest))}'),
                              onPressed: _selectBiggest,
                            ),
                            ActionChip(
                              avatar: const Icon(Icons.history, size: 18),
                              label: Text(
                                  'Not played in $_idleDays days · ${idle.length}'
                                  '${idle.isEmpty ? '' : ' · ${_fmtBytes(_bytesOf(idle))}'}'),
                              onPressed: idle.isEmpty ? null : _selectIdle,
                            ),
                            if (_sel.isNotEmpty)
                              ActionChip(
                                avatar: const Icon(Icons.close, size: 18),
                                label: const Text('Clear'),
                                onPressed: () => setState(_sel.clear),
                              ),
                          ],
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
                        child: Text(
                          'Pick songs, then delete. Songs played before this update count from the day they were added.',
                          style: TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                        child: SegmentedButton<int>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: 0, label: Text('Biggest')),
                            ButtonSegment(
                                value: 1, label: Text('Longest unplayed')),
                          ],
                          selected: {_sort},
                          onSelectionChanged: (v) =>
                              setState(() => _sort = v.first),
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final s in shown)
                        CheckboxListTile(
                          value: _sel.contains(s.path),
                          onChanged: _deleting
                              ? null
                              : (v) => setState(() {
                                    if (v == true) {
                                      _sel.add(s.path);
                                    } else {
                                      _sel.remove(s.path);
                                    }
                                  }),
                          controlAffinity: ListTileControlAffinity.trailing,
                          secondary: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: _localThumb(s)),
                          title: Text(s.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '${_fmtBytes(_size(s))} · ${_when(s)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  ),
      ),
    );
  }
}

class SavedSong {
  final String vid, title, artist, art;
  const SavedSong(
      {required this.vid,
      required this.title,
      required this.artist,
      required this.art});

  Map<String, dynamic> toJson() =>
      {'vid': vid, 'title': title, 'artist': artist, 'art': art};

  factory SavedSong.fromJson(Map<String, dynamic> j) => SavedSong(
        vid: (j['vid'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        artist: (j['artist'] as String?) ?? '',
        art: (j['art'] as String?) ?? '',
      );
}

class LocalSong {
  final String title, artist, path, art;
  final bool uploaded;
  const LocalSong(
      {required this.title,
      required this.artist,
      required this.path,
      required this.art,
      this.uploaded = false});

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'path': path,
        'art': art,
        'uploaded': uploaded,
      };

  factory LocalSong.fromJson(Map<String, dynamic> j) => LocalSong(
        title: (j['title'] as String?) ?? '',
        artist: (j['artist'] as String?) ?? '',
        path: (j['path'] as String?) ?? '',
        art: (j['art'] as String?) ?? '',
        uploaded: j['uploaded'] == true,
      );
}

class _PlaylistData {
  final String id, title;
  final List<Map<String, String>> songs;
  _PlaylistData(this.id, this.title, this.songs);
}

class PlaylistFolder {
  String id, name, url;
  final Set<String> known;
  final Set<String> paths;

  PlaylistFolder({
    required this.id,
    required this.name,
    required this.url,
    Set<String>? known,
    Set<String>? paths,
  })  : known = known ?? <String>{},
        paths = paths ?? <String>{};

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'known': known.toList(),
        'paths': paths.toList(),
      };

  factory PlaylistFolder.fromJson(Map<String, dynamic> j) => PlaylistFolder(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? 'Playlist',
        url: (j['url'] as String?) ?? '',
        known: ((j['known'] as List?) ?? const []).whereType<String>().toSet(),
        paths: ((j['paths'] as List?) ?? const []).whereType<String>().toSet(),
      );
}

String _songsText(int n) => n == 1 ? '1 song' : '$n songs';

Widget _localThumb(LocalSong s) {
  if (s.art.isEmpty) return DownloadPage._box();
  return Image.file(File(s.art),
      width: 52,
      height: 52,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => DownloadPage._box());
}

class DownloadPage extends StatelessWidget {
  final List<PlaylistFolder> playlists;
  final List<LocalSong> Function(PlaylistFolder?) songsOf;
  final VoidCallback onAdd;
  final void Function(PlaylistFolder?) onOpenFolder;
  final void Function(PlaylistFolder) onRemoveFolder;

  final List<SavedSong> songs;
  final void Function(SavedSong) onPlay;
  final void Function(SavedSong) onRemove;
  final void Function(SavedSong) onUpload;
  final ValueNotifier<String> query;
  final ValueNotifier<int> filter;
  final TextEditingController searchController;
  final void Function(List<LocalSong>, int) onPlayLocal;
  final void Function(LocalSong) onRemoveLocal;
  final void Function(LocalSong) onReplaceLocal;

  final DownloadManager manager;
  final VoidCallback onAddPlaylist;
  final VoidCallback onOpenSettings;

  const DownloadPage({
    super.key,
    required this.playlists,
    required this.songsOf,
    required this.onAdd,
    required this.onOpenFolder,
    required this.onRemoveFolder,
    required this.songs,
    required this.onPlay,
    required this.onRemove,
    required this.onUpload,
    required this.query,
    required this.filter,
    required this.searchController,
    required this.onPlayLocal,
    required this.onRemoveLocal,
    required this.onReplaceLocal,
    required this.manager,
    required this.onAddPlaylist,
    required this.onOpenSettings,
  });

  static Widget _box([IconData icon = Icons.music_note]) => Container(
        width: 52,
        height: 52,
        color: const Color(0xFF282828),
        child: Icon(icon, color: Colors.white38),
      );

  Widget _webThumb(SavedSong s) {
    if (!s.art.startsWith('http')) return _box();
    return Image.network(s.art,
        width: 52,
        height: 52,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _box());
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(text,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      );

  static const _cardGrey = Color(0xFF282828);

  Text _sub(String t) => Text(t,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.white54, fontSize: 13));

  Widget _cover(List<LocalSong> list, IconData emptyIcon) {
    final arts = list.where((s) => s.art.isNotEmpty).take(4).toList();
    Widget img(LocalSong s) => Image.file(File(s.art),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => Container(color: _cardGrey));
    final Widget body;
    if (arts.length >= 4) {
      body = Column(children: [
        Expanded(
            child: Row(children: [
          Expanded(child: img(arts[0])),
          Expanded(child: img(arts[1])),
        ])),
        Expanded(
            child: Row(children: [
          Expanded(child: img(arts[2])),
          Expanded(child: img(arts[3])),
        ])),
      ]);
    } else if (arts.isNotEmpty) {
      body = img(arts.first);
    } else {
      body = Container(
          color: _cardGrey,
          child: Center(
              child: Icon(emptyIcon, size: 56, color: Colors.white38)));
    }
    return ClipRRect(borderRadius: BorderRadius.circular(8), child: body);
  }

  Widget _corner(VoidCallback onPressed) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(Icons.delete_outline, size: 18, color: Colors.white),
          ),
        ),
      );

  Widget _folderCard({
    required double width,
    required Widget cover,
    required String title,
    required Widget subtitle,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    Widget? corner,
  }) =>
      SizedBox(
        width: width,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    cover,
                    if (corner != null)
                      Positioned(top: 6, right: 6, child: corner),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              subtitle,
            ],
          ),
        ),
      );

  Future<void> _confirmRemove(BuildContext context, PlaylistFolder p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${p.name}"?'),
        content: const Text(
            'Only the folder is removed. The songs stay on this device in the Download folder.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) onRemoveFolder(p);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: ListView(
        padding: const EdgeInsets.all(16),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Downloads',
                    style:
                        TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: onOpenSettings,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _searchBar(),
          const SizedBox(height: 8),
          _filterChips(),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: Listenable.merge([query, filter]),
            builder: (context, _) {
              if (query.value.trim().isNotEmpty || filter.value != 0) {
                return _results(context);
              }
              return _browse(context);
            },
          ),
        ],
      ),
    );
  }

  Widget _searchBar() => ValueListenableBuilder<String>(
        valueListenable: query,
        builder: (_, q, __) => TextField(
          controller: searchController,
          onChanged: (v) => query.value = v,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search songs and playlists',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      searchController.clear();
                      query.value = '';
                    },
                  ),
            filled: true,
            fillColor: const Color(0xFF1A1A1A),
            contentPadding: EdgeInsets.zero,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      );

  Widget _filterChips() => ValueListenableBuilder<int>(
        valueListenable: filter,
        builder: (_, f, __) {
          final all = songsOf(null);
          final withMp3 = all.where((s) => s.uploaded).length;
          final labels = [
            'All',
            'Downloaded (${all.length - withMp3})',
            'Saved (${songs.length})',
            'Saved with MP3 ($withMp3)',
          ];
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < labels.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(labels[i]),
                      selected: f == i,
                      onSelected: (_) => filter.value = i,
                    ),
                  ),
              ],
            ),
          );
        },
      );

  Widget _localTile(List<LocalSong> list, int i) {
    final s = list[i];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => onPlayLocal(list, i),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: _localThumb(s),
      ),
      title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (s.uploaded)
            IconButton(
              tooltip: 'Replace MP3',
              icon: const Icon(Icons.edit_outlined, color: Colors.white54),
              onPressed: () => onReplaceLocal(s),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white54),
            onPressed: () => onRemoveLocal(s),
          ),
        ],
      ),
    );
  }

  Widget _savedTile(SavedSong s) => ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: () => onPlay(s),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: _webThumb(s),
        ),
        title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Upload MP3',
              icon: const Icon(Icons.upload_file, color: Colors.white70),
              onPressed: () => onUpload(s),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white54),
              onPressed: () => onRemove(s),
            ),
          ],
        ),
      );

  Widget _results(BuildContext context) {
    final q = query.value.trim().toLowerCase();
    final f = filter.value;
    bool hit(String title, String artist) =>
        q.isEmpty ||
        title.toLowerCase().contains(q) ||
        artist.toLowerCase().contains(q);
    final all = songsOf(null);
    final downloaded =
        all.where((s) => !s.uploaded && hit(s.title, s.artist)).toList();
    final withMp3 =
        all.where((s) => s.uploaded && hit(s.title, s.artist)).toList();
    final saved = songs.where((s) => hit(s.title, s.artist)).toList();
    final folders = (f == 0 && q.isNotEmpty)
        ? playlists.where((p) => p.name.toLowerCase().contains(q)).toList()
        : <PlaylistFolder>[];
    final showDownloaded = f == 0 || f == 1;
    final showSaved = f == 0 || f == 2;
    final showWithMp3 = f == 0 || f == 3;
    final empty = folders.isEmpty &&
        (!showDownloaded || downloaded.isEmpty) &&
        (!showSaved || saved.isEmpty) &&
        (!showWithMp3 || withMp3.isEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (empty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text('No songs found.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38)),
          ),
        if (folders.isNotEmpty) ...[
          _heading('Playlists (${folders.length})'),
          for (final p in folders)
            ListTile(
              contentPadding: EdgeInsets.zero,
              onTap: () => onOpenFolder(p),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: _box(Icons.playlist_play),
              ),
              title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('Playlist • ${_songsText(songsOf(p).length)}'),
            ),
        ],
        if (showDownloaded && downloaded.isNotEmpty) ...[
          _heading('Downloaded (${downloaded.length})'),
          for (var i = 0; i < downloaded.length; i++) _localTile(downloaded, i),
        ],
        if (showWithMp3 && withMp3.isNotEmpty) ...[
          _heading('Saved with MP3 (${withMp3.length})'),
          for (var i = 0; i < withMp3.length; i++) _localTile(withMp3, i),
        ],
        if (showSaved && saved.isNotEmpty) ...[
          _heading('Saved (${saved.length})'),
          for (final s in saved) _savedTile(s),
        ],
      ],
    );
  }

  Widget _browse(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: const Text('Add music from this device'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onAddPlaylist,
          icon: const Icon(Icons.playlist_add),
          label: const Text('Add playlist (public or unlisted link)'),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(builder: (context, c) {
          final w = (c.maxWidth - 16) / 2;
          final all = songsOf(null);
          return Wrap(
            spacing: 16,
            runSpacing: 20,
            children: [
              _folderCard(
                width: w,
                cover: _cover(const [], Icons.downloading),
                title: 'Downloading',
                subtitle: ListenableBuilder(
                  listenable: manager,
                  builder: (_, __) => _sub(manager.summary),
                ),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DownloadingPage(manager: manager))),
              ),
              _folderCard(
                width: w,
                cover: _cover(all, Icons.library_music),
                title: 'Download',
                subtitle: _sub('Folder • ${_songsText(all.length)}'),
                onTap: () => onOpenFolder(null),
              ),
              for (final p in playlists)
                _folderCard(
                  width: w,
                  cover: _cover(songsOf(p), Icons.playlist_play),
                  title: p.name,
                  subtitle:
                      _sub('Playlist • ${_songsText(songsOf(p).length)}'),
                  onTap: () => onOpenFolder(p),
                  onLongPress: () => _confirmRemove(context, p),
                  corner: _corner(() => _confirmRemove(context, p)),
                ),
            ],
          );
        }),
        _heading('Saved from YouTube Music'),
        if (songs.isEmpty)
          const Text(
              'Tap the bookmark button on the player page to save a song link here.',
              style: TextStyle(color: Colors.white38)),
        if (songs.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              "Can't download a song? Tap the upload icon and pick its MP3 file. It then moves to the Download folder.",
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ),
        for (final s in songs) _savedTile(s),
      ],
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final double size, iconSize;
  final Color background, foreground;
  final String tooltip;
  final VoidCallback? onTap;

  const _CircleButton({
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.background,
    required this.foreground,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Material(
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: foreground, size: iconSize),
            ),
          ),
        ),
      ),
    );
  }
}

class FolderPage extends StatelessWidget {
  final String title;
  final Listenable refresh;
  final List<LocalSong> Function() songs;
  final LocalSong? Function() playing;
  final void Function(List<LocalSong>, int) onPlay;
  final void Function(LocalSong) onRemove;
  final void Function(LocalSong) onReplace;
  final VoidCallback? onUpdate;
  final DownloadManager manager;
  final String? folderId;
  final int Function() sortMode;
  final void Function(int) onSort;
  final ValueNotifier<String> query;
  final void Function(List<LocalSong>) onShuffle;

  static const sortNames = [
    'Newest first',
    'Oldest first',
    'Title A-Z',
    'Artist A-Z',
  ];

  const FolderPage({
    super.key,
    required this.query,
    required this.onShuffle,
    required this.sortMode,
    required this.onSort,
    required this.folderId,
    required this.title,
    required this.refresh,
    required this.songs,
    required this.playing,
    required this.onPlay,
    required this.onRemove,
    required this.onReplace,
    required this.onUpdate,
    required this.manager,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(title),
        actions: [
          ListenableBuilder(
            listenable: refresh,
            builder: (context, _) => PopupMenuButton<int>(
              tooltip: 'Sort',
              icon: const Icon(Icons.sort),
              onSelected: onSort,
              itemBuilder: (_) => [
                for (var i = 0; i < sortNames.length; i++)
                  CheckedPopupMenuItem<int>(
                    value: i,
                    checked: sortMode() == i,
                    child: Text(sortNames[i]),
                  ),
              ],
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _FolderSearchField(query: query),
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([refresh, query]),
                builder: (context, _) {
                  final all = songs();
                  final q = query.value.trim().toLowerCase();
                  final list = q.isEmpty
                      ? all
                      : all
                          .where((s) =>
                              s.title.toLowerCase().contains(q) ||
                              s.artist.toLowerCase().contains(q))
                          .toList();
                  final now = playing();
                  final busy = manager.readingStatus != null;
                  final active = manager.activeFor(folderId);
                  final waiting = manager.pendingFor(folderId);
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _CircleButton(
                            icon: Icons.shuffle,
                            size: 48,
                            iconSize: 24,
                            background: const Color(0xFF282828),
                            foreground: Colors.white,
                            tooltip: 'Shuffle',
                            onTap: list.isEmpty ? null : () => onShuffle(list),
                          ),
                          const SizedBox(width: 20),
                          _CircleButton(
                            icon: Icons.play_arrow_rounded,
                            size: 72,
                            iconSize: 44,
                            background: Colors.white,
                            foreground: Colors.black,
                            tooltip: 'Play',
                            onTap: list.isEmpty ? null : () => onPlay(list, 0),
                          ),
                          if (onUpdate != null) ...[
                            const SizedBox(width: 20),
                            _CircleButton(
                              icon: Icons.refresh,
                              size: 48,
                              iconSize: 24,
                              background: const Color(0xFF282828),
                              foreground: Colors.white,
                              tooltip: 'Update',
                              onTap: busy ? null : onUpdate,
                            ),
                          ],
                        ],
                      ),
                      if (onUpdate != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          busy
                              ? (manager.readingStatus ?? '')
                              : 'Update checks the playlist and lets you choose which songs to download.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white54),
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (active.isNotEmpty || waiting.isNotEmpty) ...[
                        Row(
                          children: [
                            const Expanded(
                              child: Text('Downloading',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600)),
                            ),
                            TextButton(
                              onPressed: () => manager.cancelFolder(folderId),
                              child: const Text('Cancel all'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (final t in active)
                          DownloadingPage._taskCard(t,
                              onCancel: manager.onCancelCurrent),
                        for (final p in waiting)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            onTap: () => manager.moveToFront(p),
                            leading: Icon(
                                identical(p, waiting.first)
                                    ? Icons.skip_next
                                    : Icons.schedule,
                                color: Colors.white38),
                            title: Text(p.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(identical(p, waiting.first)
                                ? 'Next up'
                                : 'Waiting · tap to download next'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!identical(p, waiting.first))
                                  const Icon(Icons.vertical_align_top,
                                      color: Colors.white54),
                                IconButton(
                                  tooltip: 'Remove from the list',
                                  icon: const Icon(Icons.close,
                                      color: Colors.white54),
                                  onPressed: () => manager.removePending(p),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 16),
                      ],
                      Text(
                          q.isEmpty
                              ? '${_songsText(list.length)} · ${sortNames[sortMode()]}'
                              : '${list.length} of ${_songsText(all.length)} match',
                          style: const TextStyle(color: Colors.white54)),
                      const SizedBox(height: 8),
                      if (list.isEmpty)
                        Text(
                            q.isEmpty
                                ? 'No songs here yet.'
                                : 'No songs match your search.',
                            style: const TextStyle(color: Colors.white38)),
                      for (var i = 0; i < list.length; i++)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          onTap: () => onPlay(list, i),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: _localThumb(list[i]),
                          ),
                          title: Text(list[i].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: identical(list[i], now)
                                      ? Colors.redAccent
                                      : null)),
                          subtitle: Text(list[i].artist,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (list[i].uploaded)
                                IconButton(
                                  tooltip: 'Replace MP3',
                                  icon: const Icon(Icons.edit_outlined,
                                      color: Colors.white54),
                                  onPressed: () => onReplace(list[i]),
                                ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.white54),
                                onPressed: () => onRemove(list[i]),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }
}

class _FolderSearchField extends StatefulWidget {
  final ValueNotifier<String> query;
  const _FolderSearchField({required this.query});

  @override
  State<_FolderSearchField> createState() => _FolderSearchFieldState();
}

class _FolderSearchFieldState extends State<_FolderSearchField> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.query.value);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: ValueListenableBuilder<String>(
        valueListenable: widget.query,
        builder: (_, q, __) => TextField(
          controller: _ctl,
          onChanged: (v) => widget.query.value = v,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search in this folder',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _ctl.clear();
                      widget.query.value = '';
                    },
                  ),
            filled: true,
            fillColor: const Color(0xFF1A1A1A),
            contentPadding: EdgeInsets.zero,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}

class PersonalizeSoundPage extends StatelessWidget {
  const PersonalizeSoundPage({super.key});

  static String _hz(double f) =>
      f >= 1000 ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)}k' : '${f.round()}';

  Future<void> _saveAs(BuildContext context) async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Save as a new profile'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 30,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Name, e.g. My headphones'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (name != null) eqState.saveAs(name);
  }

  Widget _sliders(BuildContext context) {
    return SizedBox(
      height: 230,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < kEqFreqs.length; i++)
            Expanded(
              child: Column(
                children: [
                  Text(
                      '${eqState.gains[i] > 0 ? '+' : ''}${eqState.gains[i].round()}',
                      style: const TextStyle(fontSize: 11, color: Colors.white70)),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape:
                              const RoundSliderThumbShape(enabledThumbRadius: 7),
                          overlayShape:
                              const RoundSliderOverlayShape(overlayRadius: 14),
                          activeTrackColor: Colors.redAccent,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.redAccent,
                        ),
                        child: Slider(
                          min: -12,
                          max: 12,
                          divisions: 24,
                          value: eqState.gains[i].clamp(-12.0, 12.0).toDouble(),
                          onChanged: (v) => eqState.setGain(i, v),
                        ),
                      ),
                    ),
                  ),
                  Text(_hz(kEqFreqs[i]),
                      style: const TextStyle(fontSize: 11, color: Colors.white54)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _resetPageSession(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset page session?'),
        content: const Text(
            'This makes the YouTube Music page forget its cookies and saved data, so it starts like a fresh install. You will be signed out of YouTube Music. Your downloaded songs, playlists and settings in this app are not touched.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reset')),
        ],
      ),
    );
    if (go != true) return;
    String msg;
    try {
      await audioHandler.resetPageSession?.call();
      msg = 'Done. Wait for the page to load, play a song, then download.';
    } catch (e) {
      msg = 'Could not reset: $e';
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _checkDownloadLink(BuildContext context) async {
    String text;
    try {
      final r = await (audioHandler.runJsResult?.call(
                  'window.__gvDiag ? window.__gvDiag() : "hook not installed in the page"') ??
              Future.value('no web view yet'))
          .timeout(const Duration(seconds: 8));
      text = r.toString();
    } catch (e) {
      text = 'Could not ask the page: $e';
    }
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download link check'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  /// Live view of the streaming tap: counters, state and the event log.
  Future<void> _showTapDebug(BuildContext context) async {
    Future<Map<String, dynamic>> fetch() async {
      try {
        final r = await (audioHandler.runJsResult?.call(
                    'window.__webTap ? JSON.stringify({status: window.__webTap.status(), diag: window.__webTap.diag(), log: window.__webTap.log().slice(-160)}) : "null"') ??
                Future.value('"null"'))
            .timeout(const Duration(seconds: 5));
        var s = r.toString();
        if (s.startsWith('"')) {
          try {
            s = jsonDecode(s) as String;
          } catch (_) {}
        }
        if (s == 'null') return {'error': 'The tap script is not installed in the page (reload the page).'};
        return Map<String, dynamic>.from(jsonDecode(s) as Map);
      } catch (e) {
        return {'error': 'Could not ask the page: $e'};
      }
    }

    String render(Map<String, dynamic> d) {
      final b = StringBuffer();
      b.writeln('Setting: tap ${eqState.tapOn ? 'ON' : 'OFF'}, equalizer ${eqState.enabled ? 'on' : 'off'}, boost ${eqState.boostDb.toStringAsFixed(0)} dB');
      b.writeln('Page report: ${audioHandler.webEqStatus}');
      if (d['error'] != null) {
        b.writeln(d['error']);
        return b.toString();
      }
      b.writeln('Tap: ${d['status']}');
      final g = (d['diag'] as Map?) ?? {};
      b.writeln('enabled=${g['enabled']} muting=${g['muting']} fallback=${g['fallback']} playing=${g['playing']} disabled="${g['disabled']}"');
      b.writeln('stream: ${g['codec']} ${jsonEncode(g['asc'])} ctx=${jsonEncode(g['ctx'])}');
      b.writeln('segments: ${g['segs']} (decoded ${g['decoded']}), cache ${g['cachedMB']} MB, range ${jsonEncode(g['range'])}');
      b.writeln('stats: ${jsonEncode(g['stats'])}');
      if ((g['lastError'] ?? '').toString().isNotEmpty) b.writeln('last error: ${g['lastError']}');
      b.writeln('--- log (newest last) ---');
      for (final e in (d['log'] as List? ?? const [])) {
        final l = e as List;
        b.writeln('${(l[0] as num).toStringAsFixed(1)}s  ${l[1]}  ${l[2]}');
      }
      return b.toString();
    }

    var text = render(await fetch());
    if (!context.mounted) return;
    Timer? timer;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        timer ??= Timer.periodic(const Duration(seconds: 1), (_) async {
          final t = render(await fetch());
          if (ctx.mounted) setS(() => text = t);
        });
        return AlertDialog(
          title: const Text('Streaming tap debug'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(text,
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 10)),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Copied the log')));
                },
                child: const Text('Copy')),
            TextButton(
                onPressed: () async {
                  try {
                    await audioHandler.runJs
                        ?.call('if(window.__webTap)window.__webTap.clearLog()');
                  } catch (_) {}
                },
                child: const Text('Clear')),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        );
      }),
    );
    timer?.cancel();
  }

  Future<void> _checkWebEq(BuildContext context) async {
    String text;
    try {
      final r = await (audioHandler.runJsResult
              ?.call('window.__webEqDiag ? window.__webEqDiag() : "script not installed in the page"') ??
          Future.value('no web view yet'))
          .timeout(const Duration(seconds: 8));
      text = r.toString();
    } catch (e) {
      text = 'Could not ask the page: $e';
    }
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Streaming effects check'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _fxSlider(String label, double v, ValueChanged<double> on) {
    return Row(
      children: [
        SizedBox(width: 78, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: Slider(value: v, min: 0, max: 1, divisions: 20, onChanged: on),
        ),
        SizedBox(
            width: 38,
            child: Text('${(v * 100).round()}%',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, color: Colors.white54))),
      ],
    );
  }

  Widget _fxCard(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1A1A),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.surround_sound_rounded),
              SizedBox(width: 10),
              Text('Sound effects',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            const Text(
                'Wider, deeper, more spacious sound for streaming and downloaded songs. Works best with headphones.',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 0,
              children: [
                for (final f in EqSettings.fxPresets)
                  ChoiceChip(
                    label: Text(f.name),
                    selected: eqState.fxId == f.id,
                    onSelected: (_) => eqState.selectFx(f),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            _fxSlider('Width', eqState.fxWide, (v) => eqState.setFx(wide: v)),
            _fxSlider('Bass', eqState.fxBass, (v) => eqState.setFx(bass: v)),
            _fxSlider('Clarity', eqState.fxClarity, (v) => eqState.setFx(clarity: v)),
            _fxSlider('Room', eqState.fxRoom, (v) => eqState.setFx(room: v)),
            if (audioHandler.fxNative['virtualizer'] == false &&
                eqState.fxWide > 0)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                    'This phone has no wide-sound effect for downloaded songs; streaming songs still get it.',
                    style: TextStyle(fontSize: 12, color: Colors.orangeAccent)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _boosterCard(BuildContext context) {
    final db = eqState.boostDb;
    final high = db > 6;
    return Card(
      color: const Color(0xFF1A1A1A),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.volume_up_rounded),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Volume booster',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(db == 0 ? 'Off' : '+${db.round()} dB',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: high
                            ? Colors.orangeAccent
                            : (db > 0 ? Colors.redAccent : Colors.white54))),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: high ? Colors.orangeAccent : Colors.redAccent,
                thumbColor: high ? Colors.orangeAccent : Colors.redAccent,
                inactiveTrackColor: Colors.white24,
              ),
              child: Slider(
                min: 0,
                max: kMaxBoostDb,
                divisions: kMaxBoostDb.round(),
                value: db,
                onChanged: eqState.setBoost,
              ),
            ),
            Text(
                'Makes songs louder than the volume buttons allow, which helps with quiet recordings or a weak speaker. Works on downloaded and streaming songs.',
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
            if (high) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0x33FFAB40),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: Colors.orangeAccent, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          'A high boost can distort the sound and is hard on your ears and speaker. Start low and raise it slowly, especially with headphones.',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
            if (audioHandler.boostWorks == false) ...[
              const SizedBox(height: 8),
              const Text('This phone did not accept the volume booster.',
                  style: TextStyle(fontSize: 12, color: Colors.orangeAccent)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tile(EqProfile p) {
    final sel = p.id == eqState.selectedId;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      selected: sel,
      selectedColor: Colors.redAccent,
      onTap: () => eqState.select(p),
      leading: Icon(sel ? Icons.radio_button_checked : Icons.radio_button_off,
          color: sel ? Colors.redAccent : Colors.white38),
      title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: p.desc.isEmpty
          ? null
          : Text(p.desc,
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
      trailing: p.builtIn
          ? null
          : IconButton(
              tooltip: 'Delete profile',
              icon: const Icon(Icons.delete_outline, color: Colors.white54),
              onPressed: () => eqState.deleteCustom(p.id),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: ListenableBuilder(
        listenable: eqState,
        builder: (context, _) {
          final sel = eqState.selected;
          final mine = eqState.custom;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Personalize sound',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _boosterCard(context),
              const SizedBox(height: 12),
              _fxCard(context),
              const SizedBox(height: 12),
              Card(
                color: const Color(0xFF1A1A1A),
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: eqState.enabled,
                        onChanged: eqState.setEnabled,
                        title: const Text('Equalizer',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(eqState.enabled
                            ? '${sel?.name ?? 'Custom'}${eqState.modified ? ' (changed)' : ''}'
                            : 'Off: songs play as they are'),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                          'Works on downloaded songs and on songs streaming from YouTube Music. For a streaming song, the change may take a second to be heard.',
                          style: TextStyle(fontSize: 12, color: Colors.white54)),
                      if (Platform.isIOS) ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: eqState.tapOn,
                          onChanged: eqState.setTapOn,
                          title: const Text('Effects on streaming songs'),
                          subtitle: const Text(
                              'Experimental. Plays streaming songs through the equalizer and booster. Turn it off if music gets stuck.'),
                        ),
                        TextButton.icon(
                          onPressed: () => _showTapDebug(context),
                          icon: const Icon(Icons.bug_report, size: 18),
                          label: const Text('Streaming debug log'),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                          'Streaming effects: ${audioHandler.webEqStatus.isEmpty ? 'no report from the page yet' : audioHandler.webEqStatus}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.lightBlueAccent)),
                      TextButton.icon(
                        onPressed: () => _checkWebEq(context),
                        icon: const Icon(Icons.bug_report_outlined, size: 18),
                        label: const Text('Check streaming effects'),
                      ),
                      TextButton.icon(
                        onPressed: () => _checkDownloadLink(context),
                        icon: const Icon(Icons.link, size: 18),
                        label: const Text('Check download link'),
                      ),
                      TextButton.icon(
                        onPressed: () => _resetPageSession(context),
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: const Text('Reset page session (signs you out)'),
                      ),
                      if (audioHandler.eqWorks == false) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0x33FFAB40),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                              Platform.isIOS
                                  ? 'The equalizer for songs on this iPhone could not start. Play a downloaded song once, then try again.'
                                  : 'This phone did not accept the equalizer, so the sound cannot be changed here.',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                color: const Color(0xFF1A1A1A),
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                  child: Column(
                    children: [
                      Opacity(
                          opacity: eqState.enabled ? 1 : 0.5,
                          child: _sliders(context)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: () =>
                                eqState.select(EqSettings.builtIns.first),
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('Reset'),
                          ),
                          TextButton.icon(
                            onPressed: () => _saveAs(context),
                            icon: const Icon(Icons.add),
                            label: const Text('Save as new profile'),
                          ),
                          if (sel != null && !sel.builtIn && eqState.modified)
                            TextButton.icon(
                              onPressed: eqState.updateSelected,
                              icon: const Icon(Icons.save_outlined),
                              label: Text('Update "${sel.name}"'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (mine.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(0, 20, 0, 4),
                  child: Text('Your profiles',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                for (final p in mine) _tile(p),
              ],
              const Padding(
                padding: EdgeInsets.fromLTRB(0, 20, 0, 4),
                child: Text('Presets',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              for (final p in EqSettings.builtIns) _tile(p),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

Widget _nowArt(MediaItem item, {double? size}) {
  Widget box() => Container(
        width: size,
        height: size,
        color: const Color(0xFF282828),
        child: Icon(Icons.music_note,
            color: Colors.white38, size: size == null ? 96 : size * 0.5),
      );
  final u = item.artUri;
  if (u == null) return box();
  if (u.scheme == 'file') {
    return Image.file(File(u.toFilePath()),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => box());
  }
  return Image.network(u.toString(),
      width: size,
      height: size,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => box());
}

class _PositionBuilder extends StatefulWidget {
  final Widget Function(BuildContext, Duration) builder;
  const _PositionBuilder({required this.builder});

  @override
  State<_PositionBuilder> createState() => _PositionBuilderState();
}

class _PositionBuilderState extends State<_PositionBuilder> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, audioHandler.playbackState.value.position);
}

void _openNowPlaying(BuildContext context) {
  Navigator.of(context).push(PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 250),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => const NowPlayingPage(),
    transitionsBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

class MiniPlayer extends StatelessWidget {

  final String? label;
  const MiniPlayer({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      initialData: audioHandler.mediaItem.value,
      builder: (context, itemSnap) {
        final item = itemSnap.data;
        return StreamBuilder<PlaybackState>(
          stream: audioHandler.playbackState,
          initialData: audioHandler.playbackState.value,
          builder: (context, stateSnap) {
            final st = stateSnap.data;
            if (item == null ||
                st == null ||
                st.processingState == AudioProcessingState.idle) {
              return const SizedBox.shrink();
            }
            final playing = st.playing;
            final artist = item.artist ?? '';
            return Material(
              color: const Color(0xFF212121),
              child: InkWell(
                onTap: () => _openNowPlaying(context),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (label != null)
                      Container(
                        width: double.infinity,
                        color: const Color(0xFF2E2E2E),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.offline_pin,
                                size: 14, color: Colors.greenAccent),
                            const SizedBox(width: 6),
                            Text(label!,
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.white70)),
                          ],
                        ),
                      ),

                    _PositionBuilder(builder: (_, pos) {
                      final total = item.duration?.inMilliseconds ?? 0;
                      final v = total > 0
                          ? (pos.inMilliseconds / total).clamp(0.0, 1.0)
                          : 0.0;
                      return LinearProgressIndicator(
                        value: v.toDouble(),
                        minHeight: 2,
                        color: Colors.white,
                        backgroundColor: Colors.white12,
                      );
                    }),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: _nowArt(item, size: 44),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                if (artist.isNotEmpty)
                                  Text(artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 12)),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: playing ? 'Pause' : 'Play',
                            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                            onPressed: () => playing
                                ? audioHandler.pause()
                                : audioHandler.play(),
                          ),
                          IconButton(
                            tooltip: 'Next',
                            icon: const Icon(Icons.skip_next),
                            onPressed: () => audioHandler.skipToNext(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: StreamBuilder<MediaItem?>(
          stream: audioHandler.mediaItem,
          initialData: audioHandler.mediaItem.value,
          builder: (context, itemSnap) {
            final item = itemSnap.data;
            return Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: 'Close',
                    iconSize: 32,
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
                if (item == null)
                  const Expanded(
                    child: Center(
                      child: Text('Nothing is playing',
                          style: TextStyle(color: Colors.white54)),
                    ),
                  )
                else
                  Expanded(child: _body(context, item)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context, MediaItem item) {
    final artist = item.artist ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _nowArt(item),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          ),
          if (artist.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 15, color: Colors.white60)),
              ),
            ),
          const SizedBox(height: 12),
          _SeekBar(duration: item.duration),
          StreamBuilder<PlaybackState>(
            stream: audioHandler.playbackState,
            initialData: audioHandler.playbackState.value,
            builder: (context, snap) {
              final playing = snap.data?.playing ?? false;
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous',
                    iconSize: 40,
                    icon: const Icon(Icons.skip_previous),
                    onPressed: () => audioHandler.skipToPrevious(),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filled(
                    tooltip: playing ? 'Pause' : 'Play',
                    iconSize: 44,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                    ),
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed: () => playing
                        ? audioHandler.pause()
                        : audioHandler.play(),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: 'Next',
                    iconSize: 40,
                    icon: const Icon(Icons.skip_next),
                    onPressed: () => audioHandler.skipToNext(),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          const _PlayerOptionsRow(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _PlayerOptionsRow extends StatelessWidget {
  const _PlayerOptionsRow();

  static const _repeatNames = ['Repeat off', 'Repeat all', 'Repeat one'];

  @override
  Widget build(BuildContext context) {
    const on = Colors.redAccent;
    const off = Colors.white54;
    return StreamBuilder<PlaybackState>(
      stream: audioHandler.playbackState,
      initialData: audioHandler.playbackState.value,
      builder: (context, _) => ListenableBuilder(
        listenable: playerOpts,
        builder: (context, _) {
          final local = audioHandler.isLocal;
          final r = playerOpts.repeat;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (local)
                IconButton(
                  tooltip: playerOpts.shuffle ? 'Shuffle on' : 'Shuffle off',
                  icon: Icon(Icons.shuffle,
                      color: playerOpts.shuffle ? on : off),
                  onPressed: () => playerOpts.setShuffle(!playerOpts.shuffle),
                ),
              if (local)
                IconButton(
                  tooltip: _repeatNames[r],
                  icon: Icon(r == 2 ? Icons.repeat_one : Icons.repeat,
                      color: r == 0 ? off : on),
                  onPressed: playerOpts.cycleRepeat,
                ),
              const _SleepButton(),
            ],
          );
        },
      ),
    );
  }
}

class _SleepButton extends StatefulWidget {
  const _SleepButton();

  @override
  State<_SleepButton> createState() => _SleepButtonState();
}

class _SleepButtonState extends State<_SleepButton> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && playerOpts.sleepAt != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _left() {
    if (playerOpts.sleepAtSongEnd) return 'End of song';
    final at = playerOpts.sleepAt;
    if (at == null) return '';
    final d = at.difference(DateTime.now());
    final secs = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = secs ~/ 3600;
    final m = ((secs % 3600) ~/ 60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final sec = (secs % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$sec' : '$m:$sec';
  }

  void _pick(BuildContext sheet, String text, VoidCallback apply) {
    apply();
    Navigator.pop(sheet);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _open() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Sleep timer',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              if (playerOpts.sleepActive)
                ListTile(
                  leading: const Icon(Icons.timer_off_outlined),
                  title: const Text('Turn off the timer'),
                  onTap: () => _pick(
                      sheet, 'Sleep timer off', playerOpts.cancelSleep),
                ),
              for (final m in const [15, 30, 45, 60, 90])
                ListTile(
                  leading: const Icon(Icons.bedtime_outlined),
                  title: Text('$m minutes'),
                  onTap: () => _pick(
                      sheet,
                      'Music will pause in $m minutes',
                      () => playerOpts.sleepIn(Duration(minutes: m))),
                ),
              ListTile(
                leading: const Icon(Icons.music_note_outlined),
                title: const Text('End of this song'),
                onTap: () => _pick(sheet, 'Music will pause after this song',
                    playerOpts.sleepAtEndOfSong),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = playerOpts.sleepActive;
    final left = _left();
    return TextButton.icon(
      onPressed: _open,
      style: TextButton.styleFrom(
          foregroundColor: active ? Colors.redAccent : Colors.white54),
      icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
      label: Text(active ? left : 'Sleep timer'),
    );
  }
}

class _SeekBar extends StatefulWidget {
  final Duration? duration;
  const _SeekBar({required this.duration});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final total = (widget.duration?.inMilliseconds ?? 0).toDouble();
    return _PositionBuilder(builder: (_, pos) {
      final cur = (_drag ?? pos.inMilliseconds.toDouble())
          .clamp(0.0, total > 0 ? total : 0.0)
          .toDouble();
      return Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: Colors.white24,
            ),
            child: Slider(
              min: 0,
              max: total > 0 ? total : 1,
              value: cur,
              onChanged: total > 0 ? (v) => setState(() => _drag = v) : null,
              onChangeEnd: (v) {
                audioHandler.seek(Duration(milliseconds: v.round()));
                setState(() => _drag = null);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(Duration(milliseconds: cur.round())),
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white60)),
                Text(total > 0 ? _fmt(widget.duration!) : '',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white60)),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class _BackupChoice {
  final bool audio;
  final bool all;
  final Set<String> folderIds;
  final bool loose;
  const _BackupChoice(
      {required this.audio,
      required this.all,
      required this.folderIds,
      required this.loose});
}

class _BackupRow {
  final String id, name;
  final int songs, bytes;
  const _BackupRow(this.id, this.name, this.songs, this.bytes);
}

class _AudioJob {
  final LocalSong song;
  final String name;
  final String? art;
  final int size;
  const _AudioJob(this.song, this.name, this.art, this.size);
}

class _ZipNames {
  final String file;
  final String? art;
  const _ZipNames(this.file, this.art);
}

class _ZipSong {
  final String vid, title, artist, file, art;
  const _ZipSong(this.vid, this.title, this.artist, this.file, this.art);
}

class _Prog {
  final String text;
  final double? value;
  const _Prog(this.text, this.value);
}

class _ProgressDialog extends StatelessWidget {
  final String title;
  final ValueListenable<_Prog> progress;
  final VoidCallback onCancel;
  const _ProgressDialog(
      {required this.title, required this.progress, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: ValueListenableBuilder<_Prog>(
          valueListenable: progress,
          builder: (context, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.text, maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 14),
              LinearProgressIndicator(value: p.value),
              if (p.value != null) ...[
                const SizedBox(height: 6),
                Text('${(p.value! * 100).round()}%',
                    style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      ),
    );
  }
}

class _BackupOptionsDialog extends StatefulWidget {
  final int totalSongs, totalBytes, looseSongs, looseBytes;
  final List<_BackupRow> rows;
  const _BackupOptionsDialog({
    required this.totalSongs,
    required this.totalBytes,
    required this.rows,
    required this.looseSongs,
    required this.looseBytes,
  });

  @override
  State<_BackupOptionsDialog> createState() => _BackupOptionsDialogState();
}

class _BackupOptionsDialogState extends State<_BackupOptionsDialog> {
  bool _audio = false;
  bool _all = true;
  bool _loose = false;
  final Set<String> _ids = {};

  bool get _valid => !_audio || _all || _ids.isNotEmpty || _loose;

  Widget _option(bool selected, String title, String? sub, VoidCallback onTap,
      {double indent = 0}) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.only(left: indent),
      leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? Theme.of(context).colorScheme.primary : null),
      title: Text(title),
      subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 12)),
      onTap: onTap,
    );
  }

  Widget _check(bool value, String title, String sub, ValueChanged<bool> on) {
    return CheckboxListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 24),
      controlAffinity: ListTileControlAffinity.leading,
      value: value,
      onChanged: (v) => on(v ?? false),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final hasChoice = w.rows.isNotEmpty || w.looseSongs > 0;
    return AlertDialog(
      title: const Text('Back up'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _option(
                  !_audio,
                  'Song list only',
                  'Small file. Songs can be downloaded again after a restore.',
                  () => setState(() => _audio = false)),
              _option(
                  _audio,
                  'Song list + audio files',
                  'The music files (mp3 / m4a) in one .zip. This can be big and needs the same amount of free space for a moment.',
                  () => setState(() => _audio = true)),
              if (_audio) ...[
                const Divider(),
                _option(
                    _all,
                    'All songs',
                    '${_songsText(w.totalSongs)} · ${_fmtBytes(w.totalBytes)}',
                    () => setState(() => _all = true),
                    indent: 12),
                if (hasChoice)
                  _option(
                      !_all,
                      'Only some playlists',
                      'Tick the playlists to include',
                      () => setState(() => _all = false),
                      indent: 12),
                if (!_all) ...[
                  for (final r in w.rows)
                    _check(
                        _ids.contains(r.id),
                        r.name,
                        '${_songsText(r.songs)} · ${_fmtBytes(r.bytes)}',
                        (v) => setState(() {
                              if (v) {
                                _ids.add(r.id);
                              } else {
                                _ids.remove(r.id);
                              }
                            })),
                  if (w.looseSongs > 0)
                    _check(
                        _loose,
                        'Songs not in a playlist',
                        '${_songsText(w.looseSongs)} · ${_fmtBytes(w.looseBytes)}',
                        (v) => setState(() => _loose = v)),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _valid
              ? () => Navigator.pop(
                  context,
                  _BackupChoice(
                      audio: _audio,
                      all: _all,
                      folderIds: Set.of(_ids),
                      loose: _loose))
              : null,
          child: const Text('Back up'),
        ),
      ],
    );
  }
}

class _FailedSong {
  final PendingSong song;
  final String reason;
  const _FailedSong(this.song, this.reason);
}
