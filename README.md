# Screen Recorder

A personal fork of [Slice](https://github.com/rit3zh/slice), a native screen recorder and video editor for Mac, made by [@rit3zh](https://x.com/rit3zh).

> **This fork is for personal use only.** It is unofficial and not affiliated with the original author. It comes with no support. If you want this app, **please install the original [Slice](https://github.com/rit3zh/slice) instead** and support its author.

## Build

Requires macOS 15 or later, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open ScreenRecorder.xcodeproj
```

Set your own `DEVELOPMENT_TEAM` in `Config/Signing.xcconfig`, or run `scripts/setup-local-signing.sh` once for a self-signed identity. That keeps macOS Screen Recording, Camera and Microphone permissions across rebuilds without a developer account.

## License

The code is under the [Slice Source-Available License](LICENSE), © 2026 rit3zh. It allows personal use and free, unofficial, clearly marked forks. It forbids commercial use and redistribution. Third-party components keep their own licenses (section 11).

## Credits

All credit goes to [@rit3zh](https://x.com/rit3zh) and the original [Slice](https://github.com/rit3zh/slice). Thanks also to [FluidAudio](https://github.com/FluidInference/FluidAudio), [Parakeet](https://huggingface.co/FluidInference/parakeet-ultra-coreml), [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet), [SmoothGradient](https://github.com/raymondjavaxx/SmoothGradient), [border-beam](https://beam.jakubantalik.com), and the [3D iPhone and MacBook models](Sources/SliceCore/Resources/Models/CREDITS.txt) by their Sketchfab artists.
