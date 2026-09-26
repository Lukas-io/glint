import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Extracts frames from a recorded video, keeping the distinct ones, and prints one JSON line per kept frame plus a final summary.
enum FrameSampler {
    struct Options {
        let video: URL
        let outDir: URL
        let everyMs: Int
        let maxFrames: Int
        let distinctOnly: Bool
    }

    static func run(_ o: Options) throws {
        let asset = AVURLAsset(url: o.video)
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { sem.signal() }
        sem.wait()

        let durationMs = Int(CMTimeGetSeconds(asset.duration) * 1000.0)
        guard durationMs > 0 else {
            print(#"{"done":true,"durationMs":0,"sampled":0,"emitted":0,"capped":false}"#)
            return
        }
        try FileManager.default.createDirectory(
            at: o.outDir, withIntermediateDirectories: true)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        // In non-distinct mode, stride so the kept frames span the whole clip.
        let sampleCount = durationMs / o.everyMs + 1
        let stride = o.distinctOnly
            ? 1
            : max(1, Int(ceil(Double(sampleCount) / Double(o.maxFrames))))

        var lastPrint: [UInt8]? = nil
        var emitted = 0
        var sampled = 0
        var capped = false
        var i = 0
        var t = 0
        while t <= durationMs {
            if !o.distinctOnly && i % stride != 0 {
                i += 1
                t += o.everyMs
                continue
            }
            let time = CMTime(value: CMTimeValue(t), timescale: 1000)
            guard let image = try? gen.copyCGImage(at: time, actualTime: nil) else {
                i += 1
                t += o.everyMs
                continue
            }
            sampled += 1
            let fp = fingerprint(image)
            let keep = !o.distinctOnly || lastPrint == nil || differs(fp, lastPrint!)
            if keep {
                if emitted >= o.maxFrames {
                    capped = true
                    break
                }
                let name = String(format: "frame-%05dms.png", t)
                let url = o.outDir.appendingPathComponent(name)
                try writePNG(image, to: url)
                print("{\"path\":\"\(url.path)\",\"atMs\":\(t)}")
                lastPrint = fp
                emitted += 1
            }
            i += 1
            t += o.everyMs
        }
        print("{\"done\":true,\"durationMs\":\(durationMs),\"sampled\":\(sampled),"
            + "\"emitted\":\(emitted),\"capped\":\(capped)}")
    }

    /// 32x32 grayscale bytes: averaging suppresses h264 noise and a blinking caret.
    static func fingerprint(_ image: CGImage) -> [UInt8] {
        let side = 32
        var buf = [UInt8](repeating: 0, count: side * side)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &buf, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side, space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return buf }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buf
    }

    /// True when more than 0.5 percent of thumbnail pixels moved by more than 12 levels.
    static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var moved = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 12 { moved += 1 }
        return Double(moved) / Double(a.count) > 0.005
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw SimError(message: "could not create PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SimError(message: "could not finalize PNG at \(url.path)")
        }
    }
}
