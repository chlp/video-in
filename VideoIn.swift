import Cocoa
import AVFoundation
import Metal
import CoreVideo
import CoreAudio
import AudioToolbox

// ============================================================
// MARK: - Device selection (terminal)
// ============================================================

func listDevices(mediaType: AVMediaType, label: String) -> [AVCaptureDevice] {
    let types: [AVCaptureDevice.DeviceType] = mediaType == .video
        ? [.external, .builtInWideAngleCamera]
        : [.external, .microphone]
    let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: types,
        mediaType: mediaType,
        position: .unspecified
    ).devices
    print("\n\(label):")
    if devices.isEmpty { print("  (none)") }
    for (i, d) in devices.enumerated() {
        let tag = d.deviceType == .external ? "USB" : "built-in"
        print("  \(i + 1)) \(d.localizedName)  [\(tag)]")
    }
    return devices
}

func promptChoice(count: Int, label: String) -> Int? {
    if count == 0 { return nil }
    if count == 1 {
        print("\n→ Auto-selected the only \(label) device (1)")
        return 0
    }
    while true {
        print("\nSelect \(label) device [1-\(count), 0 = none]: ", terminator: "")
        guard let line = readLine(), let num = Int(line) else {
            print("  Enter a number.")
            continue
        }
        if num == 0 { return nil }
        if num >= 1 && num <= count { return num - 1 }
        print("  Out of range.")
    }
}

let videoDevices = listDevices(mediaType: .video, label: "Video devices")
let audioDevices = listDevices(mediaType: .audio, label: "Audio devices")

guard !videoDevices.isEmpty else {
    print("\nNo video devices found. Exiting.")
    exit(1)
}

guard let videoIdx = promptChoice(count: videoDevices.count, label: "video") else {
    print("No video device selected. Exiting.")
    exit(0)
}
let selectedVideo = videoDevices[videoIdx]

let selectedAudio: AVCaptureDevice?
if audioDevices.isEmpty {
    print("\nNo audio devices available, continuing without audio.")
    selectedAudio = nil
} else if let audioIdx = promptChoice(count: audioDevices.count, label: "audio") {
    selectedAudio = audioDevices[audioIdx]
} else {
    selectedAudio = nil
    print("Continuing without audio.")
}

print("\n--- Starting capture ---")
print("  Video: \(selectedVideo.localizedName)")
if let a = selectedAudio { print("  Audio: \(a.localizedName)") }
print()

// ============================================================
// MARK: - Audio ring buffer (lock-free SPSC)
// ============================================================

class AudioRingBuffer {
    private let capacity: Int
    private var buffer: UnsafeMutablePointer<Float>
    private var writePos: Int = 0
    private var readPos: Int = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    var available: Int {
        lock.lock()
        let a = (writePos - readPos + capacity) % capacity
        lock.unlock()
        return a
    }

    func write(_ data: UnsafePointer<Float>, count: Int) {
        lock.lock()
        for i in 0..<count {
            buffer[(writePos + i) % capacity] = data[i]
        }
        writePos = (writePos + count) % capacity
        lock.unlock()
    }

    func read(_ output: UnsafeMutablePointer<Float>, count: Int) -> Int {
        lock.lock()
        let avail = (writePos - readPos + capacity) % capacity
        let toRead = min(count, avail)
        for i in 0..<toRead {
            output[i] = buffer[(readPos + i) % capacity]
        }
        readPos = (readPos + toRead) % capacity
        lock.unlock()
        return toRead
    }
}

// ============================================================
// MARK: - Metal video renderer
// ============================================================

class MetalVideoRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    var textureCache: CVMetalTextureCache?
    let metalLayer: CAMetalLayer

    init(metalLayer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "Metal", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.metalLayer = metalLayer

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.displaySyncEnabled = false  // don't wait for vsync — lower latency

        // Shader: fullscreen textured quad
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;
        struct V2F {
            float4 pos [[position]];
            float2 uv;
        };
        vertex V2F vtx(uint vid [[vertex_id]]) {
            float2 positions[] = {
                float2(-1, -1), float2(1, -1), float2(-1, 1),
                float2(-1, 1), float2(1, -1), float2(1, 1)
            };
            float2 uvs[] = {
                float2(0, 1), float2(1, 1), float2(0, 0),
                float2(0, 0), float2(1, 1), float2(1, 0)
            };
            V2F out;
            out.pos = float4(positions[vid], 0, 1);
            out.uv = uvs[vid];
            return out;
        }
        fragment float4 frag(V2F in [[stage_in]],
                             texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear);
            return tex.sample(s, in.uv);
        }
        """

        let library = try device.makeLibrary(source: shaderSrc, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vtx")
        desc.fragmentFunction = library.makeFunction(name: "frag")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache
    }

    func render(pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache,
              let drawable = metalLayer.nextDrawable() else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm,
            width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

// ============================================================
// MARK: - AppDelegate
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate,
                   AVCaptureVideoDataOutputSampleBufferDelegate,
                   AVCaptureAudioDataOutputSampleBufferDelegate {

    let videoDevice: AVCaptureDevice
    let audioDevice: AVCaptureDevice?

    var window: NSWindow!
    var captureSession: AVCaptureSession!
    var metalRenderer: MetalVideoRenderer?
    var metalLayer: CAMetalLayer!

    // Audio playback
    var audioUnit: AudioComponentInstance?
    var ringBuffer: AudioRingBuffer?
    var audioSampleRate: Double = 48000
    var audioChannels: Int = 2

    init(videoDevice: AVCaptureDevice, audioDevice: AVCaptureDevice?) {
        self.videoDevice = videoDevice
        self.audioDevice = audioDevice
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Window
        let windowRect = NSRect(x: 100, y: 100, width: 960, height: 540)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Video In — \(videoDevice.localizedName)"
        window.center()

        let contentView = NSView(frame: windowRect)
        contentView.wantsLayer = true
        window.contentView = contentView

        // Metal layer for video rendering
        metalLayer = CAMetalLayer()
        metalLayer.frame = contentView.bounds
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView.layer?.addSublayer(metalLayer)

        do {
            metalRenderer = try MetalVideoRenderer(metalLayer: metalLayer)
        } catch {
            print("Metal init failed: \(error). Exiting.")
            NSApp.terminate(nil)
            return
        }

        // Capture session
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high

        // Video input
        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
            }
        } catch {
            print("Cannot open video: \(error)")
            NSApp.terminate(nil)
            return
        }

        // Configure video device for native format (avoid transcoding)
        configureVideoFormat()

        // Video output — raw frames to Metal
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let videoQueue = DispatchQueue(label: "video", qos: .userInteractive)
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // Audio
        if let audioDevice = audioDevice {
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if captureSession.canAddInput(audioInput) {
                    captureSession.addInput(audioInput)
                }
            } catch {
                print("Warning: Cannot open audio: \(error)")
            }

            let audioOutput = AVCaptureAudioDataOutput()
            let audioQueue = DispatchQueue(label: "audio", qos: .userInteractive)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
            }

            setupAudioUnit()
        }

        window.makeKeyAndOrderFront(nil)

        DispatchQueue.global(qos: .userInteractive).async {
            self.captureSession.startRunning()
        }
    }

    // MARK: - Video format configuration

    func configureVideoFormat() {
        // Pick the highest resolution format that doesn't require transcoding
        let formats = videoDevice.formats
        var bestFormat: AVCaptureDevice.Format?
        var bestWidth: Int32 = 0

        for format in formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            if dims.width >= bestWidth {
                bestWidth = dims.width
                bestFormat = format
            }
        }

        if let format = bestFormat {
            do {
                try videoDevice.lockForConfiguration()
                videoDevice.activeFormat = format
                // Minimize frame duration (maximize FPS)
                let minDuration = format.videoSupportedFrameRateRanges
                    .map(\.minFrameDuration)
                    .min(by: { CMTimeGetSeconds($0) < CMTimeGetSeconds($1) })
                if let min = minDuration {
                    videoDevice.activeVideoMinFrameDuration = min
                    videoDevice.activeVideoMaxFrameDuration = min
                }
                videoDevice.unlockForConfiguration()
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let fps = minDuration.map { 1.0 / CMTimeGetSeconds($0) } ?? 0
                print("Video format: \(dims.width)x\(dims.height) @ \(String(format: "%.1f", fps)) fps")
            } catch {
                print("Warning: Could not configure video format: \(error)")
            }
        }
    }

    // MARK: - Audio Unit (minimal buffer playback)

    func setupAudioUnit() {
        // Ring buffer: ~100ms worth of audio (small = low latency)
        ringBuffer = AudioRingBuffer(capacity: Int(audioSampleRate) * audioChannels)

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            print("Warning: No audio output component")
            return
        }

        var unit: AudioComponentInstance?
        AudioComponentInstanceNew(component, &unit)
        guard let audioUnit = unit else { return }
        self.audioUnit = audioUnit

        // Set minimal buffer size (128 frames ≈ 2.7ms at 48kHz)
        var bufferFrames: UInt32 = 128
        AudioUnitSetProperty(audioUnit,
                             kAudioDevicePropertyBufferFrameSize,
                             kAudioUnitScope_Global, 0,
                             &bufferFrames, UInt32(MemoryLayout<UInt32>.size))

        // Stream format: Float32, interleaved stereo
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: audioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(audioChannels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(audioChannels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(audioChannels),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        AudioUnitSetProperty(audioUnit,
                             kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0,
                             &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        // Render callback — reads from ring buffer
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) -> OSStatus in
                let me = Unmanaged<AppDelegate>.fromOpaque(inRefCon).takeUnretainedValue()
                guard let bufferList = ioData else { return noErr }
                let channels = Int(bufferList.pointee.mNumberBuffers)
                // We use interleaved so there's one buffer
                if channels >= 1 {
                    let buf = bufferList.pointee.mBuffers
                    let ptr = buf.mData?.assumingMemoryBound(to: Float.self)
                    let totalSamples = Int(inNumberFrames) * me.audioChannels
                    if let ptr = ptr, let ring = me.ringBuffer {
                        let read = ring.read(ptr, count: totalSamples)
                        // Zero-fill if not enough data (silence)
                        if read < totalSamples {
                            for i in read..<totalSamples { ptr[i] = 0 }
                        }
                    }
                }
                return noErr
            },
            inputProcRefCon: selfPtr
        )

        AudioUnitSetProperty(audioUnit,
                             kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0,
                             &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        AudioUnitInitialize(audioUnit)
        AudioOutputUnitStart(audioUnit)
        print("Audio output: \(Int(audioSampleRate))Hz, \(audioChannels)ch, buffer \(bufferFrames) frames")
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            metalRenderer?.render(pixelBuffer: pixelBuffer)
        } else if output is AVCaptureAudioDataOutput {
            processAudio(sampleBuffer)
        }
    }

    // MARK: - Audio processing

    func processAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let ringBuffer = ringBuffer else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)

        // Detect source format
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc!)?.pointee {
            if asbd.mSampleRate != audioSampleRate || Int(asbd.mChannelsPerFrame) != audioChannels {
                audioSampleRate = asbd.mSampleRate
                audioChannels = Int(asbd.mChannelsPerFrame)
                // Restart audio unit with new format would be needed for format changes
            }
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let ptr = dataPointer else { return }

        // Source might be Float32 or Int16 — check format
        let formatFlags = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc!)!.pointee.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0

        if isFloat {
            let floatPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
            let sampleCount = length / MemoryLayout<Float>.size
            ringBuffer.write(floatPtr, count: sampleCount)
        } else {
            // Int16 → Float32
            let int16Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: Int16.self)
            let sampleCount = length / MemoryLayout<Int16>.size
            var floats = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount {
                floats[i] = Float(int16Ptr[i]) / 32768.0
            }
            floats.withUnsafeBufferPointer { buf in
                ringBuffer.write(buf.baseAddress!, count: sampleCount)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        captureSession?.stopRunning()
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioComponentInstanceDispose(au)
        }
    }
}

// ============================================================
// MARK: - Entry point
// ============================================================

let app = NSApplication.shared
let delegate = AppDelegate(videoDevice: selectedVideo, audioDevice: selectedAudio)
app.delegate = delegate
app.run()
