// Root editor screen that composes preview, timeline, controls, and application state.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum CoreEditorPanel: Equatable {
    case timeline
    case shape
    case transform
    case adjust
    case effects
    case audio
    case graph
}

/// Composes the preview, timeline, inspectors, toolbar, import flow, and export flow for one project.
struct ProjectEditorView: View {
    let projectID: UUID
    @ObservedObject var projectStore: ProjectStore
    let initialContent: ProjectContent

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
    @State private var isCancelTaskConfirmationPresented = false

    init(projectID: UUID, projectStore: ProjectStore, initialContent: ProjectContent) {
        self.projectID = projectID
        self.projectStore = projectStore
        self.initialContent = initialContent
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
        .navigationBarBackButtonHidden(viewModel.isPerformingLongTask)
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
            selectedMediaItems = []
        }
        .onChange(of: selectedAudioVideoItem) { _, item in
            guard let item else { return }
            viewModel.importAudioFromPhotosItem(item)
            selectedAudioVideoItem = nil
        }
        .onChange(of: selectedReplacementItem) { _, item in
            guard let item else { return }
            viewModel.replaceSelectedMedia(with: item)
            selectedReplacementItem = nil
        }
        .onChange(of: viewModel.selectedClipID) { _, clipID in
            if let clipID, activePanel.isPropertyPanel || activePanel == .graph {
                propertyContextClipID = clipID
                if activePanel == .graph,
                    let section = graphReturnPanel.keyframeSection
                {
                    viewModel.selectGraphSegment(atPlayheadIn: section)
                }
            }
        }
        .onChange(of: activePanel) { previousPanel, panel in
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
        }
        .onChange(of: viewModel.project) { _, project in
            if let contextID = propertyContextClipID,
                project.clip(id: contextID) == nil
            {
                propertyContextClipID = nil
                viewModel.graphSegment = nil
                viewModel.displayedGraphSegment = nil
                activePanel = .timeline
            } else if activePanel == .graph {
                viewModel.refreshGraphSegment()
            }
        }
        .onChange(of: viewModel.currentTime) { _, _ in
            guard activePanel == .graph,
                let section = graphReturnPanel.keyframeSection
            else { return }
            viewModel.selectGraphSegment(atPlayheadIn: section)
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
        .confirmationDialog(
            "Stop the current task?",
            isPresented: $isCancelTaskConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Stop Task", role: .destructive) {
                viewModel.cancelLongRunningTask()
            }
            Button("Keep Waiting", role: .cancel) {}
        } message: {
            Text("The current import, export, or preview preparation will be cancelled.")
        }
    }

    private func editorCanvas(geometry: GeometryProxy) -> some View {
        let availableHeight = max(geometry.size.height - geometry.safeAreaInsets.bottom - 12, 1)
        let showsMiniTimeline = activePanel.isPropertyPanel || activePanel == .graph
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
                CorePreviewSection(
                    viewModel: viewModel,
                    selectedMediaItems: $selectedMediaItems
                )
                .frame(height: previewHeight)

                EditorPlaybackControlBar(
                    viewModel: viewModel,
                    activePanel: $activePanel,
                    graphReturnPanel: $graphReturnPanel
                )
                .frame(height: controlHeight)

                workspace
                    .frame(maxWidth: .infinity)

                if showsMiniTimeline {
                    SelectedLayerMiniTimeline(
                        viewModel: viewModel,
                        contextClipID: $propertyContextClipID,
                        pixelsPerSecond: $miniTimelinePixelsPerSecond,
                        activeSection: activePanel == .graph
                            ? graphReturnPanel.keyframeSection
                            : activePanel.keyframeSection,
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
                    graphReturnPanel: $graphReturnPanel
                )
            }
            .padding()

            EditorBusyOverlay(viewModel: viewModel) {
                isCancelTaskConfirmationPresented = true
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
    }

    @ViewBuilder
    private var workspace: some View {
        switch activePanel {
        case .timeline:
            CoreTimelineView(
                viewModel: viewModel,
                pixelsPerSecond: $pixelsPerSecond
            )
        case .shape:
            ShapeWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip
            )
        case .transform:
            TransformWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip
            )
        case .adjust:
            AdjustWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip
            )
        case .effects:
            EffectsWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip
            )
        case .audio:
            AudioWorkspaceView(
                viewModel: viewModel,
                clip: propertyContextClip
            )
        case .graph:
            KeyframeWorkspaceView(viewModel: viewModel)
        }
    }

    private var propertyContextClip: TimelineClip? {
        guard let propertyContextClipID else { return nil }
        return viewModel.project.clip(id: propertyContextClipID)
    }
}

private struct EditorPlaybackControlBar: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var activePanel: CoreEditorPanel
    @Binding var graphReturnPanel: CoreEditorPanel

    var body: some View {
        ZStack {
            HStack(spacing: 9) {
                Text("\(formatClock(viewModel.currentTime)) / \(formatClock(viewModel.duration))")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textSecondary)
                    .lineLimit(1)
                Spacer()

                if activePanel == .graph {
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
                } else if let section = activePanel.keyframeSection,
                    viewModel.candidateGraphSegment(in: section) != nil
                {
                    CompactIconButton(
                        systemName: "point.topleft.down.curvedto.point.bottomright.up",
                        title: "Graph",
                        isProminent: true,
                        action: {
                            graphReturnPanel = activePanel
                            viewModel.openCandidateGraphSegment(in: section)
                            if viewModel.graphSegment != nil {
                                activePanel = .graph
                            }
                        },
                        isBordered: false
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
}

extension CoreEditorPanel {
    var isPropertyPanel: Bool {
        self == .shape || self == .transform || self == .adjust || self == .effects || self == .audio
    }

    var keyframeSection: KeyframeSection? {
        switch self {
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
        case .timeline, .graph:
            nil
        }
    }
}
