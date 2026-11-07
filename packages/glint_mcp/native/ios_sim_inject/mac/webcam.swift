import AVFoundation
import Foundation

let header = 32
let protocolVersion: UInt32 = 1

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

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "--status" {
    finish("\(statusName(AVCaptureDevice.authorizationStatus(for: .video))) \(pickCamera()?.localizedName ?? "no camera")", code: 0)
}
guard args.count >= 2 else { finish("usage: glint-webcam <frame file> | --status", code: 64) }

let path = args[1]

final class Pump: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let path: String
    let cameraName: String
    var base: UnsafeMutableRawPointer?
    var stride = 0
    var width = 0
    var height = 0
    var seq: UInt32 = 0

    init(path: String, cameraName: String) {
        self.path = path
        self.cameraName = cameraName
    }

    func open(width: Int, height: Int) -> Bool {
        let stride = width * 4
        let size = header + stride * height
        let tmp = path + ".tmp"
        let fd = Darwin.open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0, ftruncate(fd, off_t(size)) == 0 else { return false }
        guard let map = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), map != MAP_FAILED else { return false }
        let words = map.assumingMemoryBound(to: UInt32.self)
        words[1] = UInt32(width)
        words[2] = UInt32(height)
        words[3] = UInt32(stride)
        words[5] = protocolVersion
        guard rename(tmp, path) == 0 else { return false }
        base = map
        self.stride = stride
        self.width = width
        self.height = height
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let w = CVPixelBufferGetWidth(pixels)
        let h = CVPixelBufferGetHeight(pixels)
        guard let src = CVPixelBufferGetBaseAddress(pixels) else { return }
        if base == nil {
            guard open(width: w, height: h) else { finish("error cannot create \(path)", code: 1) }
            print("ready protocol=\(protocolVersion) \(cameraName)")
            fflush(stdout)
        }
        guard let base = base, w == width, h == height else { return }
        let srcStride = CVPixelBufferGetBytesPerRow(pixels)
        let words = base.assumingMemoryBound(to: UInt32.self)
        seq &+= 1
        if seq == 0 { seq = 1 }
        words[4] = seq
        OSMemoryBarrier()
        for row in 0..<h {
            memcpy(base + header + row * stride, src + row * srcStride, min(stride, srcStride))
        }
        OSMemoryBarrier()
        words[0] = seq
    }
}

let readerFresh: TimeInterval = 10
let firstReadGrace: TimeInterval = 60
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

func readerWants(_ marker: String, since start: Date) -> Bool {
    var info = stat()
    guard stat(marker, &info) == 0 else { return Date().timeIntervalSince(start) < firstReadGrace }
    let touched = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    return Date().timeIntervalSince(touched) < readerFresh
}

func start() {
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

    let parent = getppid()
    let watcher = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    watcher.setEventHandler { _exit(0) }
    watcher.resume()
    signal(SIGTERM) { _ in _exit(0) }
    signal(SIGINT) { _ in _exit(0) }

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

switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized:
    start()
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .video) { granted in
        if granted { DispatchQueue.main.async { start() } } else { finish("denied", code: 3) }
    }
    dispatchMain()
default:
    finish("denied", code: 3)
}
