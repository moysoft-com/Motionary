# Development conventions

## Source files

- Keep one primary responsibility per file.
- Add a one-line file summary before imports.
- Document non-obvious state transitions, invariants, and compatibility behavior.
- Prefer small value types and focused extensions over broad utility namespaces.
- Keep feature-specific views inside their feature directory.

## Naming

- Types use `UpperCamelCase`; properties and functions use `lowerCamelCase`.
- Commands describe intent (`deleteLayer`, `finishInteractiveEdit`).
- Preview-only calculations use `preview` or `resolved` prefixes.
- Persisted model names describe stored concepts rather than UI labels.

## State and side effects

- SwiftUI views render state and forward user intent.
- `EditorViewModel` coordinates state transitions and user-facing errors.
- Project mutations use the shared mutation gateway unless an interactive edit intentionally defers history and
  persistence.
- File-system, media import, rendering, and export work stays in services.
- Use `AppLogger` instead of `print` for diagnostics.

## Formatting

The repository uses `swift-format` with four-space indentation and a 120-column target. Run:

```sh
xcrun swift-format format --in-place --recursive \
  --configuration .swift-format \
  Motionary MotionaryTests MotionaryUITests
```

## Testing

Behavioral changes require focused unit tests. Refactors must run the complete `Motionary` scheme test action because it
contains unit, launch, and UI tests. Timeline tests should assert placement, ordering, snapping, trimming, selection,
and persistence outcomes rather than implementation details.

## What’s New sheet

Add an entry to [WhatsNew.json](../Motionary/Resources/WhatsNew.json) with the exact Xcode marketing version as its key. Copy the 1.0 entry as a template. Supply the title, feature bullets, and button label. The subtitle and text sections are optional. Section bodies support inline Markdown.

The sheet appears on a regular launch until the user taps its button. Use the same version key for every build of a release. Omit the entry for an update that should skip the sheet.

Add `--preview-whats-new` to the Debug scheme’s launch arguments to preview the current release on every regular launch without marking it as seen. Remove the argument before resuming normal testing.

## Compatibility constraints

- Do not change persisted coding keys without a migration.
- Do not change default render dimensions, frame rate, clip duration, snapping thresholds, or timing tolerances as part
  of cleanup work.
- Preserve track render order and the shared preview/export composition path.
- Treat visual constants as product behavior; move them only when their values remain identical.

