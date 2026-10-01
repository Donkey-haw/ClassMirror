@preconcurrency import AVFoundation
import ClassMirrorCore
import Foundation

final class AudioPlaybackController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.classmirror.audio-playback", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var isMuted = false
    private var queuedFrames: AVAudioFramePosition = 0
    private var playbackGeneration: UInt64 = 0
    private let maximumQueuedDuration: TimeInterval = 0.18

    init() {
        engine.attach(player)
    }

    func enqueue(_ decoded: DecodedAudioBuffer) {
        queue.async { [self] in
            let buffer = decoded.buffer
            do {
                try prepareIfNeeded(format: buffer.format)
                guard !isMuted else { return }
                discardBacklogIfNeeded(adding: buffer)
                let generation = playbackGeneration
                let frameCount = AVAudioFramePosition(buffer.frameLength)
                queuedFrames += frameCount
                player.scheduleBuffer(
                    buffer,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    guard let self else { return }
                    queue.async { [self] in
                        guard generation == playbackGeneration else { return }
                        queuedFrames = max(0, queuedFrames - frameCount)
                    }
                }
                if !player.isPlaying {
                    player.play()
                }
            } catch {
                fputs("ClassMirror AudioPlayback: \(error)\n", stderr)
            }
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [self] in
            isMuted = muted
            player.volume = muted ? 0 : 1
            if muted {
                clearScheduledAudio()
            } else if engine.isRunning {
                player.play()
            }
        }
    }

    func reset() {
        queue.async { [self] in
            clearScheduledAudio()
            engine.stop()
            if connectedFormat != nil {
                engine.disconnectNodeOutput(player)
            }
            connectedFormat = nil
        }
    }

    private func prepareIfNeeded(format: AVAudioFormat) throws {
        if connectedFormat != format {
            clearScheduledAudio()
            engine.stop()
            if connectedFormat != nil {
                engine.disconnectNodeOutput(player)
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.volume = isMuted ? 0 : 1
    }

    private func discardBacklogIfNeeded(adding buffer: AVAudioPCMBuffer) {
        let futureFrames = queuedFrames + AVAudioFramePosition(buffer.frameLength)
        let futureDuration = Double(futureFrames) / buffer.format.sampleRate
        guard futureDuration > maximumQueuedDuration else { return }
        clearScheduledAudio()
    }

    private func clearScheduledAudio() {
        playbackGeneration &+= 1
        queuedFrames = 0
        player.stop()
    }
}
