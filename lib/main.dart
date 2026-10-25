import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt_explode;

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

/// Shuffle and repeat for songs played from the phone, plus the sleep timer.
/// One shared object, so the full-screen player and the audio handler both
/// see the same state.
class PlayerOptions extends ChangeNotifier {
  bool shuffle = false;
  int repeat = 1; // 0 = off, 1 = repeat all (the queue loops), 2 = repeat one

  /// Set by the page: re-orders the queue when shuffle is switched.
  VoidCallback? onShuffleChanged;

  Timer? _sleepTimer;
  DateTime? sleepAt; // when the timer pauses the music
  bool sleepAtSongEnd = false; // pause when the current song ends
  String? armedSong; // website song that was playing when that was set

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

  /// True (and the timer is cleared) if the music should stop at the end of
  /// this song.
  bool consumeSleepAtEnd() {
    if (!sleepAtSongEnd) return false;
    cancelSleep();
    return true;
  }
}

final PlayerOptions playerOpts = PlayerOptions();

/// The most the volume booster can add, in dB.
const double kMaxBoostDb = 12;

/// Centre frequencies (Hz) of the 10 sliders on the Personalize sound page.
const List<double> kEqFreqs = [
  32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
];

/// One equaliser setting: a gain in dB for each of the 10 frequencies.
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

/// A ready-made mix of the four sound-effect sliders.
class FxPreset {
  final String id, name;
  final double wide, bass, clarity, room;
  const FxPreset(this.id, this.name, this.wide, this.bass, this.clarity, this.room);
}

/// The equaliser on / off, the sliders, the chosen profile and the profiles
/// the person made. One shared object: the page edits it, the audio handler
/// applies it to the player.
class EqSettings extends ChangeNotifier {
  bool enabled = false;
  String selectedId = 'flat';
  List<double> gains = List<double>.filled(kEqFreqs.length, 0);
  List<EqProfile> custom = [];
  // Volume booster in dB (0 = off), separate from the equaliser switch.
  double boostDb = 0;
  // Sound effects (0..1 each): stereo width / virtual surround, bass
  // enhancer, clarity (treble + presence), room (reverb).
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

  // Gains at: 32  64  125  250  500  1k  2k  4k  8k  16k
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

  // The sliders no longer match the chosen profile.
  bool get modified {
    final p = selected;
    if (p == null) return true;
    for (var i = 0; i < gains.length; i++) {
      if ((p.gains[i] - gains[i]).abs() > 0.01) return true;
    }
    return false;
  }

  /// Gain for any frequency: straight lines between the sliders on a
  /// logarithmic frequency scale. Used to fit the 10 sliders onto however many
  /// bands the phone's own equaliser has.
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
    // Sliders move often: send to the player a moment after the last change.
    _applyTimer?.cancel();
    _applyTimer =
        Timer(const Duration(milliseconds: 80), () => audioHandler.applyEq());
  }

  /// Redraws the page (e.g. after the player accepted or refused the settings).
  void refresh() => notifyListeners();

  void setEnabled(bool on) {
    enabled = on;
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

  /// One of the four effect sliders moved: the preset becomes "custom".
  void setFx({double? wide, double? bass, double? clarity, double? room}) {
    if (wide != null) fxWide = wide;
    if (bass != null) fxBass = bass;
    if (clarity != null) fxClarity = clarity;
    if (room != null) fxRoom = room;
    fxId = fxOn ? 'custom' : 'off';
    _changed();
  }

  /// Extra dB the clarity slider adds at a frequency (for downloaded songs,
  /// where it is done with the phone's own equaliser).
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

  // Saves the sliders into the chosen profile (only your own profiles).
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

/// Shows what the web page is playing in the Android notification / lock screen,
/// and forwards the notification buttons back to the page.
class WebAudioHandler extends BaseAudioHandler {
  /// Set by the page: runs JavaScript inside the webview.
  Future<void> Function(String js)? runJs;
  String _lastKey = '';

  Future<void> _js(String code) async => runJs?.call(code);

  // ---- Local (on-device) playback ------------------------------------------
  // The phone's own equaliser (Android) sits in the player's audio chain.
  final AndroidEqualizer equalizer = AndroidEqualizer();
  // The volume booster: makes the whole song louder than the volume buttons.
  final AndroidLoudnessEnhancer loudness = AndroidLoudnessEnhancer();
  late final AudioPlayer _player = AudioPlayer(
      audioPipeline:
          AudioPipeline(androidAudioEffects: [equalizer, loudness]));
  bool eqReady = false; // a file was loaded, so the effects exist
  bool? eqWorks; // null = not tried, false = this phone refused it
  bool? boostWorks;
  static const MethodChannel _fx = MethodChannel('ytmusicweb/fx');
  Map<String, dynamic> fxNative = {};
  /// What the effects script inside the website says about itself.
  String webEqStatus = '';
  bool _local = false;

  /// Set by the page: next / previous song in the on-device list.
  Future<void> Function()? localNext, localPrev;

  /// Set by the page: an on-device song ended by itself (shuffle / repeat
  /// decide what comes next). Falls back to localNext.
  Future<void> Function()? localEnded;

  bool get isLocal => _local;

  /// "title|artist" of the website song that was reported last.
  String webSongKey = '';

  /// Set by the page: called when on-device playback stops.
  VoidCallback? localStopped;

  WebAudioHandler() {
    _player.playbackEventStream.listen((_) {
      if (_local) _broadcastLocal();
    }, onError: (_) {});
    _player.processingStateStream.listen((s) {
      if (!_local || s != ProcessingState.completed) return;
      if (playerOpts.consumeSleepAtEnd()) {
        // Sleep timer: stop after this song.
        _player.pause();
        return;
      }
      (localEnded ?? localNext)?.call();
    });
  }

  // Personalize sound for songs streaming from the website: the site's own
  // <video> is routed through a Web Audio chain (10 filters + booster + a
  // limiter). It is only built the first time the equaliser or the booster is
  // switched on, so people who never use it keep the site's untouched audio.
  static const webEqJs = r'''
(function () {
  if (window.__webEq) return;
  var FREQS = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  var ctx = null, filters = [], failed = false;
  var bassF, clarF, presF, side, wet, boost, limiter;
  var lastStatus = '';
  var hookError = '';
  function report(extra) {
    var st;
    if (failed) st = 'unsupported';
    else if (!ctx) st = wanted() ? 'starting' : 'idle';
    else if (hookError) st = 'hook-failed: ' + hookError;
    else st = ctx.state;
    var v = document.querySelector('video, audio');
    st += v ? (v.__eqHooked ? ' | video hooked' : ' | video not hooked yet') : ' | no video';
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
  function wanted() {
    var c = cfg(), f = c.fx || {};
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
      ctx = new AC();
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
      return true;
    } catch (e) { failed = true; ctx = null; hookError = String(e && e.message || e); return false; }
  }
  function hook() {
    var v = document.querySelector('video, audio');
    if (!v || v.__eqHooked || !ensureChain()) return;
    try {
      var src = ctx.createMediaElementSource(v);
      src.connect(filters[0]);
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
    resumeCtx();
    report();
  }
  setInterval(function () {
    if (!ctx) { if (wanted()) apply(); report(); return; }
    hook();
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
  window.__webEq = { apply: apply };
  apply();
})();
''';


  /// Sends the current Personalize sound settings to the website's player.
  void pushWebEq() {
    final code = 'window.__webEqCfg=${jsonEncode({
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

  /// Plays a file from the phone and shows it in the notification / lock screen.
  Future<void> playLocal({
    required String path,
    required String title,
    String? artist,
    String? artPath,
    Duration? startAt, // begin here instead of at 0:00
  }) async {
    await _js(_pauseWebJs); // stop the website's player first
    _local = true;
    _lastKey = '';
    final item = MediaItem(
      id: path,
      title: title,
      artist: (artist == null || artist.isEmpty) ? null : artist,
      artUri: artPath == null ? null : Uri.file(artPath),
    );
    mediaItem.add(item);
    final d = await _player.setFilePath(path);
    eqReady = true;
    // Before the song starts, so it never plays flat for a moment first.
    await applyEq().timeout(const Duration(seconds: 2), onTimeout: () {});
    mediaItem.add(item.copyWith(duration: d));
    if (startAt != null &&
        startAt > Duration.zero &&
        (d == null || startAt < d)) {
      await _player.seek(startAt);
    }
    _player.play(); // not awaited: it only finishes when the song ends
  }

  /// Sends the Personalize sound settings to the player's equaliser. The
  /// sliders (10 points) are fitted onto the phone's own bands.
  Future<void> applyEq() async {
    pushWebEq(); // songs streaming from the website
    if (!eqReady) return;
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
    // Its own try: a phone without an equaliser may still have the booster.
    try {
      await loudness.setEnabled(eqState.boostDb > 0);
      if (eqState.boostDb > 0) await loudness.setTargetGain(eqState.boostDb);
      boostWorks = true;
    } catch (_) {
      boostWorks = false;
    }
    // Width, bass enhancer and room use the phone's own audio effects.
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
    await _player.stop();
    // Nothing is playing any more: clear it so the mini player hides.
    mediaItem.add(null);
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    localStopped?.call();
  }

  /// Stops the on-device player WITHOUT clearing the notification, because
  /// the website is about to take over (e.g. to play the next online song).
  Future<void> releaseLocal() async {
    if (!_local) return;
    _local = false;
    _lastKey = '';
    await _player.stop();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  void _broadcastLocal() {
    final playing = _player.playing;
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
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    ));
  }

  // ---- Buttons (notification / lock screen) --------------------------------
  @override
  Future<void> play() => _local
      ? _player.play()
      : _js("var v=document.querySelector('video');if(v){v.play();}");

  @override
  Future<void> pause() => _local ? _player.pause() : _js(_pauseWebJs);

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
      ? _player.seek(position)
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

  /// Called with what the page reports every second or so.
  void onWebState(Map<String, dynamic> d) {
    if (_local) {
      // An on-device song is playing: ignore the website, unless the person
      // started a song there, then hand playback back to the website.
      if (d['playing'] != true) return;
      _local = false;
      _player.stop();
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
      // Sleep timer "end of song": the website moved on to the next song.
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
  bool _playerOpen = false; // full-screen player page is showing

  // What the page last reported as playing, and the saved list.
  Map<String, dynamic> _now = {};
  String _nowVid = '';
  List<SavedSong> _saved = [];

  // Songs copied onto the phone (played with just_audio).
  List<LocalSong> _localSongs = [];
  int _localIdx = -1; // which one is playing, -1 = none
  List<LocalSong>? _queue; // the folder being played (Next / Previous follow it)
  List<LocalSong>? _queueOrig; // the same folder in its own order (no shuffle)

  // Playlist folders in the Download tab. Every song is also in "Download".
  List<PlaylistFolder> _playlists = [];
  // Bumped whenever songs / folders / the playing song change, so an open
  // folder page redraws.
  final ValueNotifier<int> _libTick = ValueNotifier<int>(0);
  void _touch() => _libTick.value++;

  bool _downloading = false; // a song download is running
  double? _dlProgress; // 0..1 while downloading, null = unknown
  // Progress + log shown in Download tab -> Downloading.
  final DownloadManager _dl = DownloadManager();

  // yt-dlp runs natively inside the app (see YtDlpBridge.kt).
  static const MethodChannel _ytdlp = MethodChannel('ytmusicweb/ytdlp');
  DownloadTask? _activeTask;
  String? _playlistUrl; // set while a YouTube Music playlist page is open
  String? _activeId; // yt-dlp process id of the running download
  bool _batchCancel = false; // Stop pressed while the download list runs
  // The download list: songs wait in _dl.pending (saved to the phone, so it
  // carries on after the app is closed). One worker takes them one by one.
  bool _queueRunning = false;
  bool _readingPlaylist = false; // a playlist link is being read
  PendingSong? _activeSong; // the song being downloaded right now
  bool _skipCurrent = false; // cancel only the song that is downloading now
  DateTime _lastNative = DateTime.now();
  int _lastLogStep = -1;
  bool _ytdlpChecked = false; // yt-dlp update check done this session

  // ---- Play the downloaded copy instead of streaming a song ----------------
  String? _shadowVid; // online song whose downloaded copy is playing instead
  // The website song that was paused for a downloaded copy. While this is
  // set, the website's queue is waiting and carries on after the file(s).
  String? _resumeVid;
  bool _wantWebPlay = false; // we pressed Next on the site and wait for it
  bool _offlineBusy = false;
  // Setting: when a song that is also downloaded starts streaming, play the
  // downloaded copy instead. On by default.
  bool _preferOffline = true;
  // How songs are ordered in the Download folder and playlist folders:
  // 0 newest first (default), 1 oldest first, 2 title A-Z, 3 artist A-Z.
  int _sortMode = 0;
  final Map<String, int> _addedCache = {};
  // When each downloaded song (by file path) was last played, in ms. Used by
  // the Storage page to find songs nobody listens to any more.
  Map<String, int> _lastPlayed = {};
  // Setting: only download on Wi-Fi (downloads wait on mobile data).
  bool _wifiOnly = false;
  // Setting: MP3 quality of new downloads: 'high' (best), 'medium', 'small'.
  String _quality = 'high';
  // Auto-retry: tries used per song (video id), and the file name to reuse so
  // yt-dlp carries on from the half-downloaded file instead of starting over.
  final Map<String, int> _retries = {};
  final Map<String, String> _resumeIds = {};
  String? _lastAttemptId;
  DateTime _shadowStarted = DateTime.fromMillisecondsSinceEpoch(0);
  // Downloaded files are named "<time>_<videoId>.mp3".
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
    _syncLocalVids(); // the setting may be off: stop swapping to files
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
    _syncLocalVids(); // tells the website which songs it may swap
    _touch(); // redraws the open Settings page
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

  // yt-dlp --audio-quality value: 0 = best (variable, ~245 kbps).
  String get _qualityArg =>
      _quality == 'small' ? '128K' : (_quality == 'medium' ? '192K' : '0');

  // True when the phone is on Wi-Fi (or ethernet). If the check itself does
  // not work, answer yes so downloads are never blocked by mistake.
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
        // It waits in the download list like every other song.
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
    for (final s in raw) {
      try {
        final song = LocalSong.fromJson(jsonDecode(s) as Map<String, dynamic>);
        if (File(song.path).existsSync()) list.add(song);
      } catch (_) {}
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

  // Finds downloaded MP3s in the music folder that the song list does not know
  // (app data cleared, list damaged) and adds them back. The title / artist /
  // cover come from the tags inside the file; older files without tags fall
  // back to the saved-links list, then to the video id.
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
        if (!(lp.endsWith('.mp3') || lp.endsWith('.m4a')) ||
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
              : name.replaceAll(RegExp(r'\.(mp3|m4a)$', caseSensitive: false), '');
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

  // Lets the person pick audio files, copies them into the app's own storage,
  // and reads the title / artist / cover art from the file's tags.
  Future<void> _addMusic() async {
    // file_picker 13: pickFiles() returns a plain list (empty if cancelled).
    final files = await FilePicker.pickFiles(type: FileType.audio);
    if (files.isEmpty) return;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/music');
    await dir.create(recursive: true);
    var added = 0;
    for (final f in files) {
      try {
        final name = f.name;
        final dest =
            '${dir.path}/${DateTime.now().microsecondsSinceEpoch}_$name';
        // Copy the picked file's bytes (works without needing a file path).
        await File(dest).writeAsBytes(await f.readAsBytes());
        var title = name.contains('.')
            ? name.substring(0, name.lastIndexOf('.'))
            : name;
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
    _toast(added > 0 ? 'Added $added song(s)' : 'Could not add those files');
  }

  void _markPlayed(LocalSong s) {
    _lastPlayed[s.path] = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.getInstance()
        .then((p) => p.setString('last_played', jsonEncode(_lastPlayed)));
  }

  // Deletes many songs at once (Storage page). Same clean-up as _removeLocal,
  // but the list is saved only once at the end.
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

  // ---- yt-dlp update (Settings) ------------------------------------------------
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

  // ---- Backup and restore --------------------------------------------------------
  static const String _backupApp = 'ytmusicweb-backup';

  Map<String, dynamic> _songRef(LocalSong s) =>
      {'vid': _vidOf(s), 'title': s.title, 'artist': s.artist};

  List<Map<String, dynamic>> _maps(dynamic v) => (v is List ? v : const [])
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList();

  Future<void> _backup() async {
    try {
      final data = {
        'app': _backupApp,
        'version': 1,
        'created': DateTime.now().toIso8601String(),
        'saved': _saved.map((s) => s.toJson()).toList(),
        'library': _localSongs.map(_songRef).toList(),
        'folders': [
          for (final f in _playlists)
            {
              'id': f.id,
              'name': f.name,
              'url': f.url,
              'known': f.known.toList(),
              'songs': _localSongs
                  .where((s) => f.paths.contains(s.path))
                  .map(_songRef)
                  .toList(),
            }
        ],
      };
      final bytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent(' ').convert(data)));
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final where = await FilePicker.saveFile(
        dialogTitle: 'Save backup',
        fileName: 'ytmusic-backup-$day.json',
        bytes: bytes,
      );
      if (where == null) return; // cancelled
      _toast(
          'Backup saved: ${_songsText(_localSongs.length)}, ${_playlists.length} folder(s), ${_saved.length} saved link(s)');
    } catch (e) {
      _toast('Could not save the backup: $e');
    }
  }

  Future<void> _restore() async {
    Map<String, dynamic> data;
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty) return;
      final j = jsonDecode(utf8.decode(await files.first.readAsBytes()));
      if (j is! Map || j['app'] != _backupApp) throw const FormatException();
      data = Map<String, dynamic>.from(j);
    } catch (_) {
      _toast('That is not a backup file made by this app');
      return;
    }
    if (!mounted) return;

    final savedIn = _maps(data['saved']).map(SavedSong.fromJson).toList();
    final libraryIn = _maps(data['library']);
    final foldersIn = _maps(data['folders']);

    // Songs of the backup that are not on this phone (and can be downloaded
    // again, which needs a video id). Folder songs first, so they keep their
    // folder when the list skips duplicates.
    final missing = <PendingSong>[];
    final seen = <String>{};
    var noLink = 0;
    void check(Map<String, dynamic> m, String? folderId) {
      final vid = (m['vid'] as String?) ?? '';
      final title = (m['title'] as String?) ?? '';
      final artist = (m['artist'] as String?) ?? '';
      if (_findLocal(vid, title, artist) >= 0) return;
      if (vid.isEmpty) {
        noLink++;
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

    final when = DateTime.tryParse((data['created'] as String?) ?? '');
    final ask = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: Text(
            '${when == null ? '' : 'Made on ${when.toIso8601String().substring(0, 10)}.\n'}'
            'It has ${_songsText(libraryIn.length)}, ${foldersIn.length} folder(s) and ${savedIn.length} saved link(s).\n\n'
            '${missing.isEmpty ? 'All its songs are already on this phone.' : '${_songsText(missing.length)} are not on this phone.'}'
            '${noLink > 0 ? '\n$noLink added by hand cannot be downloaded again.' : ''}\n\n'
            'Nothing is deleted: the backup is added to what you have now.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, 0),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, 1),
              child: const Text('Restore list')),
          if (missing.isNotEmpty)
            TextButton(
                onPressed: () => Navigator.pop(c, 2),
                child: Text('Restore + download ${missing.length}')),
        ],
      ),
    );
    if (ask == null || ask == 0 || !mounted) return;

    // Saved links
    final newSaved = savedIn.where((s) => !_saved.any((x) => s.vid.isNotEmpty
        ? x.vid == s.vid
        : (x.title == s.title && x.artist == s.artist))).toList();
    _saved = [..._saved, ...newSaved];

    // Folders: merged into an existing one (same id or link) or created.
    var created = 0;
    final idMap = <String, String>{}; // id in the backup -> id of the folder here
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
    // A queued song goes to the folder as it is named here (it may have been
    // matched to an existing folder under a different id).
    final fixed = [
      for (final m in missing)
        PendingSong(m.vid, m.title, m.artist,
            m.folderId == null ? null : idMap[m.folderId])
    ];

    await _persistSaved();
    await _persistPlaylists();
    if (mounted) setState(() {});
    var queued = 0;
    if (ask == 2) queued = _enqueue(fixed);
    _toast('Restored: ${newSaved.length} saved link(s), $created new folder(s)'
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
    } catch (_) {
      _toast('Could not play this file');
      return false;
    }
  }

  // The person picked a song in a folder: that folder becomes the play queue
  // and the website's queue is dropped.
  Future<bool> _playQueue(List<LocalSong> queue, int pos) {
    if (pos < 0 || pos >= queue.length) return Future.value(false);
    _shadowVid = null;
    _resumeVid = null;
    final first = queue[pos];
    _queueOrig = List.of(queue);
    _queue = playerOpts.shuffle ? _shuffledFirst(queue, first) : List.of(queue);
    return _playLocal(_localSongs.indexOf(first));
  }

  // The folder's Shuffle button: switch shuffle on and start with a random song.
  Future<bool> _shuffleQueue(List<LocalSong> list) {
    if (list.isEmpty) return Future.value(false);
    playerOpts.setShuffle(true, apply: false);
    final pick = (List.of(list)..shuffle()).first;
    return _playQueue(list, list.indexOf(pick));
  }

  // `first` stays on top, everything else is mixed.
  List<LocalSong> _shuffledFirst(List<LocalSong> q, LocalSong? first) {
    final rest = q.where((x) => !identical(x, first)).toList()..shuffle();
    return [if (first != null && q.contains(first)) first, ...rest];
  }

  // Shuffle switched on / off while a folder is playing.
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

  // An on-device song ended by itself. Repeat one plays it again; repeat off
  // stops after the last song; otherwise the next song (the list loops).
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

  // Next / previous song inside the folder being played (or all songs).
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

  // By video id first, then by title + artist (songs added by hand).
  int _findLocal(String vid, String title, String artist) {
    final i = _localIndexByVid(vid);
    if (i >= 0) return i;
    if (title.isEmpty) return -1;
    return _localSongs
        .indexWhere((s) => s.title == title && s.artist == artist);
  }

  // Tells the website which songs are on the phone, so it can stop streaming
  // them the moment they start (see _shadowJs).
  void _syncLocalVids() {
    // Empty list = the website never swaps a streamed song for its file.
    final vids = _preferOffline
        ? _localSongs.map(_vidOf).where((v) => v.isNotEmpty).toList()
        : <String>[];
    // Title + artist of every song that has both: lets the website also swap
    // a different upload of the same song (audio / video / re-upload).
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

  // Plays the downloaded copy while the website's copy stays paused.
  Future<void> _startShadow(int i, String vid,
      {Duration? start}) async {
    _shadowVid = vid;
    _resumeVid = vid;
    if (i >= 0 && i < _localSongs.length) _queue = _queueFor(_localSongs[i]);
    _shadowStarted = DateTime.now();
    final ok = await _playLocal(i, start: start);
    if (!ok && _shadowVid == vid) {
      // The file would not play: let the website play this song after all.
      _shadowVid = null;
      _resumeVid = null;
      if (mounted) setState(() {});
      _controller
          .runJavaScript('window.__allowWeb=${jsonEncode(vid)};'
              "var v=document.querySelector('video');if(v){v.play();}")
          .catchError((_) {});
    }
  }

  // The website just started a song that is downloaded (message from _shadowJs).
  void _onShadowPlay(String message) {
    var vid = '', lt = '', la = '';
    try {
      final m = jsonDecode(message) as Map;
      vid = (m['vid'] as String?) ?? '';
      lt = (m['lt'] as String?) ?? ''; // set when matched by title + artist
      la = (m['la'] as String?) ?? '';
    } catch (_) {}
    if (vid.isEmpty) return;
    if (_shadowVid == vid) {
      // The person pressed play on the website's own player while the
      // downloaded copy is the one making the sound: use it as play / pause.
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
      // The page already paused the song for a file we cannot find: let it play.
      _controller
          .runJavaScript('window.__allowWeb=${jsonEncode(vid)};'
              "var v=document.querySelector('video');if(v){v.play();}")
          .catchError((_) {});
    }
  }

  // Looks at what the website reports. Returns false when the report should
  // not reach the notification (a downloaded copy is standing in).
  bool _onWebReport(Map<String, dynamic> d) {
    final playing = d['playing'] == true;
    if (playing) _wantWebPlay = false;
    final vid = _reportVid(d);

    if (_shadowVid != null) {
      if (vid == _shadowVid || !playing) return false; // site stays quiet
      // The website is playing another song now: it takes over again.
      _shadowVid = null;
      _resumeVid = null;
      return true;
    }

    // Phone went offline (or the song is stuck) while streaming: use the file.
    final offline = d['online'] == false || d['stalled'] == true;
    if (playing && offline) _maybeGoOffline(d, vid);
    return true;
  }

  Future<void> _maybeGoOffline(Map<String, dynamic> d, String vid) async {
    if (_offlineBusy) return;
    _offlineBusy = true;
    try {
      // "offline" from the page is trusted; a stuck song gets a real check.
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

  // A downloaded song ended (or Next / Previous was pressed) while the
  // website's queue is waiting. With internet: go on with the website's queue.
  // Without: play the next downloaded song and keep the queue waiting, so it
  // carries on once the internet is back.
  Future<void> _webStep(bool next) async {
    final old = _resumeVid;
    if (!await _online()) {
      _shadowVid = null; // _resumeVid stays: the website's queue still waits
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
    // The site sometimes stays paused after the click: start it.
    for (final ms in [800, 2000, 4000]) {
      await Future.delayed(Duration(milliseconds: ms));
      if (!_wantWebPlay || !mounted) return;
      if (_reportVid(_now) == old) continue; // it did not move on
      _controller.runJavaScript(_resumeJs).catchError((_) {});
    }
    _wantWebPlay = false;
  }

  Future<void> _shadowPrev() async {
    if (audioHandler.playbackState.value.position >
        const Duration(seconds: 3)) {
      await audioHandler.seek(Duration.zero); // like other players: restart
    } else {
      await _webStep(false);
    }
  }

  // Messages from the native side (YtDlpBridge.kt): progress and yt-dlp output.
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
    // Progress lines repeat constantly ("[download]  12.3% of ..."), skip them.
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

  // The player-page download button: adds the song that is playing to the
  // download list (it starts at once when nothing else is downloading).
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

  // Downloaded files are named "<time>_<videoId>.mp3", so the id tells us.
  // True when the song that is playing is already downloaded (the player
  // page's download button then shows a "done" icon).
  bool get _nowDownloaded {
    final title = ((_now['title'] as String?) ?? '').trim();
    if (title.isEmpty) return false;
    return _alreadyHave(
        _nowVid, title, ((_now['artist'] as String?) ?? '').trim());
  }

  // The song that is playing is being downloaded now / waits in the list.
  bool get _nowActive => _nowVid.isNotEmpty && _activeSong?.vid == _nowVid;
  bool get _nowWaiting =>
      _nowVid.isNotEmpty && _dl.pending.any((p) => p.vid == _nowVid);

  bool _alreadyHave(String vid, String title, String artist) =>
      _localSongs.any((s) =>
          (vid.isNotEmpty && s.path.contains('_$vid.')) ||
          (s.title == title && s.artist == artist));

  // Downloads ONE song with yt-dlp (inside the app) and adds it to
  // "On this device". Used by the player button and by "Add playlist".
  // The caller sets _downloading. Returns the task (status done or failed).
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
      _dl.log(_ytdlpChecked
          ? 'Starting yt-dlp...'
          : 'Starting yt-dlp (the first run unpacks it and checks for an update, this can take a minute)...');

      // Says so in the log if yt-dlp has been quiet for a while.
      watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
        final idle = DateTime.now().difference(_lastNative).inSeconds;
        if (idle >= 10) _dl.log('No output for ${idle}s, still working...');
      });

      // iPhone cannot run yt-dlp, so the audio is fetched in Dart instead.
      outPath = Platform.isIOS
          ? await _downloadWithDart(vid, id, dir, task)
          : await _ytdlp.invokeMethod<String>('download', {
        'url': 'https://music.youtube.com/watch?v=$vid',
        'dir': dir.path,
        'id': id,
        'update': !_ytdlpChecked,
        'quality': _qualityArg,
      }).timeout(const Duration(minutes: 10), onTimeout: () {
        _ytdlp.invokeMethod('cancel', {'id': id});
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

      // keep the cover image for the lock screen / notification
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

  // iPhone download: asks YouTube for the audio-only stream (AAC / .m4a, which
  // the iPhone can play) and saves it. No yt-dlp and no ffmpeg needed.
  Future<String> _downloadWithDart(
      String vid, String id, Directory dir, DownloadTask task) async {
    final yt = yt_explode.YoutubeExplode();
    try {
      _dl.log('Asking YouTube for the audio streams...');
      final manifest = await yt.videos.streamsClient
          .getManifest(vid)
          .timeout(const Duration(seconds: 60));
      final aac = manifest.audioOnly
          .where((s) => s.container == yt_explode.StreamContainer.mp4)
          .toList()
        ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
      if (aac.isEmpty) {
        throw Exception('YouTube gave no audio stream the iPhone can play');
      }
      final info = _quality == 'small'
          ? aac.first
          : (_quality == 'medium' ? aac[aac.length ~/ 2] : aac.last);
      final total = info.size.totalBytes;
      _dl.log(
          'Downloading ${(info.bitrate.kiloBitsPerSecond).round()} kbps AAC (${(total / 1048576).toStringAsFixed(1)} MB)');
      task.status = DlStatus.downloading;
      task.total = total;
      _dl.changed();

      final out = File('${dir.path}/$id.m4a');
      final sink = out.openWrite();
      var got = 0, step = -1;
      final clock = Stopwatch()..start();
      try {
        await for (final chunk in yt.videos.streamsClient.get(info)) {
          sink.add(chunk);
          got += chunk.length;
          task.received = got;
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
      } finally {
        await sink.close();
      }
      return out.path;
    } finally {
      yt.close();
    }
  }

  String _errText(Object e) =>
      e is PlatformException ? (e.message ?? e.code) : e.toString();

  // ---- Playlist folders ------------------------------------------------------
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

  // A song belongs to a folder by its file, or by its video id.
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

  // Puts every song of the playlist that is already on the phone into the
  // folder. Songs the person deleted stay in "known", so Update leaves them.
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
    _touch(); // redraws the open folder
  }

  // When a song was added: files are named "<microseconds>_...", so the name
  // tells (works for downloads and added files). Otherwise the file's date.
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

  // Asks yt-dlp for the list of songs in a playlist / channel page link.
  Future<_PlaylistData> _readPlaylist(String url) async {
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

  // ---- The download list --------------------------------------------------
  // Everything that waits to be downloaded (playlist songs, the player button,
  // smart download) goes through here. The list is saved on the phone after
  // every change, so it carries on after the app was closed.

  Future<void> _persistQueue() async {
    final items = <PendingSong>[
      if (_activeSong != null && !_batchCancel) _activeSong!,
      ..._dl.pending,
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'dl_queue', items.map((p) => jsonEncode(p.toJson())).toList());
  }

  // The list was changed from a page (remove / reorder): save it, and clear the
  // "paused" bar when nothing is left to resume.
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

  // Cancels the song that is downloading now; the list goes on with the next.
  void _cancelCurrent() {
    final s = _activeSong;
    if (s == null) return;
    _skipCurrent = true;
    _dl.log('Cancelling "${s.title}"...');
    final id = _activeId;
    if (id != null) _ytdlp.invokeMethod('cancel', {'id': id});
  }

  // Adds songs to the end of the list and starts the worker if it is idle.
  // Songs already downloaded, downloading or waiting are skipped.
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

  // At start: deletes half-finished download files, then puts back the songs
  // that were waiting (or downloading) when the app was closed.
  Future<void> _loadQueue() async {
    await _cleanLeftovers();
    final prefs = await SharedPreferences.getInstance();
    final back = <PendingSong>[];
    for (final raw in prefs.getStringList('dl_queue') ?? <String>[]) {
      try {
        final p = PendingSong.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (p.vid.isEmpty) continue;
        if (_alreadyHave(p.vid, p.title, p.artist)) {
          _linkToFolder(p); // it did finish before the app closed
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

  // Interrupted downloads leave temporary files behind: remove them.
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

  // Puts a finished song into its playlist folder.
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

  // The one worker: takes the first waiting song, downloads it, repeats.
  Future<void> _pumpQueue() async {
    if (_queueRunning || !mounted || _dl.pending.isEmpty) return;
    _queueRunning = true;
    _batchCancel = false;
    _dl.onResume = null;
    _dl.onStopBatch = _confirmStop;
    _dl.onCancelCurrent = _cancelCurrent;
    var saved = 0, failed = 0, strikes = 0, n = 0;
    var pausedReason = '';
    var waitKind = '';
    var outdatedHint = false;
    try {
      while (mounted && _dl.pending.isNotEmpty && !_batchCancel) {
        // Wi-Fi only: wait here (also after the app restarts) and carry on by
        // itself as soon as Wi-Fi is back.
        // Same when there is no internet at all: wait, then carry on.
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
          // Cancelled by the person: not a failure, go on with the next song.
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
            // The connection dropped during the song: put it back and wait
            // for it to return, instead of counting a failure. The partly
            // downloaded file is kept, so it carries on from there.
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
            // A connection problem while online: try again a bit later.
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
          if (_looksOutdated(err) && !outdatedHint) {
            outdatedHint = true;
            _dl.log(
                'This looks like YouTube changed something. Try Settings > Check for yt-dlp update.',
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
        // pause between songs (also lets Stop react quickly)
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
        _toast(
            'Downloads may be failing because YouTube changed. Try Settings > Check for yt-dlp update.');
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
    }
  }

  static const List<int> _retryDelays = [5, 15, 30];

  // Errors that usually mean YouTube changed something and yt-dlp is too old.
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

  // Does the yt-dlp error look like a dropped / bad connection (worth trying
  // again), rather than a video problem or YouTube refusing us?
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

  // Deletes the half-finished files of a download that is given up.
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
    if (id != null) _ytdlp.invokeMethod('cancel', {'id': id});
    if (!_queueRunning) {
      // paused: nothing is running that could clean up
      _batchCancel = false;
      _dl.batchStatus = null;
      _dl.onStopBatch = null;
      _dl.onResume = null;
    }
    _persistQueue();
    _dl.changed();
  }

  // Download tab -> Add playlist: lists the songs, asks, then downloads them
  // one at a time with a pause in between (to stay clear of YouTube's limits).
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

  // Reads the playlist, asks for confirmation, then downloads the songs one by
  // one. Used by the Add playlist button and the button on playlist pages.
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
    // Every song of the playlist that is not on this device is offered, also
    // the ones the person deleted earlier. The person picks which to download.
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
      // Nothing to download: still make / refresh the folder from the songs
      // that are already here.
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
    // Add playlist and Update both ask which songs to download.
    final picks = await showDialog<List<Map<String, String>>>(
      context: context,
      builder: (ctx) => _SongPickDialog(
        playlistName: target?.name ?? pl.title,
        total: songs.length,
        songs: todo,
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
    // The songs join the download list (also while something else downloads).
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
    task.finishedAt = DateTime.now();
    _dl.log('FAILED: $message', error: true);
    if (mounted && toast) {
      _toast('Download failed. See Download tab > Downloading for details.');
    }
  }

  // The bookmark button: only saves the current song's link to the list.
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
    final files = await FilePicker.pickFiles(type: FileType.audio);
    if (files.isEmpty) return;
    _uploadBusy = true;
    try {
      final f = files.first;
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/music');
      await dir.create(recursive: true);
      final tag = s.vid.length == 11 ? s.vid : 'saved';
      final dest =
          '${dir.path}/${DateTime.now().microsecondsSinceEpoch}_$tag.${_extOf(f.name)}';
      await File(dest).writeAsBytes(await f.readAsBytes());
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
    final files = await FilePicker.pickFiles(type: FileType.audio);
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

  // Opens a saved song in the site (streams it, needs internet).
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

  // Best-effort ad handling: hides promo banners, clicks "Skip", and fast-forwards
  // and mutes an ad that is playing. YouTube changes its page often, so the
  // selectors below may need adjusting over time.
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


  // Background playback: the site pauses itself when it thinks the page is hidden.
  // This makes the page always report "visible" and ignores visibility/blur events.
  // Best effort: the site may change how it checks, and this may stop working.
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

  // Downloaded songs: the moment the website starts one of them, its own copy
  // is paused and the app is told, so the app can play the file instead.
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

  // Reports the current song to the app (title, artist, artwork, position).
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

  // Tells the app when the full-screen player page is open or closed.
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

  // Reports the page address whenever it changes (the site never reloads the page).
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

  // true if a video/audio element is currently playing
  static const _isPlayingJs =
      "(function(){var v=document.querySelector('video');return !!(v && !v.paused && !v.ended);})()";
  // resume playback if something paused it when the app was left
  static const _resumeJs =
      "(function(){var v=document.querySelector('video');if(v && v.paused && !v.ended){v.play();}})()";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSaved();
    // iPhone: let the page play inline and start music without a tap
    // (otherwise the website's player stays silent).
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
            // Redraw the download button when the song changes to / from a
            // downloaded one.
            if (mounted && wasDownloaded != _nowDownloaded) setState(() {});
            _trackPlay(data);
            // Not passed on while a downloaded copy is standing in for it.
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
        // A playlist page looks like music.youtube.com/playlist?list=...
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
        onPageStarted: (_) => _controller.runJavaScript(_keepAliveJs),
        onPageFinished: (_) {
          _controller.runJavaScript(_keepAliveJs);
          _controller.runJavaScript(_adBlockJs);
          _controller.runJavaScript(WebAudioHandler.webEqJs);
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
      // A Safari-like identity, so Google sign-in accepts the page.
      _controller.setUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1');
    }
    audioHandler.runJs = (js) => _controller.runJavaScript(js);
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
    _loadLocal().then((_) => _loadQueue()); // songs first, then pick up the list
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
      // Remember whether music was playing just before the app is left.
      try {
        final r = await _controller.runJavaScriptReturningResult(_isPlayingJs);
        _wasPlaying = r.toString() == 'true';
      } catch (_) {}
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // If the page paused itself on the way out, start it again.
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

  // Tabs 3 (Download) and 4 (Sound) are pages of the app, not the website.
  bool get _appTab => _tab >= 3;

  // Tabs: 0 Home, 1 Search (explore page), 2 Library, 3 Download (app page),
  // 4 Personalize sound (app page).
  static const _labels = ['Home', 'Explore', 'Library'];

  // Presses the matching button of the site's own left sidebar (Home / Explore /
  // Library). This never reloads the page, so music keeps playing and there is
  // no "leave page" prompt.
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

  // Bottom of the screen: the mini player (when it has something to show)
  // on top of the Home / Search / Library / Download buttons.
  Widget? _bottomBar() {
    // The nav buttons are hidden while the website's full-screen player is open.
    final hideNav = _playerOpen && !_appTab;
    final offline = _shadowVid != null; // a downloaded copy stands in
    final onDevice = _localIdx >= 0; // a file from this phone is playing
    // Download tab: always (it hides itself when nothing plays). Other tabs:
    // only while a file from this phone is playing, since the website has its
    // own mini player for online songs.
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
              // "Download playlist" button, shown on YouTube Music playlist pages.
              if (_playlistUrl != null && !_playerOpen && !_appTab)
                Positioned(
                  right: 12,
                  bottom: 84, // above the site's mini player
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
              // Download + bookmark buttons, shown on the full-screen player page.
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

/// One download, with everything the Downloading screen shows about it.
class DownloadTask {
  final int id;
  final String title, artist;
  final String? folderId;
  DlStatus status = DlStatus.preparing;
  int received = 0, total = 0;
  double speedKBs = 0;
  double? pct; // 0..100 from yt-dlp
  int? etaSec;
  String? error;
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

/// Lists the songs of a playlist that are not on the device yet; the person
/// ticks the ones to download (or taps Select all).
class _SongPickDialog extends StatefulWidget {
  final String playlistName;
  final int total;
  final List<Map<String, String>> songs;
  final Set<String> removedBefore;

  const _SongPickDialog({
    required this.playlistName,
    required this.total,
    required this.songs,
    required this.removedBefore,
  });

  @override
  State<_SongPickDialog> createState() => _SongPickDialogState();
}

class _SongPickDialogState extends State<_SongPickDialog> {
  final Set<int> _on = {};

  bool get _all => _on.length == widget.songs.length;

  @override
  Widget build(BuildContext context) {
    final n = _on.length;
    final minutes = (n * 25 / 60).ceil();
    final onDevice = widget.total - widget.songs.length;
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
        height: h * 0.55,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        '${widget.songs.length} songs to choose from'
                        '${onDevice > 0 ? ' ($onDevice already on this device)' : ''}',
                        style: const TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (_all) {
                        _on.clear();
                      } else {
                        _on
                          ..clear()
                          ..addAll(List<int>.generate(
                              widget.songs.length, (i) => i));
                      }
                    }),
                    child: Text(_all ? 'Clear' : 'Select all'),
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
                    title: Text(song['title'] ?? '',
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        [
                          if (artist.isNotEmpty) artist,
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
  final bool smart; // added by Smart download
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

  /// Set while "Add playlist" is running (shown at the top of Downloading).
  String? batchStatus; // the download list is running / paused
  String? readingStatus; // a playlist link is being read
  VoidCallback? onStopBatch;
  VoidCallback? onResume; // set while the list is paused
  VoidCallback? onCancelCurrent; // set while a song is downloading
  VoidCallback? onQueueChanged; // saves the list to the phone
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

  /// Removes the waiting songs of one folder (null = every folder) and cancels
  /// the song downloading now if it belongs there.
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

  /// One line for the folder tile on the Download page.
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

/// The "Downloading" folder: what is downloading now, and a log of what happened.
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

    // null = animated "working..." bar (while preparing / saving)
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
                          // newest first
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
              const SizedBox(height: 12),
              _YtDlpCard(onCheck: onCheckYtDlp),
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
  final String quality; // high | medium | small
  final ValueChanged<bool> onWifiOnly;
  final ValueChanged<String> onQuality;

  const _DownloadSettingsCard({
    required this.wifiOnly,
    required this.quality,
    required this.onWifiOnly,
    required this.onQuality,
  });

  static const _hints = {
    'high': 'Best quality, biggest files: about 1.8 MB per minute of music.',
    'medium': '192 kbps: about 1.4 MB per minute. A good middle choice.',
    'small':
        '128 kbps: about 1 MB per minute. Roughly half the space of High and fine for most listening.',
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
            Text(_hints[quality] ?? '',
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
                'Saves your song list, saved links and playlist folders to a file, so a reinstall does not lose how they are organised. The music files themselves are not in the backup: after a restore, songs missing from the phone can be downloaded again.',
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

/// Settings -> Storage: how much space downloaded songs use, and a way to free
/// it. Songs are ticked first and only deleted after a confirmation.
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
  int _sort = 0; // 0 biggest first, 1 longest since played first
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

  // The later of "last played" and "added": a song never played counts from
  // the day it was added.
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

/// A song kept in the Downloads list (title, artist, thumbnail and link).
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

/// A song file copied onto the phone, with its cover image (if it had one).
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

/// What reading a playlist link gives back.
class _PlaylistData {
  final String id, title;
  final List<Map<String, String>> songs;
  _PlaylistData(this.id, this.title, this.songs);
}

/// A folder for one downloaded playlist.
class PlaylistFolder {
  String id, name, url;
  final Set<String> known; // video ids seen in the playlist at the last update
  final Set<String> paths; // song files that belong to it

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

/// The Downloads page: folders (Download = every song, plus one per playlist)
/// and the saved-links list.
class DownloadPage extends StatelessWidget {
  final List<PlaylistFolder> playlists;
  final List<LocalSong> Function(PlaylistFolder?) songsOf; // null = all songs
  final VoidCallback onAdd;
  final void Function(PlaylistFolder?) onOpenFolder; // null = Download
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

  // Cover of a folder card: a 2x2 mosaic of song covers (4 or more songs with
  // a cover), a single cover, or a grey square with an icon when empty.
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

  // One folder, drawn like a YouTube Music playlist card.
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

/// What is inside one folder: the Download folder (all songs) or a playlist
/// folder, which also has an Update button.
class FolderPage extends StatelessWidget {
  final String title;
  final Listenable refresh; // redraws the list when songs change
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
  final ValueNotifier<String> query; // the search box above the list
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

/// The search box at the top of a folder page.
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

/// The "Sound" tab: equaliser with ready-made profiles and your own.
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
                      if (audioHandler.webEqStatus.isNotEmpty &&
                          (eqState.enabled || eqState.fxOn || eqState.boostDb > 0)) ...[
                        const SizedBox(height: 8),
                        Text('Streaming effects: ${audioHandler.webEqStatus}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white38)),
                      ],
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
                                  ? 'On iPhone the equalizer works on streaming songs only. Songs added from your files are not changed yet.'
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

// ---------------------------------------------------------------------------
// Mini player (bottom of the Download page) + full-screen player
// ---------------------------------------------------------------------------

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Cover art for whatever is playing (file on the phone or a web link).
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

/// Rebuilds a few times a second with the current playback position.
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

/// Like the YouTube Music mini player: cover, title, pause and next.
/// Tapping anywhere else on it opens the full player.
class MiniPlayer extends StatelessWidget {
  /// Small line above the bar, e.g. "Playing offline version".
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
                    // thin progress line on top
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

/// The full-screen player: big cover, seek bar, previous / play-pause / next.
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

/// Shuffle, repeat and sleep timer buttons under the player controls.
/// Shuffle and repeat only apply to songs played from the phone.
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

/// Moon button: opens the sleep timer choices and shows the time left.
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

/// Slider with the current time and the song length.
class _SeekBar extends StatefulWidget {
  final Duration? duration;
  const _SeekBar({required this.duration});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag; // milliseconds while the thumb is being dragged

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
