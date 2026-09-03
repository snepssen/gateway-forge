import Foundation

public struct StereoAudio: Equatable, Sendable {
    public var sampleRate: Double
    public var left: [Float]
    public var right: [Float]

    public init(sampleRate: Double, left: [Float], right: [Float]) {
        self.sampleRate = sampleRate; self.left = left; self.right = right
    }

    public var count: Int { min(left.count, right.count) }
    public var seconds: Double { sampleRate > 0 ? Double(count) / sampleRate : 0 }
}

public enum SessionMedia {
    public struct TrailingWindow: Equatable, Sendable {
        public var startSeconds: Double
        public var seconds: Double

        public init(startSeconds: Double, seconds: Double) {
            self.startSeconds = startSeconds
            self.seconds = seconds
        }
    }

    /// Reserve transport time after narration for retained media. The session
    /// WAV remains narration-only; silence keeps its player, live bed and media
    /// nodes running until the trailing recording has actually completed.
    @discardableResult
    public static func appendTrailingWindow(to samples: inout [Float],
                                            seconds: Double,
                                            sampleRate: Int = RenderPlan.sampleRate)
        -> TrailingWindow {
        let rate = max(1, sampleRate)
        let start = Double(samples.count) / Double(rate)
        let frames = max(0, Int((seconds * Double(rate)).rounded()))
        samples.append(contentsOf: repeatElement(Float.zero, count: frames))
        return TrailingWindow(startSeconds: start,
                              seconds: Double(frames) / Double(rate))
    }

    /// Fit a source to the authored window without changing pitch or rate.
    /// Short repeating sources overlap their own edges; long sources crop.
    public static func fit(_ input: StereoAudio, seconds: Double,
                           mode: AudioAssetFit, crossfadeSeconds: Double,
                           edgeFadeSeconds: Double) -> StereoAudio {
        let target = max(0, Int((seconds * input.sampleRate).rounded()))
        guard target > 0, input.count > 0 else {
            return StereoAudio(sampleRate: input.sampleRate, left: [], right: [])
        }
        let sourceL = Array(input.left.prefix(input.count))
        let sourceR = Array(input.right.prefix(input.count))
        var left = Array(sourceL.prefix(target)), right = Array(sourceR.prefix(target))

        if mode == .cropOrLoop, left.count < target {
            let overlap = min(Int(crossfadeSeconds * input.sampleRate), input.count / 2)
            while left.count < target {
                let n = min(overlap, left.count, sourceL.count)
                if n > 0 {
                    let base = left.count - n
                    for i in 0..<n {
                        let k = Float(i + 1) / Float(n + 1)
                        left[base + i] = left[base + i] * (1 - k) + sourceL[i] * k
                        right[base + i] = right[base + i] * (1 - k) + sourceR[i] * k
                    }
                }
                let room = target - left.count
                let start = n
                let amount = min(room, sourceL.count - start)
                guard amount > 0 else { break }
                left.append(contentsOf: sourceL[start..<(start + amount)])
                right.append(contentsOf: sourceR[start..<(start + amount)])
            }
        }

        // A source ending on energy must not click against the live bed.
        let fade = min(Int(edgeFadeSeconds * input.sampleRate), left.count / 2)
        if fade > 0 {
            for i in 0..<fade {
                let k = Float(i) / Float(max(1, fade - 1))
                left[i] *= k; right[i] *= k
                left[left.count - 1 - i] *= k; right[right.count - 1 - i] *= k
            }
        }
        return StereoAudio(sampleRate: input.sampleRate, left: left, right: right)
    }
}
