import AVFoundation
import AudioToolbox
import Flutter

/// Plays on-device songs (downloaded / added from Files) through AVAudioEngine,
/// so "Personalize sound" works on iPhone too: 10-band equaliser, bass,
/// clarity, room (reverb), width and the volume booster (with a limiter).
///
/// just_audio cannot do this on iOS (its equaliser is Android-only).
/// Dart side: IosFxEngine in lib/main.dart, channel "ytmusicweb/fxplayer".
///
/// Every piece of state below is only touched on `queue`.
final class FxPlayer: NSObject {
  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let eq = AVAudioUnitEQ(numberOfBands: 13)
  private let reverb = AVAudioUnitReverb()
  private let limiter: AVAudioUnitEffect
  private let queue = DispatchQueue(label: "ytmusicweb.fxplayer")

  private var file: AVAudioFile?
  private var graphFormat: AVAudioFormat?
  private var generation = 0
  private var pendingChunks = 0
  private var wantPlaying = false
  private var finished = false   // the song has played to its end
  private var allQueued = false   // the whole file has been handed to the player
  private var startFrame: AVAudioFramePosition = 0
  private var pausedSeconds: Double = 0
  private var wide: Float = 0

  private let chunkFrames: Int64 = 16384  // about 0.4 s: width changes are heard quickly
  private let maxQueued = 4

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ytmusicweb/fxplayer", binaryMessenger: messenger)
    let desc = AudioComponentDescription(
      componentType: kAudioUnitType_Effect,
      componentSubType: kAudioUnitSubType_DynamicsProcessor,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0)
    limiter = AVAudioUnitEffect(audioComponentDescription: desc)
    super.init()

    configureNodes()
    engine.attach(node)
    engine.attach(eq)
    engine.attach(reverb)
    engine.attach(limiter)

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(configChanged),
                   name: .AVAudioEngineConfigurationChange, object: engine)
    nc.addObserver(self, selector: #selector(interrupted(_:)),
                   name: AVAudioSession.interruptionNotification, object: nil)
    nc.addObserver(self, selector: #selector(routeChanged(_:)),
                   name: AVAudioSession.routeChangeNotification, object: nil)
  }

  // MARK: - Effect nodes

  private func configureNodes() {
    let freqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    for (i, f) in freqs.enumerated() {
      let b = eq.bands[i]
      b.filterType = i == 0 ? .lowShelf : (i == freqs.count - 1 ? .highShelf : .parametric)
      b.frequency = f
      b.bandwidth = 1.27  // octaves (same shape as Q 1.1 in the website chain)
      b.gain = 0
      b.bypass = false
    }
    let bass = eq.bands[10]  // bass enhancer
    bass.filterType = .lowShelf
    bass.frequency = 90
    bass.bandwidth = 1.0
    bass.gain = 0
    bass.bypass = false
    let clarity = eq.bands[11]  // clarity: treble shelf ...
    clarity.filterType = .highShelf
    clarity.frequency = 5000
    clarity.bandwidth = 1.0
    clarity.gain = 0
    clarity.bypass = false
    let presence = eq.bands[12]  // ... plus a presence bump
    presence.filterType = .parametric
    presence.frequency = 3000
    presence.bandwidth = 1.4
    presence.gain = 0
    presence.bypass = false

    reverb.loadFactoryPreset(.mediumHall)
    reverb.wetDryMix = 0
    reverb.bypass = true
    limiter.bypass = true
  }

  private func configureLimiter() {
    let au = limiter.audioUnit
    _ = AudioUnitSetParameter(au, AudioUnitParameterID(kDynamicsProcessorParam_Threshold), AudioUnitScope(kAudioUnitScope_Global), 0, -3, 0)
    _ = AudioUnitSetParameter(au, AudioUnitParameterID(kDynamicsProcessorParam_HeadRoom), AudioUnitScope(kAudioUnitScope_Global), 0, 0.1, 0)
    _ = AudioUnitSetParameter(au, AudioUnitParameterID(kDynamicsProcessorParam_ExpansionRatio), AudioUnitScope(kAudioUnitScope_Global), 0, 1, 0)
    _ = AudioUnitSetParameter(au, AudioUnitParameterID(kDynamicsProcessorParam_AttackTime), AudioUnitScope(kAudioUnitScope_Global), 0, 0.003, 0)
    _ = AudioUnitSetParameter(au, AudioUnitParameterID(kDynamicsProcessorParam_ReleaseTime), AudioUnitScope(kAudioUnitScope_Global), 0, 0.1, 0)
  }

  /// Always stereo at the song's sample rate; mono files are widened to two
  /// channels while reading, so every effect sees the same format.
  private func buildGraph(sampleRate: Double) throws {
    if let g = graphFormat, g.sampleRate == sampleRate { return }
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
      throw fxError("Unsupported audio format")
    }
    if engine.isRunning { engine.stop() }
    engine.disconnectNodeOutput(node)
    engine.disconnectNodeOutput(eq)
    engine.disconnectNodeOutput(reverb)
    engine.disconnectNodeOutput(limiter)
    engine.connect(node, to: eq, format: fmt)
    engine.connect(eq, to: reverb, format: fmt)
    engine.connect(reverb, to: limiter, format: fmt)
    engine.connect(limiter, to: engine.mainMixerNode, format: fmt)
    graphFormat = fmt
    configureLimiter()
    engine.prepare()
  }

  private func ensureEngineRunning() throws {
    if engine.isRunning { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [])
    try session.setActive(true)
    try engine.start()
  }

  private func fxError(_ text: String) -> NSError {
    return NSError(domain: "FxPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }

  // MARK: - Dart calls

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    queue.async {
      do {
        switch call.method {
        case "load":
          guard let path = args["path"] as? String else { throw self.fxError("No path") }
          try self.load(path: path)
        case "play":
          try self.play()
        case "pause":
          self.pause()
        case "seek":
          let secs = (args["seconds"] as? NSNumber)?.doubleValue ?? 0
          try self.seek(seconds: secs)
        case "stop":
          self.stop()
        case "fx":
          self.applyFx(args)
        case "position":
          break
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
        let reply = self.state()
        DispatchQueue.main.async { result(reply) }
      } catch {
        let message = error.localizedDescription
        DispatchQueue.main.async {
          result(FlutterError(code: "fxplayer", message: message, details: nil))
        }
      }
    }
  }

  private func state() -> [String: Any] {
    var m: [String: Any] = ["pos": currentSeconds()]
    if let f = file { m["dur"] = Double(f.length) / f.processingFormat.sampleRate }
    return m
  }

  private func emit(_ type: String) {
    var m = state()
    m["type"] = type
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("event", arguments: m)
    }
  }

  private func load(path: String) throws {
    generation += 1
    node.stop()
    wantPlaying = false
    finished = false
    allQueued = false
    file = nil
    let url = URL(fileURLWithPath: path)
    let f: AVAudioFile
    do {
      f = try AVAudioFile(forReading: url)
    } catch {
      // YouTube's .m4a audio is often a "fragmented" MP4 that AVAudioFile
      // cannot read but AVAsset can. Rewrite it once as a normal .m4a.
      try remux(url)
      f = try AVAudioFile(forReading: url)
    }
    if f.length <= 0 { throw fxError("The file has no audio") }
    try buildGraph(sampleRate: f.processingFormat.sampleRate)
    file = f
    scheduleFrom(0)
  }

  /// Rewrites an audio file in place as a plain .m4a (no re-encoding if possible).
  private func remux(_ url: URL) throws {
    let asset = AVURLAsset(url: url)
    let tmp = url.deletingLastPathComponent()
      .appendingPathComponent(UUID().uuidString + ".fix.m4a")
    var lastError: Error?
    for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
      guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
      try? FileManager.default.removeItem(at: tmp)
      session.outputURL = tmp
      session.outputFileType = .m4a
      let done = DispatchSemaphore(value: 0)
      session.exportAsynchronously { done.signal() }
      done.wait()
      if session.status == .completed {
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        return
      }
      lastError = session.error
    }
    try? FileManager.default.removeItem(at: tmp)
    throw lastError ?? fxError("This file could not be read")
  }

  private func play() throws {
    guard let f = file else { throw fxError("Nothing loaded") }
    let sr = f.processingFormat.sampleRate
    let wasRunning = engine.isRunning
    if finished {
      scheduleFrom(0)
    } else if !wasRunning {
      // the system stopped the engine (call, route change): schedule again
      scheduleFrom(AVAudioFramePosition(pausedSeconds * sr))
    }
    try ensureEngineRunning()
    wantPlaying = true
    if !node.isPlaying { node.play() }
  }

  private func pause() {
    if node.isPlaying { pausedSeconds = currentSeconds() }
    wantPlaying = false
    node.pause()
  }

  private func seek(seconds: Double) throws {
    guard let f = file else { return }
    let sr = f.processingFormat.sampleRate
    let frame = AVAudioFramePosition(max(0, seconds) * sr)
    let resume = wantPlaying
    scheduleFrom(frame)
    if resume {
      try ensureEngineRunning()
      node.play()
    }
  }

  private func stop() {
    generation += 1
    node.stop()
    wantPlaying = false
    finished = false
    allQueued = false
    file = nil
    pausedSeconds = 0
    pendingChunks = 0
    if engine.isRunning { engine.stop() }
  }

  // MARK: - Scheduling

  /// (Re)starts feeding the player from `frame`. Callbacks of anything
  /// scheduled before are ignored through `generation`.
  private func scheduleFrom(_ frame: AVAudioFramePosition) {
    guard let f = file else { return }
    generation += 1
    node.stop()
    pendingChunks = 0
    finished = false
    allQueued = false
    startFrame = max(0, min(frame, f.length - 1))
    pausedSeconds = Double(startFrame) / f.processingFormat.sampleRate
    f.framePosition = startFrame
    refill()
  }

  /// Keeps a few short chunks queued. Width is applied here, to each chunk
  /// just before it is queued; everything else is live in the effect nodes.
  private func refill() {
    guard let f = file, let fmt = graphFormat else { return }
    let gen = generation
    while pendingChunks < maxQueued && !allQueued {
      let remaining = f.length - f.framePosition
      let want = AVAudioFrameCount(max(1, min(chunkFrames, remaining)))
      guard let readBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: want),
            let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: want)
      else { return }
      if remaining > 0 {
        do { try f.read(into: readBuf, frameCount: want) } catch { readBuf.frameLength = 0 }
      }
      let got = readBuf.frameLength
      let isLast = remaining <= Int64(want) || got < want
      let n = max(got, 1)
      outBuf.frameLength = n
      fill(outBuf, from: readBuf, frames: got)

      pendingChunks += 1
      if isLast { allQueued = true }
      let type: AVAudioPlayerNodeCompletionCallbackType = isLast ? .dataPlayedBack : .dataConsumed
      node.scheduleBuffer(outBuf, at: nil, options: [], completionCallbackType: type) { [weak self] _ in
        self?.queue.async {
          guard let self = self, gen == self.generation else { return }
          self.pendingChunks -= 1
          if isLast {
            self.handleEnded()
          } else {
            self.refill()
          }
        }
      }
    }
  }

  /// Copies into the stereo output buffer (mono is duplicated) and widens.
  private func fill(_ out: AVAudioPCMBuffer, from src: AVAudioPCMBuffer, frames: AVAudioFrameCount) {
    guard let o = out.floatChannelData else { return }
    let n = Int(out.frameLength)
    let have = Int(frames)
    let srcChannels = Int(src.format.channelCount)
    if have > 0, let s = src.floatChannelData, srcChannels > 0 {
      for ch in 0..<2 {
        let from = s[min(ch, srcChannels - 1)]
        for i in 0..<have { o[ch][i] = from[i] }
      }
    }
    if have < n {
      for ch in 0..<2 { for i in have..<n { o[ch][i] = 0 } }
    }
    if wide > 0.001 && have > 0 {
      let k = 1 + wide * 1.4  // side gain, same as the website chain
      let l = o[0], r = o[1]
      for i in 0..<have {
        let mid = (l[i] + r[i]) * 0.5
        let side = (l[i] - r[i]) * 0.5 * k
        l[i] = mid + side
        r[i] = mid - side
      }
    }
  }

  private func handleEnded() {
    guard let f = file else { return }
    finished = true
    wantPlaying = false
    pausedSeconds = Double(f.length) / f.processingFormat.sampleRate
    node.stop()
    emit("completed")
  }

  private func currentSeconds() -> Double {
    guard let f = file else { return 0 }
    let sr = f.processingFormat.sampleRate
    let dur = Double(f.length) / sr
    if node.isPlaying, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) {
      return max(0, min(dur, Double(startFrame + pt.sampleTime) / sr))
    }
    return pausedSeconds
  }

  // MARK: - Personalize sound

  private func number(_ v: Any?) -> Float {
    return (v as? NSNumber)?.floatValue ?? 0
  }

  private func applyFx(_ a: [String: Any]) {
    let on = (a["on"] as? Bool) ?? false
    let gains = (a["gains"] as? [NSNumber])?.map { $0.floatValue } ?? []
    let boost = max(0, min(12, number(a["boost"])))
    let bass = max(0, min(1, number(a["bass"])))
    let clarity = max(0, min(1, number(a["clarity"])))
    let room = max(0, min(1, number(a["room"])))
    wide = max(0, min(1, number(a["wide"])))

    for i in 0..<10 {
      let g: Float = (on && i < gains.count) ? gains[i] : 0
      eq.bands[i].gain = max(-24, min(24, g))
    }
    eq.bands[10].gain = bass * 9
    eq.bands[11].gain = clarity * 6
    eq.bands[12].gain = clarity * 3
    eq.globalGain = boost

    reverb.wetDryMix = room * 40
    reverb.bypass = room <= 0.001
    limiter.bypass = boost <= 0.01
  }

  // MARK: - System events

  @objc private func configChanged() {
    queue.async {
      guard self.file != nil, self.wantPlaying else { return }
      // The engine was stopped by the system (e.g. sample-rate change): carry on.
      let pos = self.currentSeconds()
      self.pausedSeconds = pos
      do {
        if let f = self.file {
          self.scheduleFrom(AVAudioFramePosition(pos * f.processingFormat.sampleRate))
        }
        try self.ensureEngineRunning()
        self.node.play()
      } catch {
        self.wantPlaying = false
        self.emit("paused")
      }
    }
  }

  @objc private func interrupted(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
    queue.async {
      guard self.wantPlaying else { return }
      self.pause()
      self.emit("paused")
    }
  }

  @objc private func routeChanged(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
    queue.async {
      guard self.wantPlaying else { return }
      self.pause()  // headphones pulled out
      self.emit("paused")
    }
  }
}
