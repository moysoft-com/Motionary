// Root editor screen that composes preview, timeline, controls, and application state.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum CoreEditorPanel: Equatable {
    case timeline
    case transform
    case adjust
    case effects
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
    @State private var selectedAudioVideoItem: PhotosPickerItem?
    @State private var isAudioFileImporterPresented = false
    @State private var isExportSettingsPresented = false
    @State private var activePanel: CoreEditorPanel = .timeline
    @State private var pixelsPerSecond: CGFloat = 88
    @State private var miniTimelinePixelsPerSecond: CGFloat = 88
    @State private var propertyContextClipID: UUID?
    @State private var graphReturnPanel: CoreEditorPanel = .transform

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
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    EditorHaptics.tap()
                    isExportSettingsPresented = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(!viewModel.canExportVideo || viewModel.isExporting)
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
        .onChange(of: viewModel.selectedClipID) { _, clipID in
            if let clipID, activePanel.isPropertyPanel {
                propertyContextClipID = clipID
            }
        }
        .onChange(of: viewModel.project) { _, project in
            if let contextID = propertyContextClipID,
                project.clip(id: contextID) == nil
            {
                propertyContextClipID = nil
                viewModel.graphSegment = nil
                activePanel = .timeline
            } else if activePanel == .graph {
                viewModel.refreshGraphSegment()
            }
        }
        .onChange(of: viewModel.graphSegment) { _, segment in
            guard activePanel == .graph, segment == nil else { return }
            if let contextID = propertyContextClipID,
                viewModel.project.clip(id: contextID) != nil
            {
                activePanel = graphReturnPanel
            } else {
                activePanel = .timeline
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
        .sheet(isPresented: $isExportSettingsPresented) {
            ExportSettingsView(project: viewModel.project) { settings in
                isExportSettingsPresented = false
                viewModel.exportProject(settings: settings)
            }
        }
    }

    private func editorCanvas(geometry: GeometryProxy) -> some View {
        let availableHeight = max(geometry.size.height - geometry.safeAreaInsets.bottom - 12, 1)
        let bottomBarHeight: CGFloat = 72
        let showsMiniTimeline = activePanel.isPropertyPanel
        let miniTimelineHeight: CGFloat = showsMiniTimeline ? 52 : 0
        let controlHeight: CGFloat = 42
        let previewRatio: CGFloat
        switch activePanel {
        case .timeline:
            previewRatio = 0.44
        case .graph:
            previewRatio = 0.34
        default:
            previewRatio = 0.31
        }
        let previewHeight = availableHeight * previewRatio
        let workspaceHeight = max(
            availableHeight - previewHeight - miniTimelineHeight - controlHeight - bottomBarHeight - 30,
            170
        )

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
                
                if showsMiniTimeline {
                    SelectedLayerMiniTimeline(
                        viewModel: viewModel,
                        contextClipID: propertyContextClipID,
                        pixelsPerSecond: $miniTimelinePixelsPerSecond
                    )
                    .frame(height: miniTimelineHeight)
                }

                CoreToolBar(
                    viewModel: viewModel,
                    selectedMediaItems: $selectedMediaItems,
                    selectedAudioVideoItem: $selectedAudioVideoItem,
                    isAudioFileImporterPresented: $isAudioFileImporterPresented,
                    activePanel: $activePanel,
                    propertyContextClipID: $propertyContextClipID
                )
                .frame(height: bottomBarHeight)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, geometry.safeAreaInsets.bottom + 6)

            EditorBusyOverlay(viewModel: viewModel)

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
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textSecondary)
                    .lineLimit(1)
                Spacer()

                if activePanel.isPropertyPanel, viewModel.candidateGraphSegment != nil {
                    CompactIconButton(
                        systemName: "point.topleft.down.curvedto.point.bottomright.up",
                        title: "Graph",
                        isProminent: true,
                        action: {
                            graphReturnPanel = activePanel
                            viewModel.openCandidateGraphSegment()
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
        self == .transform || self == .adjust || self == .effects
    }
}
