# VideoIn

A minimal macOS application for viewing video and playing audio from a USB capture device (capture card, webcam, etc.) with minimal latency.

Uses AVFoundation: `AVCaptureVideoPreviewLayer` for hardware-accelerated video rendering and `AVCaptureAudioPreviewOutput` for audio playback.

## Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- USB video capture device

## Build

```bash
swiftc -O -o VideoIn VideoIn.swift -framework Cocoa -framework AVFoundation
```

## Run

```bash
./VideoIn
```

On launch, the terminal displays a list of available video and audio devices. Select by entering a number:

```
Video devices:
  1) USB Video  [USB]
  2) FaceTime HD Camera  [built-in]

Audio devices:
  1) USB Audio  [USB]
  2) MacBook Pro Microphone  [built-in]

Select video device [1-2, 0 = none]: 1
Select audio device [1-2, 0 = none]: 1
```

- If only one device is available, it is selected automatically
- `0` for audio — start without sound
- `0` for video — exit

After selection, a window opens with the video stream. macOS will prompt for camera and microphone permissions on first launch.
