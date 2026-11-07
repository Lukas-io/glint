import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

let header = 32
let protocolVersion: UInt32 = 1
let readerFresh: TimeInterval = 10
let firstReadGrace: TimeInterval = 60

func finish(_ line: String, code: Int32) -> Never {
    print(line)
    fflush(stdout)
    exit(code)
}

func statusName(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    default: return "notDetermined"
    }
}

func pickCamera() -> AVCaptureDevice? {
    let found = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external],
        mediaType: .video,
        position: .unspecified
    ).devices
    return found.first ?? AVCaptureDevice.default(for: .video)
}

final class Frames {
    let path: String
    var base: UnsafeMutableRawPointer?
    var size = 0
    var width = 0
    var height = 0
    var stride = 0
    var seq: UInt32 = 0

    init(path: String) {
        self.path = path
    }

    var isOpen: Bool { base != nil }

    func open(width: Int, height: Int) -> Bool {
        if let base = base { munmap(base, size) }
        base = nil
        stride = width * 4
        size = header + stride * height
        let tmp = path + ".tmp"
        let fd = Darwin.open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0, ftruncate(fd, off_t(size)) == 0 else { return false }
        guard let map = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), map != MAP_FAILED else { return false }
        close(fd)
        let words = map.assumingMemoryBound(to: UInt32.self)
        words[1] = UInt32(width)
        words[2] = UInt32(height)
        words[3] = UInt32(stride)
        words[5] = protocolVersion
        guard rename(tmp, path) == 0 else { return false }
        base = map
        self.width = width
        self.height = height
        return true
    }

    func publish(width: Int, height: Int, _ fill: (UnsafeMutableRawPointer, Int) -> Bool) -> Bool {
        if base == nil || width != self.width || height != self.height {
            guard open(width: width, height: height) else { return false }
        }
        guard let base = base else { return false }
        let words = base.assumingMemoryBound(to: UInt32.self)
        seq &+= 1
        if seq == 0 { seq = 1 }
        words[4] = seq
        OSMemoryBarrier()
        let filled = fill(base + header, stride)
        OSMemoryBarrier()
        words[0] = seq
        return filled
    }
}

func readerWants(_ marker: String, since start: Date, notBefore floor: Date = .distantPast) -> Bool {
    var info = stat()
    guard stat(marker, &info) == 0 else { return Date().timeIntervalSince(start) < firstReadGrace }
    let touched = max(Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)), floor)
    return Date().timeIntervalSince(touched) < readerFresh
}

func exitWhenParentGoes() -> DispatchSourceProcess {
    let watcher = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    watcher.setEventHandler { _exit(0) }
    watcher.resume()
    signal(SIGTERM) { _ in _exit(0) }
    signal(SIGINT) { _ in _exit(0) }
    return watcher
}

final class Pump: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let frames: Frames
    let cameraName: String

    init(path: String, cameraName: String) {
        frames = Frames(path: path)
        self.cameraName = cameraName
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        guard let src = CVPixelBufferGetBaseAddress(pixels) else { return }
        let first = !frames.isOpen
        if first, !frames.open(width: w, height: h) { finish("error cannot create \(frames.path)", code: 1) }
        if first {
            print("ready protocol=\(protocolVersion) \(cameraName)")
            fflush(stdout)
        }
        guard w == frames.width, h == frames.height else { return }
        let srcStride = CVPixelBufferGetBytesPerRow(pixels)
        _ = frames.publish(width: w, height: h) { dst, stride in
            for row in 0..<h {
                memcpy(dst + row * stride, src + row * srcStride, min(stride, srcStride))
            }
            return true
        }
    }
}

let wantedWidth: Int32 = 1280
let wantedHeight: Int32 = 720
let wantedFps: Int32 = 15

func pickFormat(_ camera: AVCaptureDevice) -> AVCaptureDevice.Format? {
    camera.formats.first { format in
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return d.width == wantedWidth && d.height == wantedHeight
    }
}

func limitRate(_ camera: AVCaptureDevice, session: AVCaptureSession) {
    guard let format = pickFormat(camera), (try? camera.lockForConfiguration()) != nil else {
        session.sessionPreset = .hd1280x720
        return
    }
    camera.activeFormat = format
    if format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(wantedFps) && Double(wantedFps) <= $0.maxFrameRate }) {
        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: wantedFps)
        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: wantedFps)
    }
    camera.unlockForConfiguration()
}

func startWebcam(path: String) {
    guard let camera = pickCamera() else { finish("error no camera on this Mac", code: 2) }
    let session = AVCaptureSession()
    guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
        finish("error cannot open \(camera.localizedName)", code: 1)
    }
    session.addInput(input)
    limitRate(camera, session: session)
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.alwaysDiscardsLateVideoFrames = true
    let pump = Pump(path: path, cameraName: camera.localizedName)
    output.setSampleBufferDelegate(pump, queue: DispatchQueue(label: "glint.webcam"))
    guard session.canAddOutput(output) else { finish("error cannot read \(camera.localizedName)", code: 1) }
    session.addOutput(output)
    session.startRunning()

    let watcher = exitWhenParentGoes()

    let started = Date()
    let marker = path + ".read"
    let gate = DispatchSource.makeTimerSource(queue: .main)
    gate.schedule(deadline: .now() + 1, repeating: 1)
    gate.setEventHandler {
        let wanted = readerWants(marker, since: started)
        if wanted && !session.isRunning {
            session.startRunning()
        } else if !wanted && session.isRunning {
            session.stopRunning()
        }
    }
    gate.resume()
    withExtendedLifetime((session, pump, watcher, gate)) { dispatchMain() }
}

func runWebcam(_ args: [String]) -> Never {
    if args.first == "--status" {
        finish("\(statusName(AVCaptureDevice.authorizationStatus(for: .video))) \(pickCamera()?.localizedName ?? "no camera")", code: 0)
    }
    guard let path = args.first else { finish("usage: glint-frames webcam <frame file> | --status", code: 64) }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        startWebcam(path: path)
    case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted { DispatchQueue.main.async { startWebcam(path: path) } } else { finish("denied", code: 3) }
        }
        dispatchMain()
    default:
        finish("denied", code: 3)
    }
    dispatchMain()
}

var activeShot: Process?
let shotLock = NSLock()

func capture(udid: String, to file: String) -> CGImage? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    task.arguments = ["simctl", "io", udid, "screenshot", "--type=png", file]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    shotLock.lock()
    activeShot = task
    shotLock.unlock()
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    shotLock.lock()
    activeShot = nil
    shotLock.unlock()
    guard task.terminationStatus == 0,
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func draw(_ image: CGImage, into dst: UnsafeMutableRawPointer, stride: Int) -> Bool {
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(
        data: dst, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: stride,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info
    ) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return true
}

func runScreen(_ args: [String]) -> Never {
    guard args.count >= 2 else { finish("usage: glint-frames screen <udid> <frame file> [fps] [paused file]", code: 64) }
    let udid = args[0]
    let path = args[1]
    let wantedFps = args.count > 2 ? max(1, min(60, Double(args[2]) ?? 15)) : 15
    let pausedPath = args.count > 3 ? args[3] : nil
    let watcher = exitWhenParentGoes()
    let frames = Frames(path: path)
    let scratch = path + ".png"
    signal(SIGTERM, SIG_IGN)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    terminate.setEventHandler {
        shotLock.lock()
        activeShot?.terminate()
        shotLock.unlock()
        try? FileManager.default.removeItem(atPath: scratch)
        _exit(0)
    }
    terminate.resume()
    let started = Date()
    var lastPause = Date.distantPast
    var announced = false
    var failures = 0

    DispatchQueue.global().async {
        while true {
            if let pausedPath = pausedPath, FileManager.default.fileExists(atPath: pausedPath) {
                lastPause = Date()
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            if !readerWants(path + ".read", since: started, notBefore: lastPause) {
                try? FileManager.default.removeItem(atPath: scratch)
                finish("idle no reader for \(Int(readerFresh)) s", code: 0)
            }
            let tick = Date()
            if let image = capture(udid: udid, to: scratch),
               frames.publish(width: image.width, height: image.height, { dst, stride in draw(image, into: dst, stride: stride) }) {
                failures = 0
                if !announced {
                    announced = true
                    print("ready protocol=\(protocolVersion) \(image.width)x\(image.height)")
                    fflush(stdout)
                }
            } else {
                failures += 1
                if !announced && failures >= 5 { finish("error cannot capture the screen of \(udid)", code: 1) }
                if announced && failures >= 30 { finish("error the screen of \(udid) stopped answering", code: 1) }
                Thread.sleep(forTimeInterval: 0.5)
            }
            let spare = 1.0 / wantedFps - Date().timeIntervalSince(tick)
            if spare > 0 { Thread.sleep(forTimeInterval: spare) }
        }
    }
    withExtendedLifetime((watcher, frames, terminate)) { dispatchMain() }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "screen": runScreen(Array(arguments.dropFirst()))
case "webcam": runWebcam(Array(arguments.dropFirst()))
default: finish("usage: glint-frames webcam <frame file> | --status | screen <udid> <frame file> [fps] [paused file]", code: 64)
}
