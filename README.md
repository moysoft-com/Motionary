# Motionary

Motionary is a native iOS video editor built with SwiftUI, AVFoundation, Core Image, and the Photos picker.

## Requirements

- Xcode with the iOS 26 SDK or newer
- iOS 18 or newer on device or Simulator (Liquid Glass uses iOS 26 APIs where available)

Swift Package Manager resolves Firebase Core, Authentication, Firestore and App Check for the suggestions feature. Editing, media storage and rendering run locally.

## Getting started

1. Open `Motionary.xcodeproj`.
2. Select the `Motionary` scheme.
3. Choose an iOS simulator or device.
4. Build and run.

Command-line verification:

```sh
xcodebuild build \
  -project Motionary.xcodeproj \
  -scheme Motionary \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project Motionary.xcodeproj \
  -scheme Motionary \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Format all Swift sources with the checked-in configuration:

```sh
xcrun swift-format format --in-place --recursive \
  --configuration .swift-format \
  Motionary MotionaryTests MotionaryUITests
```

## Documentation

- [Architecture](Documentation/ARCHITECTURE.md)
- [Development conventions](Documentation/DEVELOPMENT.md)
- [Modernization summary](Documentation/MODERNIZATION.md)
- [Reliability overhaul and verification](Documentation/ReliabilityOverhaul.md)

Release verification and outstanding device/operational checks are tracked in [Release readiness](Documentation/ReleaseReadiness.md).
