// Contextual transform, adjustment, and effect workspaces.

import SwiftUI
import UIKit

struct CanvasWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        EditorWorkspaceShell(
            title: "Canvas",
            systemImage: "aspectratio"
        ) {
            VStack(spacing: 12) {
                EditorWorkspaceCard(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Format", systemImage: "rectangle.on.rectangle")
                            .font(MotionaryDesign.Typography.controlTitleStrong)
                        Spacer()
                        Text(currentResolution)
                            .font(MotionaryDesign.Typography.controlValue)
                            .foregroundStyle(MotionaryTheme.textSecondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            CanvasFormatButton(
                                title: "Original",
                                aspectRatio: originalAspectRatio ?? currentAspectRatio,
                                isSelected: isOriginalSelected,
                                isEnabled: viewModel.canApplySelectedClipOriginalRatio
                            ) {
                                viewModel.setCanvasToSelectedClipOriginalRatio()
                            }

                            ForEach(CanvasRatioPreset.presets) { preset in
                                CanvasFormatButton(
                                    title: preset.title,
                                    aspectRatio: CGFloat(preset.width) / CGFloat(preset.height),
                                    isSelected: isSelected(preset)
                                ) {
                                    viewModel.setCanvasPreset(preset)
                                }
                            }
                        }
                    }
                }

                EditorWorkspaceCard(alignment: .leading, spacing: 10) {
                    Label("Background", systemImage: "paintpalette")
                        .font(MotionaryDesign.Typography.controlTitleStrong)

                    HStack(spacing: 10) {
                        ColorPicker(
                            "Canvas background",
                            selection: Binding(
                                get: { viewModel.project.renderSettings.backgroundColor.swiftUIColor },
                                set: { viewModel.setCanvasBackgroundColor(RGBAColor($0)) }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()

                        Text("Canvas color")
                            .font(MotionaryDesign.Typography.pillLabel)
                        Spacer()
                        EditorWorkspaceCapsuleIconButton(
                            systemName: "arrow.counterclockwise",
                            accessibilityLabel: "Reset canvas background"
                        ) {
                            viewModel.setCanvasBackgroundColor(.black)
                        }
                    }
                }
            }
        }
    }

    private var isOriginalSelected: Bool {
        guard let clip = viewModel.selectedClip,
            clip.mediaType != .audio,
            let size = viewModel.project.naturalSize(for: clip)?.cgSize
        else { return false }
        let width = max(Int(abs(size.width).rounded()), 1)
        let height = max(Int(abs(size.height).rounded()), 1)
        return viewModel.project.renderSettings.width == width
            && viewModel.project.renderSettings.height == height
    }

    private func isSelected(_ preset: CanvasRatioPreset) -> Bool {
        viewModel.project.renderSettings.width == preset.width
            && viewModel.project.renderSettings.height == preset.height
    }

    private var currentResolution: String {
        let settings = viewModel.project.renderSettings
        return "\(settings.width) × \(settings.height)"
    }

    private var currentAspectRatio: CGFloat {
        let settings = viewModel.project.renderSettings
        return CGFloat(settings.width) / CGFloat(max(settings.height, 1))
    }

    private var originalAspectRatio: CGFloat? {
        guard let clip = viewModel.selectedClip,
            clip.mediaType != .audio,
            let size = viewModel.project.naturalSize(for: clip)?.displaySafeSize
        else { return nil }
        return size.width / max(size.height, 1)
    }
}

private struct CanvasFormatButton: View {
    let title: String
    let aspectRatio: CGFloat
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        EditorWorkspaceTileButton(
            title: title,
            isSelected: isSelected,
            isEnabled: isEnabled,
            accessibilityLabel: "Canvas format \(title)",
            action: action
        ) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(
                    isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary,
                    lineWidth: 1.5
                )
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(width: 28, height: 30)
        }
    }
}

struct ShapeWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
        PropertyWorkspaceShell(
            viewModel: viewModel,
            clip: clip,
            title: "Shape",
            systemImage: "slider.horizontal.3",
            section: .shape
        ) { clip, isEnabled in
            if let shape = clip.shape {
                VStack(spacing: 12) {
                    PropertyScrubber(
                        viewModel: viewModel,
                        clip: clip,
                        target: .shapeWidth,
                        isEnabled: isEnabled
                    )
                    PropertyScrubber(
                        viewModel: viewModel,
                        clip: clip,
                        target: .shapeHeight,
                        isEnabled: isEnabled
                    )

                    if shape.kind.supportsCornerRadius {
                        PropertyScrubber(
                            viewModel: viewModel,
                            clip: clip,
                            target: .shapeCornerRadius,
                            isEnabled: isEnabled
                        )
                    }

                    EditorWorkspaceColorRow(
                        title: "Color",
                        color: shape.color.swiftUIColor
                    ) {
                        viewModel.setSelectedShape(color: RGBAColor($0))
                    }
                    .disabled(!isEnabled)
                }
            }
        }
    }
}

struct TransformWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?
    let text: TextTimelineItem?

    var body: some View {
        Group {
            if let text {
                TextTransformWorkspace(viewModel: viewModel, item: text)
            } else {
                PropertyWorkspaceShell(
                    viewModel: viewModel,
                    clip: clip,
                    title: "Transform",
                    systemImage: "crop.rotate",
                    section: .transform
                ) { clip, isEnabled in
                    VStack(spacing: 12) {
                        ForEach([
                            KeyframeTarget.positionX,
                            .positionY,
                            .rotation,
                        ]) { target in
                            PropertyScrubber(
                                viewModel: viewModel,
                                clip: clip,
                                target: target,
                                isEnabled: isEnabled
                            )
                        }

                        if clip.transform.scale.isLinked {
                            PropertyScrubber(viewModel: viewModel, clip: clip, target: .scale, isEnabled: isEnabled)
                        } else {
                            PropertyScrubber(viewModel: viewModel, clip: clip, target: .scaleX, isEnabled: isEnabled)
                            PropertyScrubber(viewModel: viewModel, clip: clip, target: .scaleY, isEnabled: isEnabled)
                        }

                        TransformMirrorSection(
                            isHorizontallyMirrored: clip.transform.isFlippedHorizontally,
                            isVerticallyMirrored: clip.transform.isFlippedVertically,
                            isEnabled: isEnabled,
                            onHorizontalChange: { enabled in
                                viewModel.setSelectedTransform(
                                    isFlippedHorizontally: enabled
                                )
                            },
                            onVerticalChange: { enabled in
                                viewModel.setSelectedTransform(
                                    isFlippedVertically: enabled
                                )
                            },
                            onReset: {
                                viewModel.updateSelectedClip { $0.transform = ClipTransform() }
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct TransformMirrorSection: View {
    let isHorizontallyMirrored: Bool
    let isVerticallyMirrored: Bool
    let isEnabled: Bool
    let onHorizontalChange: (Bool) -> Void
    let onVerticalChange: (Bool) -> Void
    let onReset: () -> Void

    var body: some View {
        EditorWorkspaceSection(title: "Mirror", systemImage: "rectangle.on.rectangle") {
            EditorWorkspaceMirrorButtons(
                isHorizontallyMirrored: isHorizontallyMirrored,
                isVerticallyMirrored: isVerticallyMirrored,
                isEnabled: isEnabled,
                onHorizontalChange: onHorizontalChange,
                onVerticalChange: onVerticalChange
            )

            HStack {
                Spacer()
                EditorWorkspaceCapsuleIconButton(
                    systemName: "arrow.counterclockwise",
                    accessibilityLabel: "Reset transform",
                    isEnabled: isEnabled,
                    action: onReset
                )
            }
        }
    }
}

private struct TextTransformWorkspace: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TextTimelineItem

    var body: some View {
        let isEnabled =
            viewModel.selectedTimelineItemID == item.id
            && viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
        EditorWorkspaceShell(
            title: "Transform",
            systemImage: "crop.rotate",
            isEnabled: isEnabled,
            disablesContentWhenUnavailable: true,
            accessory: {
                SectionKeyframeButton(
                    viewModel: viewModel,
                    itemID: item.id,
                    section: .transform,
                    isEnabled: isEnabled
                )
            },
            content: {
                let unitSpace = EditorUnitSpace(size: viewModel.project.renderSettings.size)
                VStack(spacing: 12) {
                    ForEach(TextTransformControl.allCases) { control in
                        let rawValue = control.value(in: item, at: localTime)
                        EditorValueScrubber(
                            title: control.title,
                            systemImage: control.systemImage,
                            value: control.displayValue(rawValue, in: unitSpace),
                            range: control.displayRange(in: unitSpace),
                            step: control.displayStep,
                            format: control.format,
                            onBegan: viewModel.beginInteractiveEdit,
                            onChanged: { value in
                                set(control.rawValue(value, in: unitSpace), for: control)
                            },
                            onEnded: viewModel.finishTextEditing
                        )
                    }

                    TransformMirrorSection(
                        isHorizontallyMirrored: item.visuals.transform.isFlippedHorizontally,
                        isVerticallyMirrored: item.visuals.transform.isFlippedVertically,
                        isEnabled: isEnabled,
                        onHorizontalChange: { enabled in
                            updateTransform { transform in
                                transform.isFlippedHorizontally = enabled
                            }
                        },
                        onVerticalChange: { enabled in
                            updateTransform { transform in
                                transform.isFlippedVertically = enabled
                            }
                        },
                        onReset: {
                            viewModel.updateTextItem(item.id) { $0.visuals.transform = ClipTransform() }
                        }
                    )
                }
            }
        )
    }

    private var localTime: Double {
        min(max(viewModel.currentTime - item.timelineStart, 0), item.duration)
    }

    private func set(_ value: Double, for control: TextTransformControl) {
        viewModel.setSelectedTextKeyframeValue(
            value,
            target: control.keyframeTarget,
            interactive: true
        )
    }

    private func updateTransform(_ update: @escaping (inout ClipTransform) -> Void) {
        viewModel.updateTextItem(item.id) { item in
            update(&item.visuals.transform)
        }
    }

}

private enum TextTransformControl: String, CaseIterable, Identifiable {
    case positionX
    case positionY
    case rotation
    case scale

    var id: String { rawValue }

    var keyframeTarget: KeyframeTarget {
        switch self {
        case .positionX: .positionX
        case .positionY: .positionY
        case .rotation: .rotation
        case .scale: .scale
        }
    }

    var title: String {
        switch self {
        case .positionX: "Position X"
        case .positionY: "Position Y"
        case .rotation: "Rotation"
        case .scale: "Scale"
        }
    }

    var systemImage: String {
        switch self {
        case .positionX: "arrow.left.and.right"
        case .positionY: "arrow.up.and.down"
        case .rotation: "rotate.right"
        case .scale: "arrow.up.left.and.arrow.down.right"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .positionX, .positionY: -2...2
        case .rotation: -720...720
        case .scale: 0.01...100
        }
    }

    var displayStep: Double {
        switch self {
        case .positionX, .positionY: 1
        case .scale: 0.01
        case .rotation: 1
        }
    }

    var format: (Double) -> String {
        switch self {
        case .positionX, .positionY:
            { "\(Int($0.rounded()))" }
        case .rotation:
            { "\(Int($0.rounded()))°" }
        case .scale:
            { $0.formatted(.number.precision(.fractionLength(2))) + "×" }
        }
    }

    func displayValue(_ rawValue: Double, in space: EditorUnitSpace) -> Double {
        switch self {
        case .positionX:
            space.horizontalUnits(fromNormalizedPosition: rawValue)
        case .positionY:
            space.verticalUnits(fromNormalizedPosition: rawValue)
        case .rotation, .scale:
            rawValue
        }
    }

    func rawValue(_ displayValue: Double, in space: EditorUnitSpace) -> Double {
        switch self {
        case .positionX:
            space.normalizedHorizontalPosition(fromUnits: displayValue)
        case .positionY:
            space.normalizedVerticalPosition(fromUnits: displayValue)
        case .rotation, .scale:
            displayValue
        }
    }

    func displayRange(in space: EditorUnitSpace) -> ClosedRange<Double> {
        return switch self {
        case .positionX:
            ClosedRange(
                uncheckedBounds: (
                    space.horizontalUnits(fromNormalizedPosition: range.lowerBound),
                    space.horizontalUnits(fromNormalizedPosition: range.upperBound)
                )
            )
        case .positionY:
            ClosedRange(
                uncheckedBounds: (
                    space.verticalUnits(fromNormalizedPosition: range.lowerBound),
                    space.verticalUnits(fromNormalizedPosition: range.upperBound)
                )
            )
        case .rotation, .scale:
            range
        }
    }

    func value(in item: TextTimelineItem, at time: Double) -> Double {
        switch self {
        case .positionX: item.visuals.transform.positionX.value(at: time)
        case .positionY: item.visuals.transform.positionY.value(at: time)
        case .rotation: item.visuals.transform.rotationDegrees.value(at: time)
        case .scale: item.visuals.transform.scale.value(at: time).x
        }
    }
}

struct AudioWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
        PropertyWorkspaceShell(
            viewModel: viewModel,
            clip: clip,
            title: "Audio",
            systemImage: "speaker.wave.2",
            section: .audio
        ) { clip, isEnabled in
            VStack(spacing: 12) {
                if clip.mediaType == .audio || clip.mediaType == .video {
                    PropertyScrubber(
                        viewModel: viewModel,
                        clip: clip,
                        target: .volume,
                        isEnabled: isEnabled
                    )
                } else {
                    Text("Audio controls are available for audio and video clips.")
                        .font(.caption)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct AdjustWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?

    var body: some View {
        PropertyWorkspaceShell(
            viewModel: viewModel,
            clip: clip,
            title: "Adjust",
            systemImage: "slider.horizontal.3",
            section: .adjust
        ) { clip, isEnabled in
            VStack(spacing: 12) {
                if clip.mediaType != .audio {
                    ForEach([
                        KeyframeTarget.opacity,
                        .brightness,
                        .contrast,
                        .saturation,
                        .exposure,
                    ]) { target in
                        PropertyScrubber(
                            viewModel: viewModel,
                            clip: clip,
                            target: target,
                            isEnabled: isEnabled
                        )
                    }
                }
            }
        }
    }
}

struct EffectsWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?
    @Binding var activeEffectID: UUID?

    @State private var isLibraryPresented = false
    @State private var librarySelection: EffectModuleID = .cinematicBloom
    @State private var workspacePage: Int? = 0
    @State private var visibleEffectID: UUID?
    @State private var pullToAddEffectDistance: CGFloat = 0
    @State private var pullToAddEffectBounceTrigger = false
    @State private var suppressActiveEffectCloseAnimation = false
    @State private var listWorkspaceMaxX: CGFloat?
    @State private var pagerMinX: CGFloat?
    @State private var effectDrag: EffectListDragState?
    @State private var effectDragTranslation: CGFloat = 0
    @State private var isPagerTransitioning = false
    @State private var pagerTransitionToken = UUID()

    var body: some View {
        let isEnabled = clip.map(isWorkspaceEnabled) ?? false
        let canAddEffects = isEnabled && clip?.mediaType != .audio
        GeometryReader { geometry in
            ZStack {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        EditorWorkspaceShell(
                            title: "Effects",
                            systemImage: "wand.and.stars",
                            isEnabled: isEnabled,
                            emptyState: clip == nil
                                ? EditorWorkspaceEmptyState(title: "Select a clip", systemImage: "cursorarrow.click.2")
                                : nil,
                            contentStyle: .fixed,
                            accessory: {
                                Button {
                                    guard canAddEffects else { return }
                                    EditorHaptics.tap()
                                    isLibraryPresented = true
                                } label: {
                                    Image(systemName: "plus")
                                        .resizable()
                                        .scaledToFit()
                                        .font(.system(size: 16, weight: .semibold))
                                        .workspaceHeaderAccessoryFrame()
                                }
                                .buttonStyle(.plain)
                                .disabled(!canAddEffects)
                                .opacity(canAddEffects ? 1 : 0.3)
                                .accessibilityLabel("Add effect")
                            },
                            content: {
                                if let clip {
                                    ScrollView {
                                        effectsContent(clip: clip, isEnabled: isEnabled)
                                            .padding(.bottom, 6)
                                    }
                                    .scrollIndicators(.hidden)
                                    .scrollDismissesKeyboard(.interactively)
                                    .scrollDisabled(effectDrag != nil)
                                }
                            }
                        )
                        .frame(width: geometry.size.width)
                        .effectPagerOpacity(pageWidth: geometry.size.width)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: EffectsListWorkspaceMaxXPreferenceKey.self,
                                    value: proxy.frame(in: .global).maxX
                                )
                            }
                        }
                        .id(0)

                        if let clip,
                            let visibleEffectID,
                            let effect = clip.effectStack.effects.first(where: { $0.id == visibleEffectID })
                        {
                            EffectDetailWorkspaceView(
                                viewModel: viewModel,
                                clip: clip,
                                effect: effect,
                                isEnabled: isEnabled,
                                onBack: { closeEffectDetail() }
                            )
                            .frame(width: geometry.size.width)
                            .effectPagerOpacity(pageWidth: geometry.size.width)
                            .id(1)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $workspacePage)
                .scrollDisabled(effectDrag != nil)
                .coordinateSpace(name: EffectsWorkspacePagerOpacity.coordinateSpaceName)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .simultaneousGesture(pullToAddEffectGesture(isEnabled: isEnabled))

                if isPagerTransitioning {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(true)
                }

                pullToAddEffectIndicator(in: geometry.size)
            }
            .background {
                Color.clear.preference(
                    key: EffectsPagerMinXPreferenceKey.self,
                    value: geometry.frame(in: .global).minX
                )
            }
        }
        .onPreferenceChange(EffectsListWorkspaceMaxXPreferenceKey.self) { maxX in
            listWorkspaceMaxX = maxX
        }
        .onPreferenceChange(EffectsPagerMinXPreferenceKey.self) { minX in
            pagerMinX = minX
        }
        .sheet(isPresented: $isLibraryPresented) {
            EffectLibrarySheet(selectedModuleID: $librarySelection) { moduleID in
                if let effectID = viewModel.addEffect(moduleID: moduleID) {
                    openEffectDetail(effectID)
                }
                isLibraryPresented = false
            }
        }
        .onChange(of: clip?.id) { _, _ in
            activeEffectID = nil
            visibleEffectID = nil
            workspacePage = 0
        }
        .onChange(of: clip?.effectStack.effects.map(\.id)) { _, ids in
            guard let visibleEffectID,
                ids?.contains(visibleEffectID) == true
            else {
                activeEffectID = nil
                self.visibleEffectID = nil
                workspacePage = 0
                return
            }
        }
        .onChange(of: activeEffectID) { _, effectID in
            if let effectID {
                visibleEffectID = effectID
                viewModel.activeKeyframeTarget = .effectMix(effectID)
                animateWorkspacePage(to: 1)
            } else if suppressActiveEffectCloseAnimation {
                suppressActiveEffectCloseAnimation = false
                viewModel.activeKeyframeTarget = nil
                scheduleVisibleEffectRemoval()
            } else if visibleEffectID != nil {
                animateWorkspacePage(to: 0)
                scheduleVisibleEffectRemoval()
            } else {
                workspacePage = 0
            }
        }
        .onChange(of: workspacePage) { _, page in
            if page == 0, visibleEffectID != nil {
                suppressActiveEffectCloseAnimation = true
                activeEffectID = nil
                viewModel.activeKeyframeTarget = nil
                scheduleVisibleEffectRemoval()
            } else if page == 1, activeEffectID == nil {
                workspacePage = 0
            } else if page == nil {
                workspacePage = visibleEffectID == nil ? 0 : 1
            }
        }
    }

    @ViewBuilder
    private func effectsContent(clip: TimelineClip, isEnabled: Bool) -> some View {
        VStack(spacing: 12) {
            if clip.mediaType == .audio {
                Text("Effects are available for visual clips.")
                    .font(.caption)
                    .foregroundStyle(MotionaryTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if clip.effectStack.effects.isEmpty {
                    EffectsWorkspaceEmptyState()
                } else {
                    ForEach(displayEffects(for: clip), id: \.effect.id) { item in
                        EffectStackDisclosureRow(
                            viewModel: viewModel,
                            clip: clip,
                            effect: item.effect,
                            index: item.displayIndex,
                            totalCount: clip.effectStack.effects.count,
                            isEnabled: isEnabled,
                            dragState: effectDrag,
                            dragTranslation: effectDragTranslation,
                            onToggleExpanded: {
                                openEffectDetail(item.effect.id)
                            },
                            onDragChanged: { translation in
                                updateEffectDrag(
                                    effectID: item.effect.id,
                                    startIndex: item.displayIndex,
                                    translation: translation,
                                    totalCount: clip.effectStack.effects.count
                                )
                            },
                            onDragEnded: {
                                finishEffectDrag()
                            }
                        )
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.22, extraBounce: 0), value: clip.effectStack.effects.map(\.id))
    }

    private func isWorkspaceEnabled(_ clip: TimelineClip) -> Bool {
        viewModel.selectedClipID == clip.id && isTimeInsideTimelineItem(clip)
    }

    private func isTimeInsideTimelineItem(_ clip: TimelineClip) -> Bool {
        guard let item = viewModel.project.item(id: clip.id) else {
            return viewModel.isTimeInside(clip)
        }
        return viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
    }

    private func displayEffects(for clip: TimelineClip) -> [EffectStackDisplayItem] {
        clip.effectStack.effects.enumerated().reversed().enumerated().map {
            EffectStackDisplayItem(
                displayIndex: $0.offset,
                effect: $0.element.element
            )
        }
    }

    private func effectDisplayName(_ effect: EffectInstance) -> String {
        guard EffectRegistry.shared.availability(of: effect) == .available else {
            return "Unavailable Effect"
        }
        return EffectRegistry.shared.descriptor(for: effect.moduleID)?.name ?? "Effect"
    }

    private func updateEffectDrag(
        effectID: UUID,
        startIndex: Int,
        translation: CGFloat,
        totalCount: Int
    ) {
        guard totalCount > 1 else { return }
        let rowDistance = EditorWorkspaceControlStyle.height + 12
        let state = effectDrag ?? EffectListDragState(
            effectID: effectID,
            startIndex: startIndex,
            targetIndex: startIndex,
            totalCount: totalCount
        )
        let targetIndex = min(
            max(state.startIndex + Int((translation / rowDistance).rounded()), 0),
            totalCount - 1
        )
        if targetIndex != state.targetIndex {
            EditorHaptics.tap()
            withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
                effectDrag = EffectListDragState(
                    effectID: effectID,
                    startIndex: state.startIndex,
                    targetIndex: targetIndex,
                    totalCount: totalCount
                )
            }
        } else if effectDrag == nil {
            effectDrag = state
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            effectDragTranslation = translation
        }
    }

    private func finishEffectDrag() {
        guard let effectDrag else { return }
        self.effectDrag = nil
        effectDragTranslation = 0
        guard effectDrag.startIndex != effectDrag.targetIndex else { return }
        withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
            viewModel.moveEffect(
                effectDrag.effectID,
                offset: -(effectDrag.targetIndex - effectDrag.startIndex)
            )
        }
    }

    private func pullToAddEffectGesture(isEnabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { gesture in
                guard isEnabled, activeEffectID == nil, visibleEffectID == nil else { return }
                guard abs(gesture.translation.width) > abs(gesture.translation.height),
                    gesture.translation.width < 0
                else {
                    pullToAddEffectDistance = 0
                    return
                }
                let distance = min(-gesture.translation.width, effectPullToAddThreshold * 1.35)
                let wasReady = pullToAddEffectDistance >= effectPullToAddThreshold
                pullToAddEffectDistance = distance
                let isReady = distance >= effectPullToAddThreshold
                if isReady && !wasReady {
                    pullToAddEffectBounceTrigger.toggle()
                    EditorHaptics.tap()
                }
            }
            .onEnded { gesture in
                defer {
                    withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.82)) {
                        pullToAddEffectDistance = 0
                    }
                }
                guard isEnabled, activeEffectID == nil, visibleEffectID == nil else { return }
                guard abs(gesture.translation.width) > abs(gesture.translation.height),
                    -gesture.translation.width >= effectPullToAddThreshold
                else { return }
                isLibraryPresented = true
            }
    }

    private func pullToAddEffectIndicator(in size: CGSize) -> some View {
        let threshold = effectPullToAddThreshold
        let progress = min(max(pullToAddEffectDistance / threshold, 0), 1)
        let localScreenRightEdge = currentScreenWidth(fallback: size.width) - (pagerMinX ?? 0)
        let localWorkspaceRightEdge = (listWorkspaceMaxX ?? localScreenRightEdge) - (pagerMinX ?? 0)
        let gapCenterX = (localWorkspaceRightEdge + localScreenRightEdge) * 0.5

        return Image(systemName: "plus")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(MotionaryTheme.foregroundOnAccent)
            .frame(width: 30, height: 30)
            .symbolEffect(.bounce, value: pullToAddEffectBounceTrigger)
            .background {
                Circle()
                    .fill(progress >= 1 ? MotionaryTheme.accent : Color.gray)
            }
            .opacity(min(max((progress - 0.45) / 0.55, 0), 1))
            .scaleEffect(progress)
            .position(x: gapCenterX, y: size.height * 0.5)
            .allowsHitTesting(false)
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.82), value: progress)
    }

    private var effectPullToAddThreshold: CGFloat { 124 }

    private func currentScreenWidth(fallback: CGFloat) -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }
            .first ?? fallback
    }

    private func openEffectDetail(_ effectID: UUID) {
        visibleEffectID = effectID
        activeEffectID = effectID
        viewModel.activeKeyframeTarget = .effectMix(effectID)
        animateWorkspacePage(to: 1)
    }

    private func closeEffectDetail() {
        activeEffectID = nil
        viewModel.activeKeyframeTarget = nil
        animateWorkspacePage(to: 0)
        scheduleVisibleEffectRemoval()
    }

    private func animateWorkspacePage(to page: Int) {
        let token = UUID()
        pagerTransitionToken = token
        isPagerTransitioning = true
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.32, extraBounce: 0)) {
                workspacePage = page
            }
            settleWorkspacePage(page, token: token)
        }
    }

    private func settleWorkspacePage(_ page: Int, token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            guard pagerTransitionToken == token else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                workspacePage = page
                isPagerTransitioning = false
            }
        }
    }

    private func scheduleVisibleEffectRemoval() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            guard activeEffectID == nil, workspacePage != 1 else { return }
            visibleEffectID = nil
            workspacePage = 0
        }
    }
}

private struct EffectStackDisplayItem {
    let displayIndex: Int
    let effect: EffectInstance
}

private struct EffectListDragState: Equatable {
    let effectID: UUID
    let startIndex: Int
    let targetIndex: Int
    let totalCount: Int
}

private struct EffectsWorkspaceEmptyState: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(MotionaryTheme.accent)

            Text("No effects yet")
                .font(MotionaryDesign.Typography.controlTitleStrong)
                .foregroundStyle(MotionaryTheme.textPrimary)

            Text("Add an effect to start shaping this layer.")
                .font(MotionaryDesign.Typography.pillLabel)
                .foregroundStyle(MotionaryTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, minHeight: 172)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct EffectsListWorkspaceMaxXPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct EffectsPagerMinXPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private enum EffectsWorkspacePagerOpacity {
    static let coordinateSpaceName = "EffectsWorkspacePager"

    static func opacity(for frame: CGRect, pageWidth: CGFloat) -> Double {
        let safeWidth = max(pageWidth, 1)
        let outsideFraction = min(abs(frame.minX) / safeWidth, 1)
        guard outsideFraction > 0.75 else { return 1 }
        return max(0, 1 - Double((outsideFraction - 0.75) / 0.25))
    }
}

private struct EffectPagerOpacityModifier: ViewModifier {
    let pageWidth: CGFloat

    func body(content: Content) -> some View {
        content.visualEffect { content, proxy in
            content.opacity(
                EffectsWorkspacePagerOpacity.opacity(
                    for: proxy.frame(in: .named(EffectsWorkspacePagerOpacity.coordinateSpaceName)),
                    pageWidth: pageWidth
                )
            )
        }
    }
}

private extension View {
    func effectPagerOpacity(pageWidth: CGFloat) -> some View {
        modifier(EffectPagerOpacityModifier(pageWidth: pageWidth))
    }

    func workspaceHeaderAccessoryFrame() -> some View {
        self
            .frame(width: 16, height: 16)
            .offset(x: 7)
            .frame(width: 36, height: 32)
    }
}

private struct EffectKeyframeButton: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?
    let effectID: UUID?
    let isEnabled: Bool

    var body: some View {
        Button {
            guard let effectID else { return }
            viewModel.toggleEffectKeyframe(effectID)
            EditorHaptics.tap()
        } label: {
            KeyframeDiamondShape()
                .fill(isCurrent ? MotionaryTheme.accent : Color.clear)
                .overlay {
                    KeyframeDiamondShape()
                        .stroke(
                            hasAny ? MotionaryTheme.accent : MotionaryTheme.textSecondary,
                            lineWidth: 1.6
                        )
                }
                .workspaceHeaderAccessoryFrame()
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
        .opacity(canEdit ? 1 : 0.3)
        .accessibilityLabel("Effect keyframe")
        .accessibilityValue(isCurrent ? "At playhead" : (hasAny ? "Active" : "Inactive"))
    }

    private var canEdit: Bool {
        isEnabled
            && selectedEffect.map { EffectRegistry.shared.availability(of: $0) == .available }
                == true
    }

    private var selectedEffect: EffectInstance? {
        guard let effectID else { return nil }
        return clip?.effectStack.effects.first { $0.id == effectID }
    }

    private var localTime: Double {
        guard let clip else { return 0 }
        return viewModel.currentTime - clip.timelineStart
    }

    private var hasAny: Bool {
        !effectKeyframeTimes.isEmpty
    }

    private var isCurrent: Bool {
        let time = snappedLocalTime
        return effectKeyframeTimes.contains {
            abs($0 - time) <= viewModel.keyframeTimeTolerance
        }
    }

    private var snappedLocalTime: Double {
        guard let clip else { return localTime }
        return viewModel.snappedKeyframeTime(localTime, clip: clip)
    }

    private var effectKeyframeTimes: [Double] {
        guard let selectedEffect else { return [] }
        return KeyframeMergeSupport.mergedTimes([
            selectedEffect.mix.keyframes.map(\.time),
            selectedEffect.parameters.values.flatMap { $0.keyframes.map(\.time) }
        ])
    }
}

private struct EffectDetailWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip
    let effect: EffectInstance
    let isEnabled: Bool
    let onBack: () -> Void

    private var isAvailable: Bool {
        EffectRegistry.shared.availability(of: effect) == .available
    }

    private var displayName: String {
        isAvailable
            ? (EffectRegistry.shared.descriptor(for: effect.moduleID)?.name ?? "Effect")
            : "Unavailable Effect"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Button {
                    onBack()
                    EditorHaptics.tap()
                } label: {
                    Label(displayName, systemImage: "chevron.left")
                        .font(MotionaryDesign.Typography.workspaceHeader)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to effects")

                EffectKeyframeButton(
                    viewModel: viewModel,
                    clip: clip,
                    effectID: effect.id,
                    isEnabled: isEnabled
                )
            }
            .frame(height: 22)

            ScrollView {
                VStack(spacing: 12) {
                    if isAvailable {
                        ForEach(effect.parameterTargets) { target in
                            PropertyScrubber(
                                viewModel: viewModel,
                                clip: clip,
                                target: target,
                                isEnabled: isEnabled && effect.isEnabled
                            )
                        }
                    } else {
                        EditorWorkspaceMessage(
                            text: effect.moduleID.rawValue,
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(MotionaryDesign.Spacing.xl)
        .opacity(isEnabled ? 1 : 0.42)
        .motionaryGlass(cornerRadius: MotionaryDesign.Radius.panel)
        .onAppear {
            viewModel.activeKeyframeTarget = .effectMix(effect.id)
        }
    }
}

private struct EffectStackDisclosureRow: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip
    let effect: EffectInstance
    let index: Int
    let totalCount: Int
    let isEnabled: Bool
    let dragState: EffectListDragState?
    let dragTranslation: CGFloat
    let onToggleExpanded: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    private var descriptor: EffectModuleDescriptor? {
        EffectRegistry.shared.descriptor(for: effect.moduleID)
    }

    private var isAvailable: Bool {
        EffectRegistry.shared.availability(of: effect) == .available
    }

    private var displayName: String {
        isAvailable ? (descriptor?.name ?? "Effect") : "Unavailable Effect"
    }

    private var isDragging: Bool {
        dragState?.effectID == effect.id
    }

    private var rowDistance: CGFloat {
        EditorWorkspaceControlStyle.height + 12
    }

    private var rowOffset: CGFloat {
        guard let dragState else { return 0 }
        if dragState.effectID == effect.id {
            return dragTranslation
        }
        guard dragState.startIndex != dragState.targetIndex else { return 0 }
        if dragState.targetIndex > dragState.startIndex {
            return index > dragState.startIndex && index <= dragState.targetIndex ? -rowDistance : 0
        } else {
            return index >= dragState.targetIndex && index < dragState.startIndex ? rowDistance : 0
        }
    }

    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { gesture in
                guard isEnabled, totalCount > 1 else { return }
                onDragChanged(gesture.translation.height)
            }
            .onEnded { _ in
                guard isEnabled, totalCount > 1 else { return }
                onDragEnded()
            }
    }

    var body: some View {
        HStack(spacing: EditorWorkspaceControlStyle.horizontalSpacing) {
            Image(systemName: "line.3.horizontal")
                .font(MotionaryDesign.Typography.compactIcon)
                .foregroundStyle(MotionaryTheme.textSecondary)
                .frame(width: 28, height: EditorWorkspaceControlStyle.height)
                .contentShape(Rectangle())
                .gesture(reorderGesture)
                .accessibilityLabel("Reorder \(displayName)")

            Button(action: onToggleExpanded) {
                HStack(spacing: EditorWorkspaceControlStyle.horizontalSpacing) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName)
                            .font(MotionaryDesign.Typography.controlTitleStrong)
                            .foregroundStyle(MotionaryTheme.textPrimary)
                            .lineLimit(1)
                        if !isAvailable {
                            Text(effect.moduleID.rawValue)
                                .font(.caption2.monospaced())
                                .foregroundStyle(MotionaryTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            HStack(spacing: 6) {
                EditorWorkspaceIconButton(
                    systemName: effect.isEnabled ? "eye" : "eye.slash",
                    accessibilityLabel: effect.isEnabled ? "Hide effect" : "Show effect",
                    isEnabled: isEnabled
                ) {
                    viewModel.setEffectEnabled(effect.id, enabled: !effect.isEnabled)
                }

                EditorWorkspaceIconButton(
                    systemName: "trash",
                    accessibilityLabel: "Remove effect",
                    isEnabled: isEnabled,
                    role: .destructive
                ) {
                    viewModel.removeEffect(effect.id)
                }
            }
        }
        .padding(.horizontal, EditorWorkspaceControlStyle.horizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: EditorWorkspaceControlStyle.height)
        .background(
            EditorWorkspaceControlStyle.backgroundColor(isActive: isDragging),
            in: RoundedRectangle(
                cornerRadius: EditorWorkspaceControlStyle.cornerRadius,
                style: .continuous
            )
        )
        .offset(y: rowOffset)
        .zIndex(isDragging ? 10 : 0)
        .animation(isDragging ? nil : .snappy(duration: 0.18, extraBounce: 0), value: rowOffset)
    }
}

private struct EffectLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedModuleID: EffectModuleID
    let onConfirm: (EffectModuleID) -> Void

    @State private var query = ""
    @State private var selectedCategory: EffectCategory?

    private let columns = [
        GridItem(.adaptive(minimum: 126, maximum: 170), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Effect Library")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(MotionaryDesign.Typography.compactIcon)
                        .frame(width: 34, height: 34)
                        .background(MotionaryTheme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close effect library")

                Button {
                    onConfirm(selectedModuleID)
                } label: {
                    Label("Add", systemImage: "checkmark")
                        .font(MotionaryDesign.Typography.pillLabel)
                        .foregroundStyle(MotionaryTheme.foregroundOnAccent)
                        .frame(width: 78, height: 34)
                        .background(MotionaryTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            EffectSearchField(text: $query)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    EffectCategoryChip(
                        title: "All",
                        isSelected: selectedCategory == nil
                    ) {
                        selectedCategory = nil
                    }
                    ForEach(EffectCategory.allCases) { category in
                        EffectCategoryChip(
                            title: category.rawValue,
                            isSelected: selectedCategory == category
                        ) {
                            selectedCategory = category
                        }
                    }
                }
                .padding(.vertical, 1)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredModules) { module in
                        EffectLibraryTile(
                            module: module,
                            isSelected: selectedModuleID == module.id
                        ) {
                            selectedModuleID = module.id
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .padding(MotionaryDesign.Spacing.xl)
        .presentationDetents([.height(540), .large])
        .presentationDragIndicator(.visible)
    }

    private var filteredModules: [EffectModuleDescriptor] {
        EffectRegistry.shared.modules.filter { module in
            let matchesCategory = selectedCategory.map { module.category == $0 } ?? true
            let matchesQuery =
                query.isEmpty
                || module.name.localizedCaseInsensitiveContains(query)
                || module.summary.localizedCaseInsensitiveContains(query)
                || module.category.rawValue.localizedCaseInsensitiveContains(query)
            return matchesCategory && matchesQuery
        }
    }
}

private struct EffectSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(MotionaryDesign.Typography.compactIcon)
                .foregroundStyle(MotionaryTheme.textSecondary)
            TextField("Search effects", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(MotionaryDesign.Typography.compactIcon)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(MotionaryTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct EffectCategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MotionaryDesign.Typography.pillLabel)
                .foregroundStyle(isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    isSelected ? MotionaryTheme.accent : MotionaryTheme.surface,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

private struct EffectLibraryTile: View {
    let module: EffectModuleDescriptor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                EffectPreviewTileImage(moduleID: module.id, isSelected: isSelected)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(module.name)
                    .font(MotionaryDesign.Typography.pillLabel)
                    .foregroundStyle(MotionaryTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 30, alignment: .topLeading)
            }
            .padding(8)
            .background(
                isSelected ? MotionaryTheme.accent.opacity(0.22) : MotionaryTheme.surfaceSubtle,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? MotionaryTheme.accent : MotionaryTheme.separator, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(module.name)
    }
}

private struct EffectPreviewTileImage: View {
    let moduleID: EffectModuleID
    let isSelected: Bool

    @Environment(\.displayScale) private var displayScale
    @State private var renderedPreview: UIImage?
    @State private var originalPreview: UIImage?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                thumbnailLayer(renderedPreview)
                    .frame(width: size.width, height: size.height)
                    .clipped()

                if isSelected, originalPreview != nil, renderedPreview != nil {
                    TimelineView(.animation) { timeline in
                        let progress = splitProgress(at: timeline.date)
                        ZStack {
                            thumbnailLayer(originalPreview)
                                .frame(width: size.width, height: size.height)
                                .clipped()
                                .mask(alignment: .leading) {
                                    Rectangle()
                                        .frame(width: size.width * progress, height: size.height)
                                        .frame(width: size.width, height: size.height, alignment: .leading)
                                }

                            Rectangle()
                                .fill(.white.opacity(0.9))
                                .frame(width: 2, height: size.height)
                                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 0)
                                .position(x: size.width * progress, y: size.height * 0.5)
                        }
                        .frame(width: size.width, height: size.height)
                    }
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .background(.black)
        }
        .accessibilityIdentifier("effect-preview-\(moduleID.rawValue)")
        .task(id: moduleID) {
            let previews = await EffectThumbnailCache.shared.previews(
                for: moduleID,
                scale: displayScale
            )
            guard !Task.isCancelled else { return }
            originalPreview = previews.original
            renderedPreview = previews.rendered
        }
    }

    @ViewBuilder
    private func thumbnailLayer(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                Image("EffectsShowcase")
                    .resizable()
            }
        }
        .scaledToFill()
    }

    private func splitProgress(at date: Date) -> CGFloat {
        let seconds = date.timeIntervalSinceReferenceDate
        return CGFloat((sin(seconds * 1.35) + 1) * 0.5)
    }
}

private struct EffectThumbnailPair: @unchecked Sendable {
    let original: UIImage?
    let rendered: UIImage?
}

private actor EffectThumbnailCache {
    static let shared = EffectThumbnailCache()

    private struct Key: Hashable {
        let moduleID: EffectModuleID
        let scaleHundredths: Int
    }

    private var entries: [Key: EffectThumbnailPair] = [:]

    func previews(for moduleID: EffectModuleID, scale: CGFloat) -> EffectThumbnailPair {
        let key = Key(
            moduleID: moduleID,
            scaleHundredths: Int((max(scale, 1) * 100).rounded())
        )
        if let cached = entries[key] { return cached }
        let result = EffectThumbnailPair(
            original: EffectThumbnailRenderer.originalPreview(scale: scale),
            rendered: EffectThumbnailRenderer.preview(for: moduleID, scale: scale)
        )
        entries[key] = result
        return result
    }
}

struct PropertyWorkspaceShell<Content: View>: View {
    @ObservedObject var viewModel: EditorViewModel
    let clip: TimelineClip?
    let title: String
    let systemImage: String
    let section: KeyframeSection?
    @ViewBuilder let content: (TimelineClip, Bool) -> Content

    var body: some View {
        let isEnabled = clip.map(isWorkspaceEnabled) ?? false
        EditorWorkspaceShell(
            title: title,
            systemImage: systemImage,
            isEnabled: isEnabled,
            emptyState: clip == nil
                ? EditorWorkspaceEmptyState(title: "Select a clip", systemImage: "cursorarrow.click.2")
                : nil,
            accessory: {
                if let clip, let section {
                    SectionKeyframeButton(
                        viewModel: viewModel,
                        itemID: clip.id,
                        section: section,
                        isEnabled: isEnabled
                    )
                }
            },
            content: {
                if let clip {
                    content(clip, isEnabled)
                }
            }
        )
    }

    private func isWorkspaceEnabled(_ clip: TimelineClip) -> Bool {
        viewModel.selectedClipID == clip.id && isTimeInsideTimelineItem(clip)
    }

    private func isTimeInsideTimelineItem(_ clip: TimelineClip) -> Bool {
        guard let item = viewModel.project.item(id: clip.id) else {
            return viewModel.isTimeInside(clip)
        }
        return viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
    }
}

private struct PropertyScrubber: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    let clip: TimelineClip
    let target: KeyframeTarget
    let isEnabled: Bool

    @State private var rulerTickPosition: CGFloat?
    @State private var lastHapticBucket: Int?
    @State private var isDragging = false
    @State private var isScrubbing = false
    @State private var momentumTask: Task<Void, Never>?

    init(
        viewModel: EditorViewModel,
        clip: TimelineClip,
        target: KeyframeTarget,
        isEnabled: Bool = true
    ) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        self.clip = clip
        self.target = target
        self.isEnabled = isEnabled
    }

    var body: some View {
        let metadata = clip.keyframeMetadata(for: target)
        let value = displayedValue
        VStack {
            HStack(spacing: 8) {
                Label(metadata.title, systemImage: metadata.systemImage)
                    .font(MotionaryDesign.Typography.controlTitle)
                    .labelStyle(.titleOnly)
                    .frame(width: MotionaryDesign.Control.scrubberLabelWidth, alignment: .leading)
                    .lineLimit(1)

                Spacer()

                Text(formatted(value, metadata: metadata))
                    .font(MotionaryDesign.Typography.controlValue)
                    .frame(width: MotionaryDesign.Control.scrubberValueWidth, alignment: .trailing)
            }
            InfiniteScrubberTrack(
                tickPosition: rulerTickPosition
                    ?? tickPosition(for: value, metadata: metadata),
                isEditing: isScrubbing,
                maximumTickPosition: maximumTickPosition(metadata: metadata)
            )
            .contentShape(Rectangle())
            .overlay {
                HorizontalScrubInteraction(
                    onBegan: {
                        beginScrub(metadata: metadata)
                    },
                    onChanged: { delta in
                        updateScrub(
                            delta: delta,
                            metadata: metadata
                        )
                    },
                    onEnded: { velocity in
                        endScrub(
                            velocity: velocity,
                            metadata: metadata
                        )
                    }
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metadata.title)
            .accessibilityValue(formatted(value, metadata: metadata))
            .accessibilityHint("Swipe left to increase or right to decrease.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustValue(by: interactionStep(metadata: metadata), metadata: metadata)
                case .decrement:
                    adjustValue(by: -interactionStep(metadata: metadata), metadata: metadata)
                @unknown default:
                    break
                }
            }

        }
        .disabled(!isEnabled)
    }

    private var displayedValue: Double {
        if viewModel.selectedClipID == clip.id {
            return viewModel.displayedValue(for: target)
        }
        let time = viewModel.timelineLocalTime(for: clip)
        return clip.animatableProperty(for: target)?.value(at: time) ?? 0
    }

    private func beginScrub(metadata: KeyframePropertyMetadata) {
        momentumTask?.cancel()
        momentumTask = nil
        if isScrubbing {
            viewModel.finishInteractiveEdit()
        }
        let currentValue = displayedValue
        rulerTickPosition = tickPosition(
            for: currentValue,
            metadata: metadata
        )
        isDragging = true
        isScrubbing = true
        viewModel.activeKeyframeTarget = target
        viewModel.beginInteractiveEdit()
        EditorHaptics.scrubStart()
    }

    private func updateScrub(
        delta: CGFloat,
        metadata: KeyframePropertyMetadata
    ) {
        guard isDragging, let currentPosition = rulerTickPosition else { return }
        let position = boundedTickPosition(
            currentPosition - delta / InfiniteScrubberTrack.tickSpacing,
            metadata: metadata
        )
        rulerTickPosition = position
        let value = value(at: position, metadata: metadata)
        viewModel.setSelectedKeyframeValue(
            value,
            target: target,
            interactive: true
        )
        updateHaptic(for: value, metadata: metadata)
    }

    private func endScrub(
        velocity: CGFloat,
        metadata: KeyframePropertyMetadata
    ) {
        guard isDragging else { return }
        isDragging = false
        guard let position = rulerTickPosition else {
            finishScrubbing()
            return
        }
        startMomentum(
            distance: min(max(-velocity * 0.18, -480), 480),
            from: position,
            metadata: metadata
        )
    }

    private func startMomentum(
        distance: CGFloat,
        from startPosition: CGFloat,
        metadata: KeyframePropertyMetadata
    ) {
        guard abs(distance) >= 2 else {
            momentumTask = Task { @MainActor in
                await settleRulerAndFinish()
                momentumTask = nil
            }
            return
        }

        momentumTask = Task { @MainActor in
            var remaining = distance
            var position = startPosition

            while !Task.isCancelled, abs(remaining) >= 0.35 {
                let frameDistance = remaining * 0.12
                remaining *= 0.88
                let nextPosition = boundedTickPosition(
                    position + frameDistance / InfiniteScrubberTrack.tickSpacing,
                    metadata: metadata
                )
                guard abs(nextPosition - position) > 0.0001 else { break }
                position = nextPosition
                rulerTickPosition = position
                let value = value(at: position, metadata: metadata)
                viewModel.setSelectedKeyframeValue(
                    value,
                    target: target,
                    interactive: true
                )
                updateHaptic(for: value, metadata: metadata)
                try? await Task.sleep(for: .milliseconds(16))
            }

            guard !Task.isCancelled else { return }
            await settleRulerAndFinish()
            guard !Task.isCancelled else { return }
            momentumTask = nil
        }
    }

    @MainActor
    private func settleRulerAndFinish() async {
        guard rulerTickPosition != nil else {
            finishScrubbing()
            return
        }
        let metadata = clip.keyframeMetadata(for: target)
        let currentValue = displayedValue
        let snappedPosition = tickPosition(for: currentValue, metadata: metadata)
        withAnimation(.spring(duration: 0.22, bounce: 0.12)) {
            rulerTickPosition = snappedPosition
        }

        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        viewModel.setSelectedKeyframeValue(
            currentValue,
            target: target,
            interactive: true
        )
        finishScrubbing()
    }

    private func finishScrubbing() {
        rulerTickPosition = nil
        isScrubbing = false
        lastHapticBucket = nil
        viewModel.finishInteractiveEdit()
    }

    private func value(
        at position: CGFloat,
        metadata: KeyframePropertyMetadata
    ) -> Double {
        let rawValue: Double
        if target.isScaleTarget {
            rawValue =
                effectiveRange(metadata: metadata).lowerBound * pow(1.05, Double(position))
        } else {
            rawValue =
                effectiveRange(metadata: metadata).lowerBound
                + Double(position) * interactionStep(metadata: metadata)
        }
        return quantized(rawValue, metadata: metadata)
    }

    private func tickPosition(
        for value: Double,
        metadata: KeyframePropertyMetadata
    ) -> CGFloat {
        if target.isScaleTarget {
            let range = effectiveRange(metadata: metadata)
            return boundedTickPosition(
                CGFloat(
                    log(max(value, range.lowerBound) / range.lowerBound)
                        / log(1.05)
                ),
                metadata: metadata
            )
        }
        let range = effectiveRange(metadata: metadata)
        return boundedTickPosition(
            CGFloat((value - range.lowerBound) / interactionStep(metadata: metadata)),
            metadata: metadata
        )
    }

    private func maximumTickPosition(
        metadata: KeyframePropertyMetadata
    ) -> CGFloat {
        let range = effectiveRange(metadata: metadata)
        if target.isScaleTarget {
            return CGFloat(
                log(range.upperBound / range.lowerBound)
                    / log(1.05)
            )
        }
        return CGFloat(
            (range.upperBound - range.lowerBound) / interactionStep(metadata: metadata)
        )
    }

    private func boundedTickPosition(
        _ position: CGFloat,
        metadata: KeyframePropertyMetadata
    ) -> CGFloat {
        min(max(position, 0), maximumTickPosition(metadata: metadata))
    }

    private func adjustValue(by delta: Double, metadata: KeyframePropertyMetadata) {
        viewModel.activeKeyframeTarget = target
        let range = effectiveRange(metadata: metadata)
        let value = min(max(displayedValue + delta, range.lowerBound), range.upperBound)
        viewModel.setSelectedKeyframeValue(quantized(value, metadata: metadata), target: target)
        EditorHaptics.tap()
    }

    private func updateHaptic(for value: Double, metadata: KeyframePropertyMetadata) {
        let bucket: Int
        if target.isScaleTarget {
            bucket = Int((log(max(value, 0.01)) / log(1.05)).rounded())
        } else {
            bucket = Int((value / interactionStep(metadata: metadata)).rounded())
        }
        guard bucket != lastHapticBucket else { return }
        if lastHapticBucket != nil {
            EditorHaptics.selection()
        }
        lastHapticBucket = bucket
    }

    private func quantized(_ value: Double, metadata: KeyframePropertyMetadata) -> Double {
        let step = interactionStep(metadata: metadata)
        let range = effectiveRange(metadata: metadata)
        let stepped = (value / step).rounded() * step
        let bounded = min(max(stepped, range.lowerBound), range.upperBound)
        return bounded == 0 ? 0 : bounded
    }

    private func formatted(_ value: Double, metadata: KeyframePropertyMetadata) -> String {
        switch target {
        case .positionX:
            "\(Int(canvasUnitSpace.horizontalUnits(fromNormalizedPosition: value).rounded()))"
        case .positionY:
            "\(Int(canvasUnitSpace.verticalUnits(fromNormalizedPosition: value).rounded()))"
        case .shapeWidth, .shapeHeight, .shapeCornerRadius:
            "\(Int(canvasUnitSpace.units(fromPixels: value).rounded()))"
        case .rotation:
            "\(Int(value.rounded()))°"
        case .scale, .scaleX, .scaleY:
            "\(value.formatted(.number.precision(.fractionLength(2))))×"
        case .opacity, .effectMix, .volume:
            "\(Int((value * 100).rounded()))%"
        case .effectParameter(_, _, _) where metadata.range.lowerBound == 0 && metadata.range.upperBound == 1:
            "\(Int((value * 100).rounded()))%"
        default:
            metadata.formattedValue(value)
        }
    }

    private var canvasUnitSpace: EditorUnitSpace {
        EditorUnitSpace(size: viewModel.project.renderSettings.size)
    }

    private func interactionStep(metadata: KeyframePropertyMetadata) -> Double {
        switch target {
        case .positionX:
            canvasUnitSpace.normalizedHorizontalPosition(fromUnits: 1)
        case .positionY:
            canvasUnitSpace.normalizedVerticalPosition(fromUnits: 1)
        case .shapeWidth, .shapeHeight, .shapeCornerRadius:
            canvasUnitSpace.pixelsPerUnit
        default:
            metadata.step
        }
    }

    private func effectiveRange(metadata: KeyframePropertyMetadata) -> ClosedRange<Double> {
        switch target {
        case .positionX, .positionY, .shapeCornerRadius:
            viewModel.propertyRange(for: target, clip: clip)
        default:
            metadata.range
        }
    }
}

struct SectionKeyframeButton: View {
    @ObservedObject var viewModel: EditorViewModel
    let itemID: UUID
    let section: KeyframeSection
    let isEnabled: Bool

    var body: some View {
        let times = item?.keyframeTimes(in: section) ?? []
        let hasAny = !times.isEmpty
        let isSelectedItem = viewModel.selectedTimelineItemID == itemID
        let isCurrent =
            isSelectedItem
            && times.contains {
                abs((item?.timelineStart ?? 0) + $0 - viewModel.currentTime)
                    <= viewModel.keyframeTimeTolerance
            }

        Button {
            if let item, case .text = item {
                viewModel.toggleTextKeyframeSection(section)
            } else {
                viewModel.toggleKeyframeSection(section)
            }
            EditorHaptics.tap()
        } label: {
            KeyframeDiamondShape()
                .fill(isCurrent ? MotionaryTheme.accent : Color.clear)
                .overlay {
                    KeyframeDiamondShape()
                        .stroke(
                            hasAny ? MotionaryTheme.accent : MotionaryTheme.textSecondary,
                            lineWidth: 1.6
                        )
                }
                .workspaceHeaderAccessoryFrame()
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || availableTargetCount == 0)
        .opacity(availableTargetCount == 0 ? 0.3 : 1)
        .accessibilityLabel("\(section.rawValue) keyframe")
        .accessibilityValue(isCurrent ? "At playhead" : (hasAny ? "Active" : "Inactive"))
        .accessibilityHint(
            isCurrent ? "Removes the keyframe at the playhead." : "Adds a keyframe at the playhead."
        )
    }

    private var item: TimelineItem? {
        viewModel.project.item(id: itemID)
    }

    private var availableTargetCount: Int {
        guard let item else { return 0 }
        if let clip = item.legacyClip() {
            return clip.keyframeTargets(in: section).count
        }
        if case .text(let text) = item {
            return text.keyframeTargets(in: section).count
        }
        return 0
    }
}

struct EditorValueScrubber: View {
    let title: String
    let systemImage: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    var allowsUpperOverflow = false
    let format: (Double) -> String
    let onBegan: () -> Void
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    @State private var tickPosition: CGFloat?
    @State private var lastHapticBucket: Int?
    @State private var isDragging = false
    @State private var isEditing = false
    @State private var momentumTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(MotionaryDesign.Typography.controlTitle)
                    .labelStyle(.titleOnly)
                    .lineLimit(1)
                Spacer()
                Text(format(clamped(value)))
                    .font(MotionaryDesign.Typography.controlValue)
                    .foregroundStyle(MotionaryTheme.textSecondary)
            }

            InfiniteScrubberTrack(
                tickPosition: tickPosition ?? position(for: value),
                isEditing: isEditing,
                maximumTickPosition: maximumPosition
            )
            .contentShape(Rectangle())
            .overlay {
                HorizontalScrubInteraction(
                    onBegan: beginScrub,
                    onChanged: updateScrub,
                    onEnded: endScrub
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(format(clamped(value)))
            .accessibilityHint("Swipe left to increase or right to decrease.")
            .accessibilityAdjustableAction { direction in
                let delta: Double
                switch direction {
                case .increment: delta = safeStep
                case .decrement: delta = -safeStep
                @unknown default: return
                }
                onBegan()
                onChanged(quantized(value + delta))
                onEnded()
                EditorHaptics.tap()
            }
        }
        .disabled(maximumPosition.map { $0 <= 0 } ?? false)
        .onDisappear {
            momentumTask?.cancel()
            if isEditing { finishScrub() }
        }
    }

    private var safeStep: Double { max(abs(step), 0.000_001) }

    private var maximumPosition: CGFloat? {
        guard !allowsUpperOverflow else { return nil }
        return CGFloat(max((range.upperBound - range.lowerBound) / safeStep, 0))
    }

    private func position(for value: Double) -> CGFloat {
        boundedPosition(CGFloat((clamped(value) - range.lowerBound) / safeStep))
    }

    private func value(at position: CGFloat) -> Double {
        quantized(range.lowerBound + Double(position) * safeStep)
    }

    private func clamped(_ value: Double) -> Double {
        let lowerBounded = max(value, range.lowerBound)
        return allowsUpperOverflow ? lowerBounded : min(lowerBounded, range.upperBound)
    }

    private func quantized(_ value: Double) -> Double {
        let steps = ((value - range.lowerBound) / safeStep).rounded()
        let result = clamped(range.lowerBound + steps * safeStep)
        return result == 0 ? 0 : result
    }

    private func beginScrub() {
        momentumTask?.cancel()
        momentumTask = nil
        if isEditing { onEnded() }
        tickPosition = position(for: value)
        isDragging = true
        isEditing = true
        onBegan()
        EditorHaptics.scrubStart()
    }

    private func updateScrub(_ delta: CGFloat) {
        guard isDragging, let currentPosition = tickPosition else { return }
        let nextPosition = boundedPosition(
            currentPosition - delta / InfiniteScrubberTrack.tickSpacing
        )
        tickPosition = nextPosition
        publish(value(at: nextPosition))
    }

    private func endScrub(_ velocity: CGFloat) {
        guard isDragging else { return }
        isDragging = false
        guard let startPosition = tickPosition else {
            finishScrub()
            return
        }
        let distance = min(max(-velocity * 0.18, -480), 480)
        guard abs(distance) >= 2 else {
            finishScrub()
            return
        }

        momentumTask = Task { @MainActor in
            var remaining = distance
            var position = startPosition
            while !Task.isCancelled, abs(remaining) >= 0.35 {
                let frameDistance = remaining * 0.12
                remaining *= 0.88
                let nextPosition = boundedPosition(
                    position + frameDistance / InfiniteScrubberTrack.tickSpacing
                )
                guard abs(nextPosition - position) > 0.0001 else { break }
                position = nextPosition
                tickPosition = position
                publish(value(at: position))
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            finishScrub()
            momentumTask = nil
        }
    }

    private func publish(_ value: Double) {
        onChanged(value)
        let bucket = Int(((value - range.lowerBound) / safeStep).rounded())
        guard bucket != lastHapticBucket else { return }
        if lastHapticBucket != nil { EditorHaptics.selection() }
        lastHapticBucket = bucket
    }

    private func boundedPosition(_ position: CGFloat) -> CGFloat {
        let lowerBounded = max(position, 0)
        guard let maximumPosition else { return lowerBounded }
        return min(lowerBounded, maximumPosition)
    }

    private func finishScrub() {
        guard isEditing else { return }
        tickPosition = nil
        lastHapticBucket = nil
        isEditing = false
        onEnded()
    }
}

struct InfiniteScrubberTrack: View {
    static let tickSpacing = MotionaryDesign.Control.scrubberTickSpacing

    let tickPosition: CGFloat
    let isEditing: Bool
    let maximumTickPosition: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(
                    cornerRadius: EditorWorkspaceControlStyle.cornerRadius,
                    style: .continuous
                )
                    .fill(EditorWorkspaceControlStyle.backgroundColor(isActive: isEditing))

                Canvas { context, size in
                    let spacing = Self.tickSpacing

                    let halfVisibleTicks = Int(ceil((size.width * 0.5) / spacing))
                    let startIndex = max(0, Int(floor(tickPosition)) - halfVisibleTicks - 1)
                    let visibleEndIndex = Int(ceil(tickPosition)) + halfVisibleTicks + 1
                    let endIndex =
                        maximumTickPosition.map {
                            min(Int(ceil($0)), visibleEndIndex)
                        } ?? visibleEndIndex

                    if startIndex <= endIndex {
                        for index in startIndex...endIndex {
                            let indexPosition =
                                maximumTickPosition.map {
                                    min(CGFloat(index), $0)
                                } ?? CGFloat(index)
                            let x =
                                size.width * 0.5
                                + (indexPosition - tickPosition) * spacing
                            let isRoundNumber = index.isMultiple(of: 10)
                            let height: CGFloat = 8
                            let rect = CGRect(
                                x: x - 0.6,
                                y: (size.height - height) * 0.5,
                                width: 1.2,
                                height: height
                            )
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: 0.6),
                                with: .color(
                                    Color.primary.opacity(isRoundNumber ? 0.52 : 0.24)
                                )
                            )
                        }
                    }
                }
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.14),
                            .init(color: .white, location: 0.86),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                Capsule()
                    .fill(MotionaryTheme.accent)
                    .frame(width: isEditing ? 2.5 : 1.5, height: isEditing ? 24 : 9)
                    .shadow(
                        color: MotionaryTheme.accent.opacity(isEditing ? 0.5 : 0.15),
                        radius: isEditing ? 3 : 1
                    )

            }
        }
        .frame(minWidth: 72, maxWidth: .infinity)
        .frame(height: EditorWorkspaceControlStyle.height)
        .animation(.spring(duration: 0.24, bounce: 0.18), value: isEditing)
    }
}

struct HorizontalScrubInteraction: UIViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void

        init(
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat) -> Void
        ) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                onBegan()
                recognizer.setTranslation(.zero, in: view)
            case .changed:
                let delta = recognizer.translation(in: view).x
                onChanged(delta)
                recognizer.setTranslation(.zero, in: view)
            case .ended, .cancelled:
                let velocity = recognizer.velocity(in: view).x
                onEnded(velocity)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}

struct SelectedLayerMiniTimeline: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    @Binding var contextClipID: UUID?
    @Binding var pixelsPerSecond: CGFloat
    let activeSection: KeyframeSection?
    let activeEffectID: UUID?
    let graphSegment: KeyframeSegment?
    @State private var displayTime: Double = 0

    init(
        viewModel: EditorViewModel,
        contextClipID: Binding<UUID?>,
        pixelsPerSecond: Binding<CGFloat>,
        activeSection: KeyframeSection?,
        activeEffectID: UUID?,
        graphSegment: KeyframeSegment?
    ) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        _contextClipID = contextClipID
        _pixelsPerSecond = pixelsPerSecond
        self.activeSection = activeSection
        self.activeEffectID = activeEffectID
        self.graphSegment = graphSegment
    }

    var body: some View {
        GeometryReader { geometry in
            if let contextClipID,
                let track = viewModel.project.tracks.first(where: {
                    $0.items.contains { $0.id == contextClipID }
                })
            {
                let centerPadding = geometry.size.width * 0.5
                let contentWidth =
                    max(CGFloat(viewModel.duration) * pixelsPerSecond, 1)
                    + centerPadding * 2
                TimelineScrollContainer(
                    pixelsPerSecond: $pixelsPerSecond,
                    currentTime: displayTime,
                    duration: viewModel.duration,
                    maximumTimelineTime: viewModel.lastPlayableTime,
                    contentRevision: miniTimelineContentRevision,
                    contentSize: CGSize(width: contentWidth, height: geometry.size.height),
                    isScrollDisabled: false,
                    allowsVerticalScrolling: false,
                    onScrubStart: { viewModel.beginScrub() },
                    onScrubChanged: { time in
                        viewModel.updateScrub(to: time)
                    },
                    onScrubEnd: { time in
                        viewModel.endScrub(at: time)
                    },
                    onPullToAddChanged: { _ in },
                    onPullToAddEnded: { _ in }
                ) {
                    ZStack(alignment: .leading) {
                        Color.clear
                        ForEach(track.items) { item in
                            let width = max(CGFloat(item.placementDuration) * pixelsPerSecond, 6)
                            ZStack {
                                if item.id == contextClipID {
                                    RoundedRectangle(
                                        cornerRadius: MotionaryDesign.Radius.button,
                                        style: .continuous
                                    )
                                        .fill(MotionaryTheme.selected)
                                        .frame(width: width + 4, height: 42)
                                        .overlay {
                                            RoundedRectangle(
                                                cornerRadius: MotionaryDesign.Radius.button,
                                                style: .continuous
                                            )
                                                .stroke(MotionaryTheme.selected, lineWidth: 2)
                                        }
                                        .allowsHitTesting(false)
                                }

                                TimelineItemVisualFill(
                                    item: item,
                                    media: item.legacyClip().flatMap {
                                        viewModel.project.mediaDescriptor(for: $0)
                                    },
                                    mediaClip: item.legacyClip(),
                                    width: width,
                                    height: 38,
                                    pixelsPerSecond: pixelsPerSecond,
                                    sampleWidth: nil,
                                    sampleOffsetX: 0
                                )
                                .frame(width: width, height: 38)
                                .foregroundStyle(Color.black.opacity(0.88))
                                .background {
                                    RoundedRectangle(
                                        cornerRadius: MotionaryDesign.Radius.control,
                                        style: .continuous
                                    )
                                        .fill(timelineItemTint(for: item))
                                }
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: MotionaryDesign.Radius.control,
                                        style: .continuous
                                    )
                                )

                                MiniTimelineKeyframes(
                                    item: item,
                                    currentTime: viewModel.currentTime,
                                    tolerance: viewModel.keyframeTimeTolerance,
                                    width: width,
                                    activeSection: activeSection,
                                    activeEffectID: activeEffectID,
                                    graphSegment: graphSegment
                                )
                            }
                            .frame(width: width, height: 42)
                            .opacity(item.id == contextClipID ? 1 : 0.22)
                            .offset(x: centerPadding + CGFloat(item.timelineStart) * pixelsPerSecond)
                        }
                    }
                    .frame(width: contentWidth, height: geometry.size.height, alignment: .leading)
                }
                .overlay {
                    Rectangle()
                        .fill(MotionaryTheme.selected)
                        .frame(width: 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MotionaryDesign.Radius.compactPanel, style: .continuous))
        .motionaryGlass(cornerRadius: MotionaryDesign.Radius.compactPanel)
        .background {
            TimelineDisplayLink(
                player: viewModel.player,
                isPlaying: viewModel.isPlaying
            ) { time in
                displayTime = min(max(time, 0), max(viewModel.duration, 0))
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            displayTime = viewModel.currentTime
        }
        .onChange(of: playbackState.currentTime) { _, time in
            guard !viewModel.isPlaying else { return }
            displayTime = time
        }
    }

    private var miniTimelineContentRevision: Int {
        let frameRate = Double(max(viewModel.project.renderSettings.frameRate, 1))
        let playheadFrame =
            viewModel.isPlaying
            ? 0
            : Int((viewModel.currentTime * frameRate).rounded())
        let sectionValue: Int
        switch activeSection {
        case .shape: sectionValue = 1
        case .transform: sectionValue = 2
        case .adjust: sectionValue = 3
        case .effects: sectionValue = 4
        case .audio: sectionValue = 5
        case .speed: sectionValue = 6
        case .textType: sectionValue = 7
        case .textStyle: sectionValue = 8
        case nil: sectionValue = 0
        }
        let graphValue: Int
        if let graphSegment {
            graphValue =
                Int((graphSegment.startTime * frameRate).rounded()) &* 31
                &+ Int((graphSegment.endTime * frameRate).rounded()) &* 131
                &+ sectionValue &* 521
                &+ (graphSegment.effectID?.hashValue ?? 0)
        } else {
            graphValue = 0
        }
        return viewModel.timelineContentRevision &* 10_007
            &+ playheadFrame &* 101
            &+ sectionValue &* 1_009
            &+ (activeEffectID?.hashValue ?? 0)
            &+ graphValue
    }
}

private struct MiniTimelineKeyframes: View {
    let item: TimelineItem
    let currentTime: Double
    let tolerance: Double
    let width: CGFloat
    let activeSection: KeyframeSection?
    let activeEffectID: UUID?
    let graphSegment: KeyframeSegment?

    var body: some View {
        ZStack {
            if let graphSegment, graphSegment.clipID == item.id {
                graphSegmentIndicator(graphSegment)
            }

            ForEach(KeyframeSection.allCases) { section in
                ForEach(keyframeTimes(in: section), id: \.self) { time in
                    marker(time: time, section: section)
                }
            }
        }
        .frame(width: width, height: 38)
    }

    @ViewBuilder
    private func marker(time: Double, section: KeyframeSection) -> some View {
        let isActiveSection = section == activeSection
        let isCurrent =
            isActiveSection
            && abs((item.timelineStart + time) - currentTime) <= tolerance
        let isGraphEndpoint =
            graphSegment?.clipID == item.id
            && graphSegment?.section == section
            && (abs((graphSegment?.startTime ?? -.infinity) - time) <= tolerance
                || abs((graphSegment?.endTime ?? -.infinity) - time) <= tolerance)
        let size: CGFloat = isActiveSection ? 12 : 9
        KeyframeDiamondShape()
            .fill(isCurrent || isGraphEndpoint ? MotionaryTheme.control : Color.clear)
            .overlay {
                KeyframeDiamondShape()
                    .stroke(
                        isActiveSection ? MotionaryTheme.control : MotionaryTheme.control.opacity(0.72),
                        lineWidth: isActiveSection ? 1.5 : 1.2
                    )
            }
            .frame(width: size, height: size)
            .position(x: markerX(for: time), y: 19)
            .zIndex(isActiveSection ? 2 : 1)
    }

    private func graphSegmentIndicator(_ segment: KeyframeSegment) -> some View {
        let startX = markerX(for: segment.startTime)
        let endX = markerX(for: segment.endTime)
        return Capsule()
            .fill(MotionaryTheme.accent.opacity(0.9))
            .frame(width: max(endX - startX, 2), height: 2)
            .position(x: (startX + endX) * 0.5, y: 19)
            .shadow(color: MotionaryTheme.accent.opacity(0.55), radius: 2)
            .zIndex(0)
    }

    private func markerX(for time: Double) -> CGFloat {
        min(
            max(CGFloat(time / max(item.placementDuration, 0.001)) * width, 7),
            max(width - 7, 7)
        )
    }

    private func keyframeTimes(in section: KeyframeSection) -> [Double] {
        if section == .effects {
            return item.keyframeTimes(in: section, effectID: activeEffectID)
        }
        return item.keyframeTimes(in: section)
    }
}
