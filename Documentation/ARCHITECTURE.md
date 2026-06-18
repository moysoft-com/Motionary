# Architecture

Motionary uses a feature-oriented architecture with explicit domain, state, presentation, persistence, media, and
rendering boundaries. The app remains a single Xcode target; directory boundaries communicate ownership without adding
runtime indirection.

## Dependency direction

```text
SwiftUI views
    ↓
EditorViewModel and feature state
    ↓
Domain models and project operations
    ↓
Persistence, import, composition, and export services
    ↓
Apple frameworks and the file system
```

Views may request user actions from a view model, but they do not persist projects or construct AVFoundation
compositions directly. Services consume domain values and do not depend on SwiftUI views.

## Source layout

```text
Motionary/
├── DesignSystem/          Shared colors, surfaces, and inspector controls
├── Editor/
│   ├── Controls/          Toolbar and inspector workspaces
│   ├── Preview/           Preview canvas and direct manipulation
│   ├── Timeline/          Timeline layout, gestures, clips, thumbnails, waveforms
│   └── ProjectEditorView  Editor composition root
├── EditorCore/            Observable state and editor commands
├── EditorDomain/          Codable project, timeline, transform, effect, and render models
├── Home/
│   └── Components/        Dashboard-specific reusable views
├── Infrastructure/        Cross-cutting facilities such as unified logging
├── MediaPipeline/         Media import and audio-session configuration
├── Rendering/             Composition, custom compositing, and export
└── Helpers/               Small Apple-framework adapters and conversion helpers
```

## Editor state

`EditorViewModel` owns the current `EditorProject`, selection, playback state, undo/redo history, and service
dependencies. Its implementation is split into behavior-focused extensions:

- playback and lifecycle;
- import and layer management;
- clip editing;
- canvas, transforms, effects, and keyframes;
- rendering and export;
- mutation, persistence, and selection validation.

All project mutations continue to flow through the same mutation gateway so history, persistence, timeline revisions,
and preview rebuilding remain consistent.

## Domain and persistence

`EditorProject` is the persisted aggregate. `ProjectContent` is the storage envelope and migration boundary. Temporary
undefined layers are removed only during encoding/decoding, matching the existing persistence behavior. The legacy
`Clip` model remains solely for backward-compatible decoding and migration.

## Rendering

`CompositionRenderService` converts project tracks into AVFoundation composition tracks and custom compositor
instructions. `MotionaryVideoCompositor` applies transforms, adjustments, effects, opacity, and layer ordering.
`VideoExportService` uses the same rendered composition as preview, preventing preview/export drift.

