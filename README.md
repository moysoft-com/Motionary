# Motionary

Motionary is a native iOS video editor built with SwiftUI, AVFoundation, Core Image, and the Photos picker.

## Requirements

- Xcode 17 or newer
- iOS 26 SDK
- An iOS 26 simulator or device

The project has no third-party runtime dependencies.

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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
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
