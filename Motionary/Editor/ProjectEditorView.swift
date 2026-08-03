// Root editor screen that composes preview, timeline, controls, and application state.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum CoreEditorPanel: Equatable {
    case timeline
    case text
    case textType
    case textStyle
    case textMotion
    case textMotionGraph
    case shape
    case transform
    case adjust
    case effects
    case audio
    case speed
    case mask
    case removeBackground
    case blend
    case autoBeats
    case canvas
    case graph
}

/// Composes the preview, timeline, inspectors, toolbar, import flow, and export flow for one project.
struct ProjectEditorView: View {
    let projectID: UUID
    @ObservedObject var projectStore: ProjectStore
    let initialContent: ProjectContent
    let onClose: () -> Void

    @StateObject private var viewModel: EditorViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedMediaItems: [PhotosPickerItem] = []
    @State private var selectedReplacementItem: PhotosPickerItem?
    @State private var selectedAudioVideoItem: PhotosPickerItem?
    @State private var isAudioVideoPickerPresented = false
    @State private var isAudioFileImporterPresented = false
    @State private var isExportSettingsPresented = false
    @State private var activePanel: CoreEditorPanel = .timeline
    @State private var pixelsPerSecond: CGFloat = 88
    @State private var miniTimelinePixelsPerSecond: CGFloat = 88
    @State private var propertyContextClipID: UUID?
    @State private var graphReturnPanel: CoreEditorPanel = .transform
    @State private var activeEffectWorkspaceID: UUID?
    @State private var activeTextMotionPhase: TextAnimationPhase = .entrance
    @State private var cancelTaskConfirmationLocation: CGPoint?
    @State private var isTextKeyboardVisible = false

    init(
        projectID: UUID,
        projectStore: ProjectStore,
        initialContent: ProjectContent,
        onClose: @escaping () -> Void = {}
    ) {
        self.projectID = projectID
        self.projectStore = projectStore
        self.initialContent = initialContent
        self.onClose = onClose
        _viewModel = StateObject(
            wrappedValue: EditorViewModel(
                projectID: projectID,
                projectStore: projectStore,
                initialContent: initialContent
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            editorCanvas(geometry: geometry)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(viewModel.project.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    EditorHaptics.tap()
                    isExportSettingsPresented = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(!viewModel.canExportVideo || viewModel.isPerformingLongTask)
                .accessibilityLabel("Export")
                .accessibilityIdentifier("motionary-editor-export")
                .labelStyle(.titleAndIcon)
            }
        }
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .onChange(of: selectedMediaItems) { _, items in
            guard !items.isEmpty else { return }
            viewModel.importPhotosItems(items)
            DispatchQueue.main.async {
                selectedMediaItems = []
            }
        }
        .onChange(of: selectedAudioVideoItem) { _, item in
            guard let item else { return }
            viewModel.importAudioFromPhotosItem(item)
            DispatchQueue.main.async {
                selectedAudioVideoItem = nil
            }
        }
        .onChange(of: selectedReplacementItem) { _, item in
            guard let item else { return }
            viewModel.replaceSelectedMedia(with: item)
            DispatchQueue.main.async {
                selectedReplacementItem = nil
            }
        }
        .onChange(of: viewModel.selectedClipID) { _, clipID in
            DispatchQueue.main.async {
                activeEffectWorkspaceID = nil
                if let clipID {
                    if activePanel.isPropertyPanel || activePanel == .graph {
                        propertyContextClipID = clipID
                        if activePanel == .graph,
                            let section = graphReturnPanel.keyframeSection
                        {
                            viewModel.selectGraphSegment(atPlayheadIn: section)
                        }
                    }

                    if let clip = viewModel.project.clip(id: clipID) {
                        let panelToCheck = activePanel == .graph ? graphReturnPanel : activePanel
                        var isSupported = true
                        switch panelToCheck {
                        case .text, .textType, .textStyle, .textMotion, .textMotionGraph:
                            isSupported = false
                        case .shape:
                            isSupported = clip.shape != nil
                        case .transform, .adjust, .effects:
                            isSupported = clip.mediaType != .audio
                        case .audio:
                            isSupported = clip.mediaType == .audio || clip.mediaType == .video
                        case .speed:
                            if case .media(let media) = viewModel.project.item(id: clipID) {
                                isSupported = media.mediaType == .video || media.mediaType == .audio
                            } else {
                                isSupported = false
                            }
                        case .mask:
                            isSupported = clip.mediaType != .audio
                        case .removeBackground:
                            isSupported = clip.mediaType == .image || clip.mediaType == .video
                        case .blend:
                            isSupported = clip.mediaType != .audio
                        case .autoBeats:
                            isSupported = clip.mediaType == .audio
                        default:
                            isSupported = true
                        }
                        if !isSupported {
                            activePanel = .timeline
                        }
                    } else if case .adjustment = viewModel.project.item(id: clipID) {
                        let panelToCheck = activePanel == .graph ? graphReturnPanel : activePanel
                        switch panelToCheck {
                        case .timeline, .transform, .adjust, .effects, .mask, .blend:
                            break
                        default:
                            activePanel = .timeline
                        }
                    } else if case .text = viewModel.project.item(id: clipID) {
                        let panelToCheck = activePanel == .graph ? graphReturnPanel : activePanel
                        if !panelToCheck.isTextPanel
                            && panelToCheck != .transform
                            && panelToCheck != .mask
                            && panelToCheck != .blend
                            && panelToCheck != .timeline
                        {
                            activePanel = .timeline
                        }
                    }
                } else if activePanel != .canvas {
                    activePanel = .timeline
                }
            }
        }
        .onChange(of: activePanel) { previousPanel, panel in
            DispatchQueue.main.async {
                if previousPanel == .graph, panel != .graph {
                    viewModel.graphSegment = nil
                    viewModel.displayedGraphSegment = nil
                    viewModel.activeKeyframeTarget = nil
                    viewModel.selectedKeyframeID = nil
                }
                if previousPanel.isPropertyPanel, panel == .timeline {
                    propertyContextClipID = nil
                    viewModel.activeKeyframeTarget = nil
                }
                if panel != .effects && panel != .graph {
                    activeEffectWorkspaceID = nil
                }
            }
        }
        .onChange(of: viewModel.project) { _, project in
            if let contextID = propertyContextClipID,
                project.item(id: contextID) == nil
            {
                DispatchQueue.main.async {
                    propertyContextClipID = nil
                    activeEffectWorkspaceID = nil
                    viewModel.graphSegment = nil
                    viewModel.displayedGraphSegment = nil
                    activePanel = .timeline
                }
            } else if let activeEffectWorkspaceID,
                project.item(id: propertyContextClipID ?? UUID())?
                    .visualEditingClip()?
                    .effectStack.effects.contains(where: { $0.id == activeEffectWorkspaceID }) != true
            {
                DispatchQueue.main.async {
                    self.activeEffectWorkspaceID = nil
                }
            } else if activePanel == .graph {
                DispatchQueue.main.async {
                    viewModel.refreshGraphSegment()
                }
            }
        }
        .onReceive(viewModel.playbackState.$currentTime) { _ in
            guard activePanel == .graph,
                let section = graphReturnPanel.keyframeSection
            else { return }
            DispatchQueue.main.async {
                viewModel.selectGraphSegment(
                    atPlayheadIn: section,
                    effectID: graphReturnPanel == .effects ? activeEffectWorkspaceID : nil
                )
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .fileImporter(
            isPresented: $isAudioFileImporterPresented,
            allowedContentTypes: [.audio]
        ) { result in
            switch result {
            case .success(let url):
                viewModel.importAudio(url: url)
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .photosPicker(
            isPresented: $isAudioVideoPickerPresented,
            selection: $selectedAudioVideoItem,
            matching: .videos
        )
        .sheet(isPresented: $isExportSettingsPresented) {
            ExportSettingsView(project: viewModel.project) { settings in
                isExportSettingsPresented = false
                viewModel.exportProject(settings: settings)
            }
        }
    }

    private func editorCanvas(geometry: GeometryProxy) -> some View {
        let availableHeight = max(geometry.size.height - geometry.safeAreaInsets.bottom - 12, 1)
        let activeKeyframeSection = activeTimelineKeyframeSection
        let showsMiniTimeline =
            (activePanel.keyframeSection != nil || activePanel == .graph)
            && propertyContextTimelineItem != nil
        let miniTimelineHeight: CGFloat = showsMiniTimeline ? 52 : 0
        let controlHeight: CGFloat = 42
        let previewRatio: CGFloat
        switch activePanel {
        case .timeline:
            previewRatio = 0.44
        default:
            previewRatio = 0.31
        }
        let previewHeight = availableHeight * previewRatio
        return ZStack {
            MotionaryTheme.background(for: colorScheme).ignoresSafeArea()

            VStack(spacing: 10) {
                if !isTextKeyboardVisible {
                    CorePreviewSection(
                        viewModel: viewModel,
                        selectedMediaItems: $selectedMediaItems
                    )
                    .frame(height: previewHeight)

                    EditorPlaybackControlBar(
                        viewModel: viewModel,
                        activePanel: $activePanel,
                        graphReturnPanel: $graphReturnPanel,
                        activeEffectWorkspaceID: $activeEffectWorkspaceID,
                        activeTextMotionPhase: $activeTextMotionPhase
                    )
                    .frame(height: controlHeight)
                }

                workspace
                    .frame(maxWidth: .infinity)

                if showsMiniTimeline {
                    SelectedLayerMiniTimeline(
                        viewModel: viewModel,
                        contextClipID: $propertyContextClipID,
                        pixelsPerSecond: $miniTimelinePixelsPerSecond,
                        activeSection: activePanel == .graph
                            ? graphReturnPanel.keyframeSection
                            : activeKeyframeSection,
                        activeEffectID: activePanel == .graph && graphReturnPanel == .effects
                            ? viewModel.graphSegment?.effectID
                            : activeEffectWorkspaceID,
                        graphSegment: activePanel == .graph
                            ? viewModel.graphSegment
                            : nil
                    )
                    .frame(height: miniTimelineHeight)
                }

                CoreToolBar(
                    viewModel: viewModel,
                    selectedMediaItems: $selectedMediaItems,
                    selectedReplacementItem: $selectedReplacementItem,
                    isAudioVideoPickerPresented: $isAudioVideoPickerPresented,
                    isAudioFileImporterPresented: $isAudioFileImporterPresented,
                    activePanel: $activePanel,
                    propertyContextClipID: $propertyContextClipID,
                    graphReturnPanel: $graphReturnPanel,
                    activeEffectWorkspaceID: $activeEffectWorkspaceID
                )
            }
            .padding()

            EditorBusyOverlay(viewModel: viewModel) { location in
                cancelTaskConfirmationLocation = location
            }

            if let location = cancelTaskConfirmationLocation,
                viewModel.shouldPresentBusyOverlay
            {
                EditorCancelTaskPopover(
                    title: "Stop the current task?",
                    message: "The current import, analysis, export, or preview preparation will be cancelled.",
                    onConfirm: {
                        cancelTaskConfirmationLocation = nil
                        viewModel.cancelLongRunningTask()
                    },
                    onDismiss: {
                        cancelTaskConfirmationLocation = nil
                    }
                )
                .position(cancelPopoverPosition(for: location, in: geometry.size))
                .transition(.scale(scale: 0.94).combined(with: .opacity))
                .zIndex(1_500)
            }

            if let message = viewModel.confirmationMessage {
                MotionaryConfirmationToast(message: message)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(500)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: viewModel.confirmationMessage)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: cancelTaskConfirmationLocation)
        .onChange(of: viewModel.shouldPresentBusyOverlay) { _, isBusy in
            if !isBusy {
                DispatchQueue.main.async {
                    cancelTaskConfirmationLocation = nil
                }
            }
        }
    }

    private func cancelPopoverPosition(for location: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(location.x, 132), max(size.width - 132, 132)),
            y: min(max(location.y, 92), max(size.height - 92, 92))
        )
    }

    @ViewBuilder
    private var workspace: some View {
        switch activePanel {
        case .timeline:
            CoreTimelineView(
                viewModel: viewModel,
                pixelsPerSecond: $pixelsPerSecond
            )
        case .text:
            TextWorkspaceView(
                viewModel: viewModel,
                item: propertyContextText,
                mode: .content,
                activeMotionPhase: $activeTextMotionPhase,
                isKeyboardVisible: $isTextKeyboardVisible
            )
        case .textType:
            TextWorkspaceView(
                viewModel: viewModel,
                item: propertyContextText,
                mode: .type,
                activeMotionPhase: $activeTextMotionPhase,
                isKeyboardVisible: $isTextKeyboardVisible
            )
        case .textStyle:
            TextWorkspaceView(
                viewModel: viewModel,
                item: propertyContextText,
                mode: .style,
                activeMotionPhase: $activeTextMotionPhase,
                isKeyboardVisible: $isTextKeyboardVisible
            )
        case .textMotion:
            TextWorkspaceView(
                viewModel: viewModel,
                item: propertyContextText,
                mode: .motion,
                activeMotionPhase: $activeTextMotionPhase,
                isKeyboardVisible: $isTextKeyboardVisible
            )
        case .textMotionGraph:
            TextMotionGraphWorkspace(
                viewModel: viewModel,
                item: propertyContextText,
                phase: activeTextMotionPhase
            )
        case .shape:
            ShapeWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip
            )
        case .transform:
            TransformWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip,
                text: propertyContextText
            )
        case .adjust:
            AdjustWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip
            )
        case .effects:
            EffectsWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip,
                activeEffectID: $activeEffectWorkspaceID
            )
        case .audio:
            AudioWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip
            )
        case .speed:
            SpeedWorkspaceView(
                viewModel: viewModel,
                item: propertyContextTimelineItem
            )
        case .mask:
            MaskWorkspaceView(
                viewModel: viewModel,
                item: propertyContextTimelineItem
            )
        case .removeBackground:
            RemoveBackgroundWorkspaceView(
                viewModel: viewModel,
                item: propertyContextTimelineItem
            )
        case .blend:
            BlendWorkspaceView(
                viewModel: viewModel,
                item: propertyContextTimelineItem
            )
        case .autoBeats:
            AutoBeatsWorkspaceView(
                viewModel: viewModel,
                item: propertyContextTimelineItem
            )
        case .canvas:
            CanvasWorkspaceView(viewModel: viewModel)
        case .graph:
            KeyframeWorkspaceView(viewModel: viewModel)
        }
    }

    private var propertyContextClip: TimelineClip? {
        guard let propertyContextClipID else { return nil }
        return viewModel.project.item(id: propertyContextClipID)?.visualEditingClip()
    }

    private var propertyContextText: TextTimelineItem? {
        guard let propertyContextClipID,
            case .text(let item) = viewModel.project.item(id: propertyContextClipID)
        else { return nil }
        return item
    }

    private var propertyContextTimelineItem: TimelineItem? {
        guard let propertyContextClipID else { return nil }
        return viewModel.project.item(id: propertyContextClipID)
    }

    private var activeTimelineKeyframeSection: KeyframeSection? {
        if activePanel == .effects && activeEffectWorkspaceID == nil {
            return nil
        }
        return activePanel.keyframeSection
    }

    @ViewBuilder
    private var saveStateLabel: some View {
        switch viewModel.projectSession.saveState {
        case .idle:
            EmptyView()
        case .saving:
            Label("Saving", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(MotionaryTheme.textSecondary)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(MotionaryTheme.textSecondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }
}

private struct EditorPlaybackControlBar: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    @Binding var activePanel: CoreEditorPanel
    @Binding var graphReturnPanel: CoreEditorPanel
    @Binding var activeEffectWorkspaceID: UUID?
    @Binding var activeTextMotionPhase: TextAnimationPhase
    @State private var isTimePadPresented = false

    init(
        viewModel: EditorViewModel,
        activePanel: Binding<CoreEditorPanel>,
        graphReturnPanel: Binding<CoreEditorPanel>,
        activeEffectWorkspaceID: Binding<UUID?>,
        activeTextMotionPhase: Binding<TextAnimationPhase>
    ) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        _activePanel = activePanel
        _graphReturnPanel = graphReturnPanel
        _activeEffectWorkspaceID = activeEffectWorkspaceID
        _activeTextMotionPhase = activeTextMotionPhase
    }

    var body: some View {
        ZStack {
            HStack(spacing: 9) {
                MotionaryNumberPadPopover(isPresented: $isTimePadPresented) { value in
                    viewModel.seek(to: min(value, viewModel.duration), exact: true)
                } label: {
                    Text("\(formatClock(playbackState.currentTime)) / \(formatClock(viewModel.duration))")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .lineLimit(1)
                }
                .accessibilityHint("Open number pad")
                Spacer()

                if activePanel == .textMotionGraph {
                    CompactIconButton(
                        systemName: "xmark",
                        title: "Close motion graph",
                        isProminent: true,
                        action: { activePanel = .textMotion },
                        isBordered: false
                    )
                } else if activePanel == .graph {
                    CompactIconButton(
                        systemName: "xmark",
                        title: "Close graphs",
                        isProminent: true,
                        action: {
                            viewModel.graphSegment = nil
                            activePanel = graphReturnPanel
                        },
                        isBordered: false
                    )
                } else if activePanel == .textMotion,
                    hasSelectedTextMotion
                {
                    CompactIconButton(
                        systemName: "point.topleft.down.curvedto.point.bottomright.up",
                        title: "Edit \(activeTextMotionPhase.shortTitle) graph",
                        isProminent: true,
                        action: { activePanel = .textMotionGraph },
                        isBordered: false
                    )
                } else if let section = activeGraphSection,
                    viewModel.candidateGraphSegment(in: section, effectID: activeEffectWorkspaceID) != nil
                {
                    CompactIconButton(
                        systemName: "point.topleft.down.curvedto.point.bottomright.up",
                        title: "Graph",
                        isProminent: true,
                        action: {
                            graphReturnPanel = activePanel
                            viewModel.openCandidateGraphSegment(
                                in: section,
                                effectID: activeEffectWorkspaceID
                            )
                            if viewModel.graphSegment != nil {
                                activePanel = .graph
                            }
                        },
                        isBordered: false
                    )
                } else if activePanel == .timeline {
                    CompactIconButton(
                        systemName: "link",
                        title: viewModel.isRippleEditingEnabled
                            ? "Disable ripple editing"
                            : "Enable ripple editing",
                        isProminent: viewModel.isRippleEditingEnabled,
                        action: {
                            viewModel.isRippleEditingEnabled.toggle()
                        },
                        isBordered: false,
                        tintsProminentIcon: true
                    )
                }
                CompactIconButton(
                    systemName: "arrow.uturn.backward",
                    title: "Undo",
                    isDisabled: !viewModel.canUndo,
                    action: { viewModel.undo() },
                    isBordered: false
                )
                CompactIconButton(
                    systemName: "arrow.uturn.forward",
                    title: "Redo",
                    isDisabled: !viewModel.canRedo,
                    action: { viewModel.redo() },
                    isBordered: false
                )
            }
            .padding(.horizontal, 5)

            HStack(spacing: 18) {
                CompactIconButton(
                    systemName: "backward.end.fill",
                    title: "Previous edit point",
                    isDisabled: !viewModel.canNavigateBackward,
                    action: {
                        viewModel.navigateBackward()
                    },
                    isBordered: false
                )
                CompactIconButton(
                    systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                    title: viewModel.isPlaying ? "Pause" : "Play",
                    isProminent: true,
                    isDisabled: viewModel.player == nil
                ) {
                    if activePanel == .graph {
                        viewModel.toggleGraphPlayback()
                    } else {
                        viewModel.togglePlayback()
                    }
                }
                CompactIconButton(
                    systemName: "forward.end.fill",
                    title: "Next edit point",
                    isDisabled: !viewModel.canNavigateForward,
                    action: {
                        viewModel.navigateForward()
                    },
                    isBordered: false
                )
            }
        }
    }

    private var hasSelectedTextMotion: Bool {
        guard let item = viewModel.selectedTextItem else { return false }
        return switch activeTextMotionPhase {
        case .entrance:
            item.animations.entrance != nil
        case .loop:
            item.animations.loop != nil
        case .exit:
            item.animations.exit != nil
        }
    }

    private var activeGraphSection: KeyframeSection? {
        if activePanel == .effects && activeEffectWorkspaceID == nil {
            return nil
        }
        return activePanel.keyframeSection
    }

}

extension CoreEditorPanel {
    var isPropertyPanel: Bool {
        isTextPanel || self == .shape || self == .transform || self == .adjust || self == .effects
            || self == .audio || self == .speed || self == .mask || self == .removeBackground
            || self == .blend || self == .autoBeats
    }

    var isTextPanel: Bool {
        switch self {
        case .text, .textType, .textStyle, .textMotion, .textMotionGraph:
            true
        default:
            false
        }
    }

    var keyframeSection: KeyframeSection? {
        switch self {
        case .text, .textMotion, .textMotionGraph:
            nil
        case .textType:
            .textType
        case .textStyle:
            .textStyle
        case .shape:
            .shape
        case .transform:
            .transform
        case .adjust:
            .adjust
        case .effects:
            .effects
        case .audio:
            .audio
        case .speed:
            nil
        case .mask, .removeBackground, .blend, .autoBeats, .canvas, .timeline, .graph:
            nil
        }
    }
}
