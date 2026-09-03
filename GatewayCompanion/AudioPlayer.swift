import AVFoundation
import Foundation
import GatewaySync

@MainActor
final class CompanionAudioPlayer: NSObject, ObservableObject {
    @Published private(set) var session: SyncSession?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var error: String?
    @Published private(set) var failedSessionID: String?
    @Published private(set) var arrivalHolding = false
    @Published private(set) var returningToWaking = false

    var finished: ((SyncSession) -> Void)?
    var duration: TimeInterval { narrationFile.map { Double($0.length) / $0.processingFormat.sampleRate }
        ?? session?.seconds ?? 0 }

    private var engine: AVAudioEngine?
    private var narration = AVAudioPlayerNode()
    private var narrationFile: AVAudioFile?
    private var mediaNodes: [(cue: SyncMediaCue, node: AVAudioPlayerNode, buffer: AVAudioPCMBuffer)] = []
    private var exitNarration = AVAudioPlayerNode()
    private var exitFile: AVAudioFile?
    private var returnSignal = AVAudioPlayerNode()
    private var returnBuffer: AVAudioPCMBuffer?
    private var bed: SyncBedEngine?
    private var bedNode: AVAudioSourceNode?
    private var timer: Timer?
    private var seekSeconds = 0.0
    private var generation = 0

    func play(_ session: SyncSession, url: URL,
              assetURL: (SyncAssetReference) -> URL) {
        var preparation = "audio route"
        do {
            if self.session?.id == session.id, engine != nil {
                resume(); return
            }
            stop()
            let audioSession = AVAudioSession.sharedInstance()
            // Playback already permits AirPlay and Bluetooth A2DP. Passing
            // allowBluetoothA2DP here is an invalid category/option pairing on
            // iPhone and setCategory returns paramErr (OSStatus -50).
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)

            preparation = "session narration"
            guard session.bed != nil else { throw PlayerError.missingBed }
            let file = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine()
            let narration = AVAudioPlayerNode()
            engine.attach(narration)
            engine.connect(narration, to: engine.mainMixerNode, format: file.processingFormat)
            narration.volume = Float(session.mix?.speech ?? SyncAudioMix.standard.speech)

            preparation = "retained tuning and return recordings"
            let prepared = try (session.media ?? []).map { cue -> (SyncMediaCue, AVAudioPlayerNode, AVAudioPCMBuffer) in
                let buffer = try Self.fittedMedia(cue, url: assetURL(cue.audio))
                let node = AVAudioPlayerNode()
                node.volume = Float(cue.gain * Self.roleGain(cue.role, mix: session.mix ?? .standard))
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
                return (cue, node, buffer)
            }

            var preparedExit: AVAudioFile?
            var preparedReturn: AVAudioPCMBuffer?
            let exitNode = AVAudioPlayerNode()
            let signalNode = AVAudioPlayerNode()
            if session.isContinuous {
                guard let exit = session.exitNarration,
                      let signal = session.continuousReturnSignal else {
                    throw PlayerError.missingContinuousReturn
                }
                preparedExit = try AVAudioFile(forReading: assetURL(exit))
                preparedReturn = try Self.fittedMedia(signal, url: assetURL(signal.audio))
                engine.attach(exitNode)
                engine.connect(exitNode, to: engine.mainMixerNode,
                               format: preparedExit!.processingFormat)
                exitNode.volume = Float(session.mix?.speech ?? SyncAudioMix.standard.speech)
                engine.attach(signalNode)
                engine.connect(signalNode, to: engine.mainMixerNode,
                               format: preparedReturn!.format)
                signalNode.volume = Float((session.mix ?? .standard).returnSignal)
            }

            preparation = "live stereo bed"
            var bedEngine: SyncBedEngine?
            var sourceNode: AVAudioSourceNode?
            if let plan = session.bed {
                let renderer = SyncBedEngine(plan: plan, mix: session.mix ?? .standard)
                renderer.holdLastStage = session.isContinuous
                let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
                guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000,
                                                 channels: 2) else {
                    throw PlayerError.audioFormat
                }
                let node = Self.makeBedNode(renderer: renderer, format: format)
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                bedEngine = renderer; sourceNode = node
            }

            self.engine = engine; self.narration = narration
            narrationFile = file; mediaNodes = prepared
            exitNarration = exitNode; exitFile = preparedExit
            returnSignal = signalNode; returnBuffer = preparedReturn
            bed = bedEngine; bedNode = sourceNode
            self.session = session; error = nil; failedSessionID = nil; seekSeconds = 0
            arrivalHolding = false; returningToWaking = false
            preparation = "audio engine"
            try engine.start()
            schedule(from: 0)
            isPlaying = true
            startTimer()
        } catch {
            stop()
            failedSessionID = session.id
            self.error = "Could not prepare \(preparation): \(error.localizedDescription)"
        }
    }

    func pause() {
        guard let engine else { return }
        updateElapsed()
        engine.pause()
        isPlaying = false
        timer?.invalidate(); timer = nil
    }

    func resume() {
        guard let engine else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            isPlaying = true
            startTimer()
        } catch {
            failedSessionID = session?.id
            self.error = "Could not resume the complete session: \(error.localizedDescription)"
        }
    }

    func stop() {
        generation &+= 1
        narration.stop()
        mediaNodes.forEach { $0.node.stop() }
        exitNarration.stop(); returnSignal.stop()
        engine?.stop()
        engine = nil; narrationFile = nil; mediaNodes = []
        exitFile = nil; returnBuffer = nil
        bed?.targetGain = 0; bed?.reset(); bed = nil; bedNode = nil
        session = nil; isPlaying = false; elapsed = 0; seekSeconds = 0
        arrivalHolding = false; returningToWaking = false
        timer?.invalidate(); timer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func seek(to fraction: Double) {
        guard !arrivalHolding, !returningToWaking,
              narrationFile != nil, engine != nil else { return }
        let destination = max(0, min(1, fraction)) * duration
        narration.stop(); mediaNodes.forEach { $0.node.stop() }
        schedule(from: destination)
        elapsed = destination
    }

    private func schedule(from seconds: Double) {
        guard let file = narrationFile else { return }
        generation &+= 1
        let mine = generation
        seekSeconds = seconds
        let rate = file.processingFormat.sampleRate
        let frame = min(file.length, AVAudioFramePosition(seconds * rate))
        let remaining = file.length - frame
        guard remaining > 0 else { complete(generation: mine); return }
        narration.scheduleSegment(file, startingFrame: frame,
            frameCount: AVAudioFrameCount(remaining), at: nil,
            completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in self?.complete(generation: mine) }
            }
        for item in mediaNodes where item.cue.startSeconds + item.cue.seconds > seconds {
            let offset = max(0, seconds - item.cue.startSeconds)
            let delay = max(0, item.cue.startSeconds - seconds)
            guard let slice = Self.slice(item.buffer, seconds: offset) else { continue }
            item.node.scheduleBuffer(slice,
                at: AVAudioTime(sampleTime: AVAudioFramePosition(delay * slice.format.sampleRate),
                                atRate: slice.format.sampleRate))
            item.node.play()
        }
        bed?.seek(to: seconds)
        narration.play()
    }

    private func complete(generation mine: Int) {
        guard generation == mine, let completed = session else { return }
        updateElapsed()
        guard duration > 0, elapsed >= duration / 2 else {
            error = "Playback stopped before the session transport reached its end."
            isPlaying = false
            bed?.targetGain = 0
            return
        }
        elapsed = duration
        finished?(completed)
        narration.stop(); mediaNodes.forEach { $0.node.stop() }
        timer?.invalidate(); timer = nil
        if completed.isContinuous {
            bed?.seek(to: duration)
            arrivalHolding = true
            returningToWaking = false
            isPlaying = true
        } else {
            stop()
        }
    }

    /// Leave the Continuous arrival only when the listener asks: authored
    /// return narration first, then the retained wake-up signal.
    func returnToWaking() {
        guard arrivalHolding, let exitFile, returnBuffer != nil else {
            error = "This journey has no downloaded return narration and wake-up signal."
            return
        }
        generation &+= 1
        let mine = generation
        arrivalHolding = false
        returningToWaking = true
        isPlaying = true
        exitNarration.scheduleFile(
            exitFile, at: nil, completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == mine,
                      let returnBuffer = self.returnBuffer else { return }
                self.bed?.targetGain = 0
                self.returnSignal.scheduleBuffer(
                    returnBuffer, completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == mine else { return }
                        self.stop()
                    }
                }
                self.returnSignal.play()
            }
        }
        exitNarration.play()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
    }

    private func updateElapsed() {
        guard let rendered = narration.lastRenderTime,
              let played = narration.playerTime(forNodeTime: rendered) else { return }
        elapsed = min(duration, seekSeconds + Double(played.sampleTime) / played.sampleRate)
    }

    private nonisolated static func makeBedNode(renderer: SyncBedEngine,
                                                format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, count, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard list.count >= 2,
                  let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = list[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            renderer.render(left: left, right: right, count: Int(count),
                            sampleRate: format.sampleRate)
            return noErr
        }
    }

    private nonisolated static func roleGain(_ role: String, mix: SyncAudioMix) -> Double {
        role == "returnSignal" ? mix.returnSignal : mix.resonantTuning
    }

    private nonisolated static func fittedMedia(_ cue: SyncMediaCue,
                                                url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let sourceFrames = AVAudioFrameCount(file.length)
        guard sourceFrames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: sourceFrames) else {
            throw PlayerError.audioFormat
        }
        try file.read(into: source)
        guard let channels = source.floatChannelData else { throw PlayerError.audioFormat }
        let rate = source.format.sampleRate
        guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: rate, channels: 2,
                                               interleaved: false) else { throw PlayerError.audioFormat }
        let targetCount = max(1, Int((cue.seconds * rate).rounded()))
        guard let output = AVAudioPCMBuffer(pcmFormat: stereoFormat,
                                           frameCapacity: AVAudioFrameCount(targetCount)),
              let target = output.floatChannelData else { throw PlayerError.audioFormat }
        output.frameLength = AVAudioFrameCount(targetCount)
        let available = Int(source.frameLength)
        let overlap = cue.fit == "cropOrLoop"
            ? min(Int(cue.crossfadeSeconds * rate), available / 2) : 0
        for channel in 0..<2 {
            let input = channels[min(channel, Int(source.format.channelCount) - 1)]
            var written = min(targetCount, available)
            target[channel].update(from: input, count: written)
            while cue.fit == "cropOrLoop", written < targetCount {
                let blend = min(overlap, written, available)
                if blend > 0 {
                    for index in 0..<blend {
                        let amount = Float(index + 1) / Float(blend + 1)
                        let position = written - blend + index
                        target[channel][position] = target[channel][position] * (1 - amount)
                            + input[index] * amount
                    }
                }
                let amount = min(targetCount - written, available - blend)
                guard amount > 0 else { break }
                target[channel].advanced(by: written).update(from: input.advanced(by: blend),
                                                              count: amount)
                written += amount
            }
            if written < targetCount {
                target[channel].advanced(by: written).initialize(repeating: 0,
                                                                 count: targetCount - written)
            }
            let fade = min(Int(cue.edgeFadeSeconds * rate), targetCount / 2)
            if fade > 0 {
                for index in 0..<fade {
                    let amount = Float(index) / Float(max(1, fade - 1))
                    target[channel][index] *= amount
                    target[channel][targetCount - 1 - index] *= amount
                }
            }
        }
        return output
    }

    private nonisolated static func slice(_ source: AVAudioPCMBuffer,
                                          seconds: Double) -> AVAudioPCMBuffer? {
        let offset = min(Int(seconds * source.format.sampleRate), Int(source.frameLength))
        let count = Int(source.frameLength) - offset
        guard count > 0,
              let output = AVAudioPCMBuffer(pcmFormat: source.format,
                                            frameCapacity: AVAudioFrameCount(count)),
              let input = source.floatChannelData, let target = output.floatChannelData else { return nil }
        output.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(source.format.channelCount) {
            target[channel].update(from: input[channel].advanced(by: offset), count: count)
        }
        return output
    }
}

private enum PlayerError: LocalizedError {
    case audioFormat
    case missingBed
    case missingContinuousReturn
    var errorDescription: String? {
        switch self {
        case .audioFormat: "an audio asset has an unsupported format"
        case .missingBed: "this cached session predates complete mobile playback; sync it again"
        case .missingContinuousReturn:
            "this cached Continuous journey predates mobile return audio; sync it again"
        }
    }
}
