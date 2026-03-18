import Cocoa
import AVFoundation

// --- Device selection in terminal before GUI starts ---

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
    if devices.isEmpty {
        print("  (none)")
    }
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

// List devices
let videoDevices = listDevices(mediaType: .video, label: "Video devices")
let audioDevices = listDevices(mediaType: .audio, label: "Audio devices")

guard !videoDevices.isEmpty else {
    print("\nNo video devices found. Exiting.")
    exit(1)
}

// Prompt user
guard let videoIdx = promptChoice(count: videoDevices.count, label: "video") else {
    print("No video device selected. Exiting.")
    exit(0)
}
let selectedVideo = videoDevices[videoIdx]

let selectedAudio: AVCaptureDevice?
if audioDevices.isEmpty {
    print("\nNo audio devices available, continuing without audio.")
    selectedAudio = nil
} else {
    if let audioIdx = promptChoice(count: audioDevices.count, label: "audio") {
        selectedAudio = audioDevices[audioIdx]
    } else {
        selectedAudio = nil
        print("Continuing without audio.")
    }
}

print("\n--- Starting capture ---")
print("  Video: \(selectedVideo.localizedName)")
if let a = selectedAudio { print("  Audio: \(a.localizedName)") }
print()

// --- App ---

class AppDelegate: NSObject, NSApplicationDelegate {
    let videoDevice: AVCaptureDevice
    let audioDevice: AVCaptureDevice?
    var window: NSWindow!
    var captureSession: AVCaptureSession!
    var previewLayer: AVCaptureVideoPreviewLayer!

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
            showAlert("Cannot open video device: \(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        // Audio input
        if let audioDevice = audioDevice {
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if captureSession.canAddInput(audioInput) {
                    captureSession.addInput(audioInput)
                }
            } catch {
                print("Warning: Cannot open audio device: \(error.localizedDescription)")
            }

            let audioOutput = AVCaptureAudioPreviewOutput()
            audioOutput.volume = 1.0
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
            }
        }

        // Video preview layer
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.frame = contentView.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView.layer?.addSublayer(previewLayer)

        window.makeKeyAndOrderFront(nil)

        DispatchQueue.global(qos: .userInteractive).async {
            self.captureSession.startRunning()
        }
    }

    func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureSession?.stopRunning()
    }
}

// --- Entry point ---
let app = NSApplication.shared
let delegate = AppDelegate(videoDevice: selectedVideo, audioDevice: selectedAudio)
app.delegate = delegate
app.run()
