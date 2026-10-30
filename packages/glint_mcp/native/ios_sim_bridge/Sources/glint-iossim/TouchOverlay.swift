import AVFoundation
import Foundation
import QuartzCore

/// Draws touches onto a finished recording: each finger is a dot with a short trail while down and a ring that grows and fades on release.
enum TouchOverlay {
    /// One finger: when it went down (seconds from the video's start) and its path as [x, y, ms] in video pixels.
    struct Finger: Decodable {
        let t: Double
        let points: [[Double]]
    }

    /// Video pixels per logical point, which sizes the dot, and every finger to draw.
    struct Input: Decodable {
        let scale: Double
        let fingers: [Finger]
    }

    enum Failure: Error, CustomStringConvertible {
        case noVideoTrack, exportFailed(String)
        var description: String {
            switch self {
            case .noVideoTrack: return "the recording has no video track"
            case .exportFailed(let why): return "writing the video failed: \(why)"
            }
        }
    }

    static let radius = 15.0
    static let trail = 0.14
    static let release = 0.28
    static let blue = CGColor(red: 4 / 255, green: 102 / 255, blue: 200 / 255, alpha: 1)

    static func run(video: URL, touches: URL, out: URL) throws {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: touches))
        let asset = AVURLAsset(url: video)
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { sem.signal() }
        sem.wait()
        guard let source = asset.tracks(withMediaType: .video).first else { throw Failure.noVideoTrack }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.noVideoTrack }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: source, at: .zero)
        track.preferredTransform = source.preferredTransform

        let shown = source.naturalSize.applying(source.preferredTransform)
        let size = CGSize(width: abs(shown.width), height: abs(shown.height))
        let total = max(CMTimeGetSeconds(asset.duration), 0.001)

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = true
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        let r = radius * input.scale
        for finger in input.fingers where !finger.points.isEmpty {
            addFinger(finger, radius: r, total: total, to: parent)
        }

        let videoComposition = AVMutableVideoComposition(propertiesOf: composition)
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)

        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed("no export session")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        let done = DispatchSemaphore(value: 0)
        export.exportAsynchronously { done.signal() }
        done.wait()
        if export.status != .completed {
            throw Failure.exportFailed(export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        }
        print(#"{"done":true,"fingers":\#(input.fingers.count)}"#)
    }

    /// A keyframe animation of [key] over the whole video, holding the first value before and the last value after.
    static func track(_ key: String, _ samples: [(Double, Any)], total: Double) -> CAKeyframeAnimation {
        var times: [NSNumber] = []
        var values: [Any] = []
        var last = -1.0
        for (t, v) in [(0, samples.first!.1)] + samples + [(total, samples.last!.1)] {
            let k = min(max(t / total, last), 1)
            times.append(NSNumber(value: k))
            values.append(v)
            last = k
        }
        let a = CAKeyframeAnimation(keyPath: key)
        a.keyTimes = times
        a.values = values
        a.duration = total
        a.beginTime = AVCoreAnimationBeginTimeAtZero
        a.isRemovedOnCompletion = false
        a.fillMode = .both
        a.calculationMode = .linear
        return a
    }

    static func addFinger(_ f: Finger, radius r: Double, total: Double, to parent: CALayer) {
        let points = f.points.map { CGPoint(x: $0[0], y: $0[1]) }
        let times = f.points.map { f.t + $0[2] / 1000 }
        let down = times.first!
        let up = times.last!

        var lengths = [0.0]
        for i in 1..<max(points.count, 1) where points.count > 1 {
            lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let length = lengths.last ?? 0
        if length > 1 {
            let path = CGMutablePath()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            let line = CAShapeLayer()
            line.frame = parent.bounds
            line.path = path
            line.fillColor = nil
            line.strokeColor = blue.copy(alpha: 0.4)
            line.lineWidth = r * 1.1
            line.lineCap = .round
            line.lineJoin = .round
            let ends = zip(times, lengths).map { ($0.0, $0.1 / length as Any) }
            let starts = zip(times, lengths).map { ($0.0 + trail, $0.1 / length as Any) }
            line.add(track("strokeEnd", [(down, 0.0 as Any)] + ends, total: total), forKey: "end")
            line.add(track("strokeStart", [(down, 0.0 as Any)] + starts, total: total), forKey: "start")
            line.add(track("opacity", [(down - 0.001, 0.0), (down, 1.0), (up, 1.0), (up + trail, 0.0)], total: total), forKey: "fade")
            parent.addSublayer(line)
        }

        let dot = CAShapeLayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        dot.fillColor = CGColor(gray: 1, alpha: 0.85)
        dot.strokeColor = blue
        dot.lineWidth = 2.5 * r / radius
        dot.add(track("position", zip(times, points).map { ($0.0, NSValue(point: $0.1) as Any) }, total: total), forKey: "move")
        dot.add(track("opacity", [(down - 0.001, 0.0), (down, 1.0), (up, 1.0), (up + release, 0.0)], total: total), forKey: "fade")
        parent.addSublayer(dot)

        let ring = CAShapeLayer()
        ring.bounds = dot.bounds
        ring.path = dot.path
        ring.fillColor = nil
        ring.strokeColor = blue
        ring.lineWidth = dot.lineWidth
        ring.position = points.last!
        ring.add(track("opacity", [(up - 0.001, 0.0), (up, 0.9), (up + release, 0.0)], total: total), forKey: "fade")
        ring.add(track("transform.scale", [(up, 1.0), (up + release, 2.6)], total: total), forKey: "grow")
        parent.addSublayer(ring)
    }

}
