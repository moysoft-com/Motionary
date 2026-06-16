import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

private enum CoreEditorPanel: Equatable {
    case timeline
    case transform
}

struct ProjectEditorView: View {
    let projectID: UUID
    @ObservedObject var projectStore: ProjectStore
    let initialContent: ProjectContent

    @StateObject private var viewModel: EditorViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedMediaItems: [PhotosPickerItem] = []
    @State private var isShareSheetPresented = false
    @State private var activePanel: CoreEditorPanel = .timeline
    @State private var pixelsPerSecond: CGFloat = 88

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
            let availableHeight = max(geometry.size.height - geometry.safeAreaInsets.bottom - 12, 1)
            let bottomBarHeight: CGFloat = 72
            let previewHeight = availableHeight * 0.44
            let workspaceHeight = max(availableHeight - previewHeight - bottomBarHeight - 16, 190)

            ZStack {
                MotionaryTheme.background(for: colorScheme).ignoresSafeArea()

                VStack(spacing: 10) {
                    CorePreviewSection(
                        viewModel: viewModel,
                        selectedMediaItems: $selectedMediaItems
                    )
                    .frame(height: previewHeight)
                    ZStack {
                        HStack(spacing: 12) {
                            
                            Text("\(formatClock(viewModel.currentTime)) / \(formatClock(viewModel.duration))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MotionaryTheme.textSecondary)
                                .lineLimit(1)
                            Spacer()

                            CompactIconButton(
                                systemName: "arrow.uturn.backward",
                                title: "Undo",
                                isProminent: true,
                                isDisabled: !viewModel.canUndo,
                                isBordered: false,
                                action: {
                                    viewModel.undo()
                                }
                            )
                            CompactIconButton(
                                systemName: "arrow.uturn.forward",
                                title: "Redo",
                                isProminent: true,
                                isDisabled: !viewModel.canRedo,
                                isBordered: false,
                                action: {
                                    viewModel.redo()
                                }
                            )
                        }
                        .padding(.horizontal, 5)
                        HStack {
                            Spacer()
                            CompactIconButton(
                                systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                                title: viewModel.isPlaying ? "Pause" : "Play",
                                isProminent: true,
                                isDisabled: viewModel.player == nil
                            ) {
                                viewModel.togglePlayback()
                            }
                            Spacer()
                        }
                    }

                    Group {
                        switch activePanel {
                        case .timeline:
                            CoreTimelineView(
                                viewModel: viewModel,
                                pixelsPerSecond: $pixelsPerSecond
                            )
                        case .transform:
                            TransformWorkspaceView(viewModel: viewModel)
                        }
                    }
                    .frame(height: workspaceHeight)

                    CoreToolBar(
                        viewModel: viewModel,
                        selectedMediaItems: $selectedMediaItems,
                        activePanel: $activePanel
                    )
                    .frame(height: bottomBarHeight)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, geometry.safeAreaInsets.bottom + 6)

                EditorBusyOverlay(viewModel: viewModel)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(viewModel.project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    EditorHaptics.tap()
                    viewModel.exportProject()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(viewModel.duration == 0 || viewModel.isExporting)
                .accessibilityLabel("Export")
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
        .onChange(of: viewModel.shareURL) { _, url in
            isShareSheetPresented = url != nil
        }
        .alert("Motionary", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $isShareSheetPresented, onDismiss: {
            viewModel.shareURL = nil
        }) {
            if let url = viewModel.shareURL {
                ActivityView(activityItems: [url])
            }
        }
    }
}

private struct TimelineClipDragState: Equatable {
    let clipID: UUID
    let clipKind: TrackKind
    let targetTrackIndex: Int
    let insertionTrackIndex: Int?
    let sourceTrackIndex: Int
    let translationY: CGFloat
    let overlayClip: TimelineClip
}

private struct CorePreviewSection: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var selectedMediaItems: [PhotosPickerItem]

    var body: some View {
        ZStack {
            if let player = viewModel.player {
                GeometryReader { geometry in
                    let ratio = CGFloat(viewModel.project.renderSettings.width) / CGFloat(max(viewModel.project.renderSettings.height, 1))
                    let canvasRect = aspectFitRect(in: geometry.size, aspectRatio: ratio)
                    let localCanvasRect = CGRect(origin: .zero, size: canvasRect.size)

                    ZStack {
                        PreviewRendererView(player: player)
                            .frame(width: canvasRect.width, height: canvasRect.height)

                        PreviewTransformCanvas(
                            viewModel: viewModel,
                            canvasRect: localCanvasRect
                        )
                    }
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .border(.gray.opacity(0.3), width: 0.5)
                    .position(x: canvasRect.midX, y: canvasRect.midY)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(MotionaryTheme.accent)
                    PhotosPicker(selection: $selectedMediaItems, matching: .any(of: [.images, .videos])) {
                        Label("Import Media", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .foregroundStyle(Color.black)
                            .background(MotionaryTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if viewModel.isRenderingPreview {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .glassEffect(.regular)
            }
        }
    }
}

private struct CoreTimelineView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var pixelsPerSecond: CGFloat
    @State private var activeClipDrag: TimelineClipDragState?
    private let trackHeight: CGFloat = 50
    private let rowSpacing: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            CoreTimelineLayout(
                viewModel: viewModel,
                pixelsPerSecond: $pixelsPerSecond,
                activeClipDrag: $activeClipDrag,
                size: geometry.size,
                trackHeight: trackHeight,
                rowSpacing: rowSpacing
            )
        }
    }
}

private struct CoreTimelineLayout: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var pixelsPerSecond: CGFloat
    @Binding var activeClipDrag: TimelineClipDragState?
    let size: CGSize
    let trackHeight: CGFloat
    let rowSpacing: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.045))

            timelineScroll
            fixedRuler
            playhead
            emptyState
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .motionaryGlass(cornerRadius: 20)
    }

    private var centerPadding: CGFloat { size.width / 2 }
    private var duration: Double { max(viewModel.duration, 0.1) }
    private var contentWidth: CGFloat { max(CGFloat(viewModel.duration) * pixelsPerSecond, 0) + centerPadding * 2 }
    private var rowCount: Int { max(viewModel.project.tracks.count, 1) + (activeClipDrag?.insertionTrackIndex == nil ? 0 : 1) }
    private var contentHeight: CGFloat { CGFloat(rowCount) * (trackHeight + rowSpacing) + 38 }

    private var timelineScroll: some View {
        TimelineScrollContainer(
            pixelsPerSecond: $pixelsPerSecond,
            currentTime: viewModel.currentTime,
            duration: viewModel.duration,
            contentRevision: viewModel.timelineContentRevision,
            contentSize: CGSize(width: contentWidth, height: max(contentHeight, size.height)),
            onScrubStart: { viewModel.beginScrub() },
            onScrubChanged: { viewModel.updateScrub(to: $0) },
            onScrubEnd: { viewModel.endScrub(at: $0) }
        ) {
            TimelineTracksContent(
                viewModel: viewModel,
                activeClipDrag: $activeClipDrag,
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                containerHeight: size.height,
                centerPadding: centerPadding,
                pixelsPerSecond: pixelsPerSecond,
                trackHeight: trackHeight,
                rowSpacing: rowSpacing
            )
        }
    }

    private var fixedRuler: some View {
        VStack(spacing: 0) {
            FixedTimelineRuler(
                duration: duration,
                currentTime: viewModel.currentTime,
                pixelsPerSecond: pixelsPerSecond
            )
            .frame(height: 30)
            .allowsHitTesting(false)

            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .allowsHitTesting(false)
    }

    private var playhead: some View {
        Rectangle()
            .fill(MotionaryTheme.selected)
            .frame(width: 2, height: size.height - 22)
            .position(x: size.width / 2, y: size.height / 2 + 8)
            .shadow(color: .black.opacity(0.45), radius: 6)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.duration == 0 {
            Text("Import media to start")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MotionaryTheme.textSecondary)
        }
    }
}

private struct TimelineTracksContent: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var activeClipDrag: TimelineClipDragState?
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let centerPadding: CGFloat
    let pixelsPerSecond: CGFloat
    let trackHeight: CGFloat
    let rowSpacing: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.deselectTimeline()
                }

            VStack(spacing: rowSpacing) {
                ForEach(Array(viewModel.project.tracks.enumerated()), id: \.element.id) { index, track in
                    if activeClipDrag?.insertionTrackIndex == index {
                        TimelineInsertionGapRow(kind: activeClipDrag?.clipKind ?? .visual, height: trackHeight)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    trackRow(track: track, index: index)
                }

                if activeClipDrag?.insertionTrackIndex == viewModel.project.tracks.count {
                    TimelineInsertionGapRow(kind: activeClipDrag?.clipKind ?? .visual, height: trackHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .offset(y: 30)
            .animation(.snappy(duration: 0.18), value: activeClipDrag?.insertionTrackIndex)

            if let activeClipDrag {
                TimelineClipBlock(
                    clip: activeClipDrag.overlayClip,
                    isSelected: true,
                    isGhosted: false,
                    pixelsPerSecond: pixelsPerSecond,
                    height: trackHeight - 8,
                    rowStride: trackHeight + rowSpacing,
                    sourceTrackIndex: activeClipDrag.sourceTrackIndex,
                    trackCount: viewModel.project.tracks.count,
                    onSelect: {},
                    onBeginEdit: {},
                    onMove: { _, _, _, _ in nil },
                    onPreviewMove: { _, _, _ in nil },
                    onTrimStart: { _, _, _ in nil },
                    onPreviewTrimStart: { _, _ in nil },
                    onTrimEnd: { _, _, _ in nil },
                    onPreviewTrimEnd: { _, _ in nil },
                    onFinishInteractiveEdit: {},
                    onClipDragChanged: { _ in }
                )
                .allowsHitTesting(false)
                .offset(
                    x: centerPadding + CGFloat(activeClipDrag.overlayClip.timelineStart) * pixelsPerSecond,
                    y: 30 + CGFloat(activeClipDrag.sourceTrackIndex) * (trackHeight + rowSpacing) + 4 + activeClipDrag.translationY
                )
                .zIndex(20)
                .transaction { $0.animation = nil }
            }
        }
        .frame(width: contentWidth, height: max(contentHeight, containerHeight), alignment: .topLeading)
    }

    private func trackRow(track: TimelineTrack, index: Int) -> some View {
        TimelineTrackRow(
            track: track,
            trackIndex: index,
            trackCount: viewModel.project.tracks.count,
            selectedClipID: viewModel.selectedClipID,
            activeClipID: activeClipDrag?.clipID,
            projectDuration: viewModel.duration,
            pixelsPerSecond: pixelsPerSecond,
            centerPadding: centerPadding,
            height: trackHeight,
            rowStride: trackHeight + rowSpacing,
            onSelectTrack: { viewModel.selectedTrackID = track.id },
            onSelectClip: { clipID in
                viewModel.selectClip(clipID, trackID: track.id, revealInPreview: true)
            },
            onBeginEditClip: { clipID in
                viewModel.selectClip(clipID, trackID: track.id)
            },
            onMoveClip: { clipID, start, targetIndex, insertionIndex, interactive in
                viewModel.selectClip(clipID, trackID: track.id)
                return viewModel.placeClip(
                    clipID,
                    at: start,
                    proposedTrackIndex: targetIndex,
                    insertTrackAt: insertionIndex,
                    interactive: interactive
                )
            },
            onPreviewMoveClip: { clipID, start, targetIndex, insertionIndex in
                viewModel.previewClipPlacement(
                    clipID,
                    at: start,
                    proposedTrackIndex: targetIndex,
                    insertTrackAt: insertionIndex
                )
            },
            onTrimStart: { clipID, delta, baseline, interactive in
                viewModel.selectClip(clipID, trackID: track.id)
                return viewModel.trimClipStart(
                    clipID,
                    by: delta,
                    baseline: baseline,
                    interactive: interactive
                )
            },
            onPreviewTrimStart: { clipID, delta, baseline in
                viewModel.previewTrimClipStart(
                    clipID,
                    by: delta,
                    baseline: baseline
                )
            },
            onTrimEnd: { clipID, delta, baseline, interactive in
                viewModel.selectClip(clipID, trackID: track.id)
                return viewModel.trimClipEnd(
                    clipID,
                    by: delta,
                    baseline: baseline,
                    interactive: interactive
                )
            },
            onPreviewTrimEnd: { clipID, delta, baseline in
                viewModel.previewTrimClipEnd(
                    clipID,
                    by: delta,
                    baseline: baseline
                )
            },
            onFinishInteractiveEdit: {
                viewModel.finishInteractiveEdit()
            },
            onMoveTrack: { trackID, targetIndex in
                viewModel.moveTrack(trackID, to: targetIndex)
            },
            onClipDragChanged: { state in
                withAnimation(.snappy(duration: 0.18)) {
                    activeClipDrag = state
                }
            }
        )
    }
}

private struct TimelineRuler: View {
    let duration: Double
    let pixelsPerSecond: CGFloat
    let centerPadding: CGFloat

    var body: some View {
        Canvas { context, _ in
            let seconds = max(Int(ceil(duration)), 1)
            for second in 0...seconds {
                let x = centerPadding + CGFloat(second) * pixelsPerSecond
                var path = Path()
                path.move(to: CGPoint(x: x, y: second % 5 == 0 ? 4 : 12))
                path.addLine(to: CGPoint(x: x, y: 26))
                context.stroke(path, with: .color(.white.opacity(second % 5 == 0 ? 0.42 : 0.18)), lineWidth: 1)

                if second % 5 == 0 {
                    context.draw(
                        Text("\(second)s")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.58)),
                        at: CGPoint(x: x + 12, y: 10)
                    )
                }
            }
        }
    }
}

private struct FixedTimelineRuler: View {
    let duration: Double
    let currentTime: Double
    let pixelsPerSecond: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let centerX = size.width / 2
                let visibleStart = max(Int(floor(currentTime - Double(centerX / pixelsPerSecond))) - 1, 0)
                let visibleEnd = Int(ceil(currentTime + Double(centerX / pixelsPerSecond))) + 1

                for second in visibleStart...max(visibleStart, visibleEnd) {
                    guard Double(second) <= max(duration, 4) else { continue }
                    let x = centerX + CGFloat(Double(second) - currentTime) * pixelsPerSecond
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: second % 5 == 0 ? 5 : 14))
                    path.addLine(to: CGPoint(x: x, y: 29))
                    context.stroke(path, with: .color(.white.opacity(second % 5 == 0 ? 0.46 : 0.18)), lineWidth: 1)

                    if second % 2 == 0 {
                        context.draw(
                            Text(formatClock(Double(second)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.58)),
                            at: CGPoint(x: x + 18, y: 10)
                        )
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(.black.opacity(0.12))
        }
    }
}

private struct PreviewClipInfo: Identifiable {
    let trackID: UUID
    let clip: TimelineClip

    var id: UUID { clip.id }
}

private struct PreviewClipFrame {
    let rect: CGRect
    let rotationDegrees: Double
}

private struct PreviewTransformCanvas: View {
    @ObservedObject var viewModel: EditorViewModel
    let canvasRect: CGRect

    @State private var dragStartTransform: ClipTransform?
    @State private var scaleStart: Double?
    @State private var rotationStart: Double?
    @State private var snapGuideX: CGFloat?
    @State private var snapGuideY: CGFloat?
    @State private var previewSnapKey: String?
    @State private var lastPreviewSnapFeedbackKey: String?
    @State private var lastPreviewSnapFeedbackAt: Date = .distantPast
    @State private var isTransforming = false

    var body: some View {
        ZStack {
            ForEach(activeClipInfos.reversed()) { info in
                if let frame = previewFrame(for: info.clip) {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: frame.rect.width, height: frame.rect.height)
                        .rotationEffect(.degrees(frame.rotationDegrees))
                        .position(x: frame.rect.midX, y: frame.rect.midY)
                        .onTapGesture {
                            EditorHaptics.selection()
                            viewModel.selectClip(info.clip.id, trackID: info.trackID)
                        }
                }
            }

            if isTransforming,
               let clip = selectedVisualClip,
               let frame = previewFrame(for: clip) {
                LiveTransformClipProxy(
                    clip: clip,
                    frame: frame,
                    currentTime: viewModel.currentTime
                )
                .allowsHitTesting(false)
            }

            if let x = snapGuideX {
                Rectangle()
                    .fill(MotionaryTheme.accent.opacity(0.82))
                    .frame(width: 1, height: canvasRect.height)
                    .position(x: x, y: canvasRect.midY)
                    .allowsHitTesting(false)
            }

            if let y = snapGuideY {
                Rectangle()
                    .fill(MotionaryTheme.accent.opacity(0.82))
                    .frame(width: canvasRect.width, height: 1)
                    .position(x: canvasRect.midX, y: y)
                    .allowsHitTesting(false)
            }

            if let clip = selectedVisualClip,
               let frame = previewFrame(for: clip) {
                PreviewSelectionBox(frame: frame)
                    .gesture(dragGesture(for: clip, frame: frame))
                    .simultaneousGesture(scaleGesture(for: clip))
                    .simultaneousGesture(rotationGesture(for: clip))
                    .id(clip.id)
            }
        }
        .frame(width: canvasRect.width, height: canvasRect.height)
        .position(x: canvasRect.midX, y: canvasRect.midY)
        .onChange(of: viewModel.selectedClipID) { _, _ in
            resetPreviewInteraction(finishEdit: isTransforming)
        }
        .onDisappear {
            resetPreviewInteraction(finishEdit: isTransforming)
        }
    }

    private var selectedVisualClip: TimelineClip? {
        guard let clip = viewModel.selectedClip, clip.mediaType != .audio else { return nil }
        return clip
    }

    private var activeClipInfos: [PreviewClipInfo] {
        viewModel.project.tracks.flatMap { track in
            track.clips.compactMap { clip in
                guard clip.mediaType != .audio else { return nil }
                guard isClipVisible(clip) || clip.id == viewModel.selectedClipID else { return nil }
                return PreviewClipInfo(trackID: track.id, clip: clip)
            }
        }
    }

    private func dragGesture(for clip: TimelineClip, frame: PreviewClipFrame) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartTransform == nil {
                    dragStartTransform = clip.transform
                    isTransforming = true
                    EditorHaptics.dragStart()
                    viewModel.beginInteractiveEdit()
                }
                guard let start = dragStartTransform else { return }

                let proposedX = start.positionX.baseValue + Double(value.translation.width / max(canvasRect.width * 0.5, 1))
                let proposedY = start.positionY.baseValue - Double(value.translation.height / max(canvasRect.height * 0.5, 1))
                let snapped = snappedPosition(
                    positionX: proposedX,
                    positionY: proposedY,
                    frame: frame,
                    selectedClipID: clip.id
                )
                snapGuideX = snapped.guideX
                snapGuideY = snapped.guideY
                updatePreviewSnapHaptic(
                    kind: "position",
                    snapped: snapped.guideX != nil || snapped.guideY != nil,
                    value: "\(Int((snapped.guideX ?? -1).rounded())):\(Int((snapped.guideY ?? -1).rounded()))"
                )
                viewModel.setSelectedTransform(
                    positionX: snapped.positionX,
                    positionY: snapped.positionY,
                    interactive: true
                )
            }
            .onEnded { _ in
                resetPreviewInteraction(finishEdit: true)
            }
    }

    private func scaleGesture(for clip: TimelineClip) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if scaleStart == nil {
                    scaleStart = clip.transform.scale.baseValue
                    isTransforming = true
                    EditorHaptics.dragStart()
                    viewModel.beginInteractiveEdit()
                }
                guard let scaleStart else { return }
                let snapped = snappedScale(
                    scale: scaleStart * value,
                    clip: clip,
                    selectedClipID: clip.id
                )
                snapGuideX = snapped.guideX
                snapGuideY = snapped.guideY
                updatePreviewSnapHaptic(
                    kind: "scale",
                    snapped: snapped.guideX != nil || snapped.guideY != nil,
                    value: "\(Int((snapped.guideX ?? -1).rounded())):\(Int((snapped.guideY ?? -1).rounded()))"
                )
                viewModel.setSelectedTransform(scale: snapped.scale, interactive: true)
            }
            .onEnded { _ in
                resetPreviewInteraction(finishEdit: true)
            }
    }

    private func rotationGesture(for clip: TimelineClip) -> some Gesture {
        RotationGesture()
            .onChanged { value in
                if rotationStart == nil {
                    rotationStart = clip.transform.rotationDegrees.baseValue
                    isTransforming = true
                    EditorHaptics.dragStart()
                    viewModel.beginInteractiveEdit()
                }
                guard let rotationStart else { return }
                let snapped = snappedRotation(rotationStart - value.degrees)
                updatePreviewSnapHaptic(
                    kind: "rotation",
                    snapped: snapped.snapped,
                    value: String(format: "%.0f", snapped.rotation)
                )
                viewModel.setSelectedTransform(rotationDegrees: snapped.rotation, interactive: true)
            }
            .onEnded { _ in
                resetPreviewInteraction(finishEdit: true)
            }
    }

    private func snappedPosition(
        positionX: Double,
        positionY: Double,
        frame: PreviewClipFrame,
        selectedClipID: UUID
    ) -> (positionX: Double, positionY: Double, guideX: CGFloat?, guideY: CGFloat?) {
        let proposedCenter = CGPoint(
            x: canvasRect.midX + CGFloat(positionX) * canvasRect.width * 0.5,
            y: canvasRect.midY - CGFloat(positionY) * canvasRect.height * 0.5
        )
        let targets = snapTargets(excluding: selectedClipID)
        let threshold: CGFloat = 10

        let snappedX = snapAxis(
            center: proposedCenter.x,
            anchorOffsets: rotatedAnchorOffsets(size: frame.rect.size, rotationDegrees: frame.rotationDegrees).map(\.x),
            targets: targets.x,
            threshold: threshold
        )
        let snappedY = snapAxis(
            center: proposedCenter.y,
            anchorOffsets: rotatedAnchorOffsets(size: frame.rect.size, rotationDegrees: frame.rotationDegrees).map(\.y),
            targets: targets.y,
            threshold: threshold
        )

        let normalizedX = Double((snappedX.center - canvasRect.midX) / max(canvasRect.width * 0.5, 1))
        let normalizedY = Double(-(snappedY.center - canvasRect.midY) / max(canvasRect.height * 0.5, 1))
        return (normalizedX, normalizedY, snappedX.guide, snappedY.guide)
    }

    private func snappedScale(
        scale: Double,
        clip: TimelineClip,
        selectedClipID: UUID
    ) -> (scale: Double, guideX: CGFloat?, guideY: CGFloat?) {
        guard let baseSize = previewBaseSize(for: clip) else {
            return (min(max(scale, 0.05), 8), nil, nil)
        }

        let proposedScale = CGFloat(min(max(scale, 0.05), 8))
        let center = previewCenter(for: clip)
        let targets = snapTargets(excluding: selectedClipID)
        let threshold: CGFloat = 10
        let rotation = -clip.transform.rotationDegrees.baseValue

        let xSnap = snapScaleAxis(
            center: center.x,
            baseOffsets: rotatedAnchorOffsets(size: baseSize, rotationDegrees: rotation).map(\.x),
            proposedScale: proposedScale,
            targets: targets.x,
            threshold: threshold
        )
        let ySnap = snapScaleAxis(
            center: center.y,
            baseOffsets: rotatedAnchorOffsets(size: baseSize, rotationDegrees: rotation).map(\.y),
            proposedScale: proposedScale,
            targets: targets.y,
            threshold: threshold
        )

        let best = [xSnap, ySnap]
            .compactMap { $0 }
            .min { $0.distance < $1.distance }

        guard let best else {
            return (Double(proposedScale), nil, nil)
        }

        return (
            Double(min(max(best.scale, 0.05), 8)),
            xSnap?.guide == best.guide ? xSnap?.guide : nil,
            ySnap?.guide == best.guide ? ySnap?.guide : nil
        )
    }

    private func snappedRotation(_ degrees: Double) -> (rotation: Double, snapped: Bool) {
        let interval = 15.0
        let threshold = 2.25
        let nearest = (degrees / interval).rounded() * interval
        guard abs(nearest - degrees) <= threshold else {
            return (degrees, false)
        }
        return (nearest, true)
    }

    private func snapTargets(excluding selectedClipID: UUID) -> (x: [CGFloat], y: [CGFloat]) {
        var xTargets = [canvasRect.minX, canvasRect.midX, canvasRect.maxX]
        var yTargets = [canvasRect.minY, canvasRect.midY, canvasRect.maxY]

        for info in activeClipInfos where info.clip.id != selectedClipID {
            guard let frame = previewFrame(for: info.clip) else { continue }
            let anchors = rotatedAnchors(for: frame)
            xTargets.append(contentsOf: anchors.map(\.x))
            yTargets.append(contentsOf: anchors.map(\.y))
        }

        return (xTargets, yTargets)
    }

    private func snapAxis(center: CGFloat, anchorOffsets: [CGFloat], targets: [CGFloat], threshold: CGFloat) -> (center: CGFloat, guide: CGFloat?) {
        let ownAnchors = anchorOffsets.map { center + $0 }
        var bestDelta: CGFloat = 0
        var bestGuide: CGFloat?
        var bestDistance = threshold

        for ownAnchor in ownAnchors {
            for target in targets {
                let delta = target - ownAnchor
                let distance = abs(delta)
                if distance < bestDistance {
                    bestDistance = distance
                    bestDelta = delta
                    bestGuide = target
                }
            }
        }

        return (center + bestDelta, bestGuide)
    }

    private func snapScaleAxis(
        center: CGFloat,
        baseOffsets: [CGFloat],
        proposedScale: CGFloat,
        targets: [CGFloat],
        threshold: CGFloat
    ) -> (scale: CGFloat, guide: CGFloat, distance: CGFloat)? {
        let offsets = baseOffsets.filter { abs($0) > 0.001 }
        guard !offsets.isEmpty else { return nil }
        var best: (scale: CGFloat, guide: CGFloat, distance: CGFloat)?

        for offset in offsets {
            let proposedAnchor = center + offset * proposedScale
            for target in targets {
                let desiredScale = (target - center) / offset
                guard desiredScale > 0 else { continue }
                let distance = abs(target - proposedAnchor)
                guard distance < threshold else { continue }
                if best == nil || distance < best!.distance {
                    best = (desiredScale, target, distance)
                }
            }
        }

        return best
    }

    private func rotatedAnchors(for frame: PreviewClipFrame) -> [CGPoint] {
        let offsets = rotatedAnchorOffsets(size: frame.rect.size, rotationDegrees: frame.rotationDegrees)
        let center = CGPoint(x: frame.rect.midX, y: frame.rect.midY)
        return offsets.map { CGPoint(x: center.x + $0.x, y: center.y + $0.y) }
    }

    private func rotatedAnchorOffsets(size: CGSize, rotationDegrees: Double) -> [CGPoint] {
        let halfWidth = size.width * 0.5
        let halfHeight = size.height * 0.5
        let base = [
            CGPoint(x: -halfWidth, y: -halfHeight),
            CGPoint(x: 0, y: -halfHeight),
            CGPoint(x: halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: 0),
            CGPoint(x: halfWidth, y: halfHeight),
            CGPoint(x: 0, y: halfHeight),
            CGPoint(x: -halfWidth, y: halfHeight),
            CGPoint(x: -halfWidth, y: 0),
            .zero
        ]
        let radians = CGFloat(rotationDegrees * .pi / 180)
        let cosValue = cos(radians)
        let sinValue = sin(radians)
        return base.map { point in
            CGPoint(
                x: point.x * cosValue - point.y * sinValue,
                y: point.x * sinValue + point.y * cosValue
            )
        }
    }

    private func previewFrame(for clip: TimelineClip) -> PreviewClipFrame? {
        let sourceSize = clip.source.naturalSize?.cgSize ?? viewModel.project.renderSettings.size
        guard sourceSize.width > 0, sourceSize.height > 0, canvasRect.width > 0, canvasRect.height > 0 else {
            return nil
        }

        let fitScale = min(canvasRect.width / sourceSize.width, canvasRect.height / sourceSize.height)
        let scale = max(clip.transform.scale.baseValue, 0.05)
        let size = CGSize(width: sourceSize.width * fitScale * scale, height: sourceSize.height * fitScale * scale)
        let center = previewCenter(for: clip)

        return PreviewClipFrame(
            rect: CGRect(
                x: center.x - size.width * 0.5,
                y: center.y - size.height * 0.5,
                width: size.width,
                height: size.height
            ),
            rotationDegrees: -clip.transform.rotationDegrees.baseValue
        )
    }

    private func previewBaseSize(for clip: TimelineClip) -> CGSize? {
        let sourceSize = clip.source.naturalSize?.cgSize ?? viewModel.project.renderSettings.size
        guard sourceSize.width > 0, sourceSize.height > 0, canvasRect.width > 0, canvasRect.height > 0 else {
            return nil
        }
        let fitScale = min(canvasRect.width / sourceSize.width, canvasRect.height / sourceSize.height)
        return CGSize(width: sourceSize.width * fitScale, height: sourceSize.height * fitScale)
    }

    private func previewCenter(for clip: TimelineClip) -> CGPoint {
        CGPoint(
            x: canvasRect.midX + CGFloat(clip.transform.positionX.baseValue) * canvasRect.width * 0.5,
            y: canvasRect.midY - CGFloat(clip.transform.positionY.baseValue) * canvasRect.height * 0.5
        )
    }

    private func isClipVisible(_ clip: TimelineClip) -> Bool {
        viewModel.currentTime >= clip.timelineStart && viewModel.currentTime < clip.timelineEnd
    }

    private func resetPreviewInteraction(finishEdit: Bool) {
        dragStartTransform = nil
        scaleStart = nil
        rotationStart = nil
        snapGuideX = nil
        snapGuideY = nil
        previewSnapKey = nil
        isTransforming = false
        if finishEdit {
            viewModel.finishInteractiveEdit()
            EditorHaptics.editCommit()
        }
    }

    private func updatePreviewSnapHaptic(kind: String, snapped: Bool, value: String) {
        let key = snapped ? "\(kind)-\(value)" : nil
        let previousKey = previewSnapKey
        previewSnapKey = key
        guard let key, key != previousKey else { return }

        let now = Date()
        if key == lastPreviewSnapFeedbackKey,
           now.timeIntervalSince(lastPreviewSnapFeedbackAt) < 0.35 {
            return
        }

        lastPreviewSnapFeedbackKey = key
        lastPreviewSnapFeedbackAt = now
        EditorHaptics.snap()
    }
}

private struct LiveTransformClipProxy: View {
    let clip: TimelineClip
    let frame: PreviewClipFrame
    let currentTime: Double

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(width: frame.rect.width, height: frame.rect.height)
        .clipped()
        .rotationEffect(.degrees(frame.rotationDegrees))
        .position(x: frame.rect.midX, y: frame.rect.midY)
        .opacity(0.9)
        .task(id: taskID) {
            image = await TimelineThumbnailLoader.image(
                for: clip,
                timelineTime: currentTime,
                targetHeight: max(frame.rect.height, 80)
            )
        }
    }

    private var taskID: String {
        [
            clip.source.url.path,
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration),
            String(format: "%.2f", currentTime),
            "\(Int(frame.rect.height.rounded()))"
        ].joined(separator: "|")
    }
}

private struct PreviewSelectionBox: View {
    let frame: PreviewClipFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(MotionaryTheme.accent, lineWidth: 1.5)

            ForEach(SelectionHandlePosition.allCases) { position in
                Circle()
                    .fill(MotionaryTheme.accent)
                    .frame(width: 9, height: 9)
                    .position(position.point(in: frame.rect.size))
            }
        }
        .frame(width: frame.rect.width, height: frame.rect.height)
        .rotationEffect(.degrees(frame.rotationDegrees))
        .position(x: frame.rect.midX, y: frame.rect.midY)
        .contentShape(Rectangle())
    }
}

private enum SelectionHandlePosition: CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: Self { self }

    func point(in size: CGSize) -> CGPoint {
        switch self {
        case .topLeft:
            CGPoint(x: 0, y: 0)
        case .topRight:
            CGPoint(x: size.width, y: 0)
        case .bottomLeft:
            CGPoint(x: 0, y: size.height)
        case .bottomRight:
            CGPoint(x: size.width, y: size.height)
        }
    }
}

private struct TimelineScrollContainer<Content: View>: UIViewRepresentable {
    @Binding var pixelsPerSecond: CGFloat
    let currentTime: Double
    let duration: Double
    let contentRevision: Int
    let contentSize: CGSize
    let onScrubStart: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let content: Content

    init(
        pixelsPerSecond: Binding<CGFloat>,
        currentTime: Double,
        duration: Double,
        contentRevision: Int,
        contentSize: CGSize,
        onScrubStart: @escaping () -> Void,
        onScrubChanged: @escaping (Double) -> Void,
        onScrubEnd: @escaping (Double) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        _pixelsPerSecond = pixelsPerSecond
        self.currentTime = currentTime
        self.duration = duration
        self.contentRevision = contentRevision
        self.contentSize = contentSize
        self.onScrubStart = onScrubStart
        self.onScrubChanged = onScrubChanged
        self.onScrubEnd = onScrubEnd
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = true
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear

        let host = context.coordinator.hostingController
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = true
        scrollView.addSubview(host.view)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        scrollView.addGestureRecognizer(pinch)
        context.coordinator.pinchRecognizer = pinch

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.clampZoom(in: scrollView)
        context.coordinator.updateHostedContentIfNeeded(content, contentSize: contentSize)
        context.coordinator.hostingController.view.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize

        let activePixelsPerSecond = context.coordinator.parent.pixelsPerSecond
        let maxX = max(contentSize.width - scrollView.bounds.width, 0)
        let targetX = min(max(CGFloat(currentTime) * activePixelsPerSecond, 0), maxX)
        let targetY = min(scrollView.contentOffset.y, max(contentSize.height - scrollView.bounds.height, 0))

        guard !context.coordinator.isUserInteracting else { return }
        guard abs(scrollView.contentOffset.x - targetX) > 0.5 || abs(scrollView.contentOffset.y - targetY) > 0.5 else { return }
        guard context.coordinator.shouldApplyProgrammaticScroll(targetX: targetX, targetY: targetY) else { return }

        context.coordinator.isProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: false)
        context.coordinator.isProgrammaticScroll = false
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: TimelineScrollContainer
        let hostingController: UIHostingController<Content>
        var pinchRecognizer: UIPinchGestureRecognizer?
        var pinchStartPixelsPerSecond: CGFloat = 88
        var pinchAnchorTime: Double = 0
        var isProgrammaticScroll = false
        var isUserInteracting = false
        private var hostedContentRevision: Int
        private var hostedContentSize: CGSize
        private var hostedPixelsPerSecond: CGFloat
        private var lastProgrammaticScrollTime: CFTimeInterval = 0
        private var pendingProgrammaticScrollTarget: CGPoint = .zero
        private let maximumPixelsPerSecond: CGFloat = 280

        init(parent: TimelineScrollContainer) {
            self.parent = parent
            self.hostingController = UIHostingController(rootView: parent.content)
            self.hostedContentRevision = parent.contentRevision
            self.hostedContentSize = parent.contentSize
            self.hostedPixelsPerSecond = parent.pixelsPerSecond
        }

        func updateHostedContentIfNeeded(_ content: Content, contentSize: CGSize) {
            let zoomChanged = abs(hostedPixelsPerSecond - parent.pixelsPerSecond) > 0.1
            guard hostedContentRevision != parent.contentRevision ||
                    hostedContentSize != contentSize ||
                    zoomChanged
            else { return }

            hostingController.rootView = content
            hostedContentRevision = parent.contentRevision
            hostedContentSize = contentSize
            hostedPixelsPerSecond = parent.pixelsPerSecond
        }

        func shouldApplyProgrammaticScroll(targetX: CGFloat, targetY: CGFloat) -> Bool {
            let now = CACurrentMediaTime()
            let target = CGPoint(x: targetX, y: targetY)
            let targetChangedMeaningfully = abs(target.x - pendingProgrammaticScrollTarget.x) > 8 ||
                abs(target.y - pendingProgrammaticScrollTarget.y) > 8
            pendingProgrammaticScrollTarget = target
            guard targetChangedMeaningfully || now - lastProgrammaticScrollTime >= 1.0 / 30.0 else {
                return false
            }
            lastProgrammaticScrollTime = now
            return true
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserInteracting = true
            EditorHaptics.scrubStart()
            parent.onScrubStart()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll, isUserInteracting || scrollView.isDragging || scrollView.isDecelerating else { return }
            let time = min(max(Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1)), 0), parent.duration)
            parent.onScrubChanged(time)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            finishScrub(scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishScrub(scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isProgrammaticScroll = false
        }

        private func finishScrub(_ scrollView: UIScrollView) {
            let time = min(max(Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1)), 0), parent.duration)
            parent.onScrubEnd(time)
            isUserInteracting = false
            EditorHaptics.editCommit()
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }

            switch recognizer.state {
            case .began:
                isUserInteracting = true
                EditorHaptics.scrubStart()
                parent.onScrubStart()
                pinchStartPixelsPerSecond = parent.pixelsPerSecond
                pinchAnchorTime = Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1))
            case .changed:
                parent.pixelsPerSecond = clampedPixelsPerSecond(pinchStartPixelsPerSecond * recognizer.scale, in: scrollView)
                keepPinchAnchorCentered(in: scrollView)
            case .ended, .cancelled, .failed:
                parent.pixelsPerSecond = clampedPixelsPerSecond(pinchStartPixelsPerSecond * recognizer.scale, in: scrollView)
                keepPinchAnchorCentered(in: scrollView)
                let time = min(max(Double(scrollView.contentOffset.x / max(parent.pixelsPerSecond, 1)), 0), parent.duration)
                parent.onScrubEnd(time)
                isUserInteracting = false
                EditorHaptics.editCommit()
            default:
                break
            }
        }

        func clampZoom(in scrollView: UIScrollView) {
            let clamped = clampedPixelsPerSecond(parent.pixelsPerSecond, in: scrollView)
            guard abs(clamped - parent.pixelsPerSecond) > 0.1 else { return }
            parent.pixelsPerSecond = clamped
        }

        private func clampedPixelsPerSecond(_ value: CGFloat, in scrollView: UIScrollView) -> CGFloat {
            min(max(value, minimumPixelsPerSecond(in: scrollView)), maximumPixelsPerSecond)
        }

        private func minimumPixelsPerSecond(in scrollView: UIScrollView) -> CGFloat {
            4
        }

        private func keepPinchAnchorCentered(in scrollView: UIScrollView) {
            let targetX = CGFloat(pinchAnchorTime) * parent.pixelsPerSecond
            let maxX = max(parent.contentSize.width - scrollView.bounds.width, 0)
            let clampedX = min(max(targetX, 0), maxX)
            isProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: clampedX, y: scrollView.contentOffset.y), animated: false)
            isProgrammaticScroll = false
            let time = min(max(Double(clampedX / max(parent.pixelsPerSecond, 1)), 0), parent.duration)
            parent.onScrubChanged(time)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private struct TimelineInsertionGapRow: View {
    let kind: TrackKind
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(MotionaryTheme.accent.opacity(0.72), style: StrokeStyle(lineWidth: 1.3, dash: [7, 5]))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((kind == .audio ? MotionaryTheme.audio : MotionaryTheme.video).opacity(0.18))
            )
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .padding(.leading, 114)
            .padding(.trailing, 10)
            .allowsHitTesting(false)
    }
}

private struct TimelineClipInteractionTarget: View {
    let onSelect: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value?) -> Void

    @State private var isLongPressArmed = false

    var body: some View {
        Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isLongPressArmed else { return }
                onSelect()
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.34, maximumDistance: 10)
                    .onEnded { _ in
                        isLongPressArmed = true
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard isLongPressArmed else { return }
                        onDragChanged(value)
                    }
                    .onEnded { value in
                        defer { isLongPressArmed = false }
                        guard isLongPressArmed else {
                            onDragEnded(nil)
                            return
                        }
                        onDragEnded(value)
                    }
            )
    }
}

private struct TimelineTrackRow: View {
    let track: TimelineTrack
    let trackIndex: Int
    let trackCount: Int
    let selectedClipID: UUID?
    let activeClipID: UUID?
    let projectDuration: Double
    let pixelsPerSecond: CGFloat
    let centerPadding: CGFloat
    let height: CGFloat
    let rowStride: CGFloat
    let onSelectTrack: () -> Void
    let onSelectClip: (UUID) -> Void
    let onBeginEditClip: (UUID) -> Void
    let onMoveClip: (UUID, Double, Int, Int?, Bool) -> TimelinePlacementResult?
    let onPreviewMoveClip: (UUID, Double, Int, Int?) -> TimelinePlacementResult?
    let onTrimStart: (UUID, Double, TimelineClip?, Bool) -> TimelineTrimResult?
    let onPreviewTrimStart: (UUID, Double, TimelineClip?) -> TimelineTrimResult?
    let onTrimEnd: (UUID, Double, TimelineClip?, Bool) -> TimelineTrimResult?
    let onPreviewTrimEnd: (UUID, Double, TimelineClip?) -> TimelineTrimResult?
    let onFinishInteractiveEdit: () -> Void
    let onMoveTrack: (UUID, Int) -> Void
    let onClipDragChanged: (TimelineClipDragState?) -> Void

    @State private var trackDragOffset: CGFloat = 0
    @State private var isTrackDragArmed = false

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: onSelectTrack) {
                HStack(spacing: 7) {
                    Image(systemName: track.kind == .visual ? "square.stack.3d.up" : "waveform")
                        .font(.caption)
                    Text(track.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(MotionaryTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(width: 104, height: height, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .offset(x: 10, y: trackDragOffset)
            .gesture(
                LongPressGesture(minimumDuration: 0.32, maximumDistance: 12)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard case .second(true, let drag?) = value else { return }
                        if !isTrackDragArmed {
                            isTrackDragArmed = true
                            timelineDragHaptic()
                        }
                        trackDragOffset = drag.translation.height
                    }
                    .onEnded { value in
                        defer {
                            isTrackDragArmed = false
                            withAnimation(.snappy(duration: 0.18)) {
                                trackDragOffset = 0
                            }
                        }
                        guard case .second(true, let drag?) = value else { return }
                        let target = min(
                            max(trackIndex + Int((drag.translation.height / rowStride).rounded()), 0),
                            max(trackCount - 1, 0)
                        )
                        onMoveTrack(track.id, target)
                    }
            )
            .zIndex(trackDragOffset == 0 ? 0 : 4)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .frame(width: max(CGFloat(projectDuration) * pixelsPerSecond, 0), height: height)
                .offset(x: centerPadding)

            ForEach(track.clips) { clip in
                TimelineClipBlock(
                    clip: clip,
                    isSelected: selectedClipID == clip.id,
                    isGhosted: activeClipID == clip.id,
                    pixelsPerSecond: pixelsPerSecond,
                    height: height - 8,
                    rowStride: rowStride,
                    sourceTrackIndex: trackIndex,
                    trackCount: trackCount,
                    onSelect: { onSelectClip(clip.id) },
                    onBeginEdit: { onBeginEditClip(clip.id) },
                    onMove: { start, targetIndex, insertionIndex, interactive in onMoveClip(clip.id, start, targetIndex, insertionIndex, interactive) },
                    onPreviewMove: { start, targetIndex, insertionIndex in onPreviewMoveClip(clip.id, start, targetIndex, insertionIndex) },
                    onTrimStart: { delta, baseline, interactive in onTrimStart(clip.id, delta, baseline, interactive) },
                    onPreviewTrimStart: { delta, baseline in onPreviewTrimStart(clip.id, delta, baseline) },
                    onTrimEnd: { delta, baseline, interactive in onTrimEnd(clip.id, delta, baseline, interactive) },
                    onPreviewTrimEnd: { delta, baseline in onPreviewTrimEnd(clip.id, delta, baseline) },
                    onFinishInteractiveEdit: onFinishInteractiveEdit,
                    onClipDragChanged: onClipDragChanged
                )
                .offset(x: centerPadding + CGFloat(clip.timelineStart) * pixelsPerSecond)
            }
        }
        .frame(height: height)
    }
}

private struct TimelineTrimPreview {
    let clip: TimelineClip
    let result: TimelineTrimResult
}

private struct TimelineClipBlock: View {
    let clip: TimelineClip
    let isSelected: Bool
    let isGhosted: Bool
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let rowStride: CGFloat
    let sourceTrackIndex: Int
    let trackCount: Int
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onMove: (Double, Int, Int?, Bool) -> TimelinePlacementResult?
    let onPreviewMove: (Double, Int, Int?) -> TimelinePlacementResult?
    let onTrimStart: (Double, TimelineClip?, Bool) -> TimelineTrimResult?
    let onPreviewTrimStart: (Double, TimelineClip?) -> TimelineTrimResult?
    let onTrimEnd: (Double, TimelineClip?, Bool) -> TimelineTrimResult?
    let onPreviewTrimEnd: (Double, TimelineClip?) -> TimelineTrimResult?
    let onFinishInteractiveEdit: () -> Void
    let onClipDragChanged: (TimelineClipDragState?) -> Void

    @State private var isClipDragArmed = false
    @State private var dragStartTimelineStart: Double?
    @State private var dragStartTrackIndex: Int?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragPreview: TimelinePlacementResult?
    @State private var trimBaseline: TimelineClip?
    @State private var trimPreview: TimelineTrimPreview?
    @State private var committedInteractiveEdit = false
    @State private var activeSnapKey: String?
    @State private var lastSnapFeedbackKey: String?
    @State private var lastSnapFeedbackAt: Date = .distantPast

    var body: some View {
        let previewClip = displayedClip
        let displayWidth = max(CGFloat(previewClip.sourceRange.duration) * pixelsPerSecond, 6)
        let displayOffsetX = CGFloat(previewClip.timelineStart - clip.timelineStart) * pixelsPerSecond
        let isEditing = isClipDragArmed || trimBaseline != nil

        TimelineClipFill(
            clip: previewClip,
            width: displayWidth,
            height: height,
            pixelsPerSecond: pixelsPerSecond
        )
        .frame(width: displayWidth, height: height)
        .foregroundStyle(Color.black.opacity(0.88))
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(clip.mediaType == .audio ? MotionaryTheme.audio : MotionaryTheme.video)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.white : .clear, lineWidth: 2)
        }
        .overlay(alignment: .leading) {
            if isSelected {
                TrimHandle(edge: .leading)
                    .offset(x: -3)
                    .gesture(trimStartGesture)
            }
        }
        .overlay(alignment: .trailing) {
            if isSelected {
                TrimHandle(edge: .trailing)
                    .offset(x: 3)
                    .gesture(trimEndGesture)
            }
        }
        .overlay {
            TimelineClipInteractionTarget(
                onSelect: {
                    guard !isEditing else { return }
                    EditorHaptics.selection()
                    onSelect()
                },
                onDragChanged: { drag in
                    updateDragPreview(with: drag)
                },
                onDragEnded: { drag in
                    guard let drag else {
                        finishTimelineGesture()
                        return
                    }
                    finishDrag(with: drag)
                }
            )
        }
        .opacity(isGhosted ? 0.18 : 1)
        .offset(x: isGhosted ? 0 : displayOffsetX, y: trimBaseline != nil ? 0 : 0)
        .scaleEffect(isEditing ? 1.025 : 1)
        .shadow(color: .black.opacity(isEditing ? 0.28 : 0), radius: 12, y: 5)
        .zIndex(isEditing ? 8 : 0)
        .transaction { transaction in
            if isEditing {
                transaction.animation = nil
            }
        }
        .animation(.snappy(duration: 0.18), value: isSelected)
        .onDisappear {
            finishTimelineGesture()
        }
    }

    private var displayedClip: TimelineClip {
        var previewClip = trimPreview?.clip ?? clip
        if isClipDragArmed, let dragPreview {
            previewClip.timelineStart = dragPreview.start
        }
        return previewClip
    }

    private var clipKind: TrackKind {
        clip.mediaType == .audio ? .audio : .visual
    }

    private func finishDrag(with drag: DragGesture.Value) {
        if let dragStartTimelineStart {
            let start = dragStartTimelineStart + Double(drag.translation.width / max(pixelsPerSecond, 1))
            let target = targetTrack(for: drag.translation.height)
            let result = onMove(start, target.trackIndex, target.insertionIndex, true)
            committedInteractiveEdit = true
            updateSnapHaptic(kind: "move", snapped: result?.snapped == true, value: result?.start)
        }
        finishTimelineGesture()
    }

    private var trimStartGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let baseline = beginTrimIfNeeded()
                let seconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                guard let result = onPreviewTrimStart(seconds, baseline) else { return }
                trimPreview = TimelineTrimPreview(
                    clip: clipApplyingTrimStart(result, to: baseline),
                    result: result
                )
                updateSnapHaptic(kind: "trim-start", snapped: result.snapped, value: result.edgeTime)
            }
            .onEnded { value in
                if let trimBaseline {
                    let seconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                    let result = onTrimStart(seconds, trimBaseline, true)
                    committedInteractiveEdit = true
                    updateSnapHaptic(kind: "trim-start", snapped: result?.snapped == true, value: result?.edgeTime)
                }
                finishTimelineGesture()
            }
    }

    private var trimEndGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let baseline = beginTrimIfNeeded()
                let seconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                guard let result = onPreviewTrimEnd(seconds, baseline) else { return }
                trimPreview = TimelineTrimPreview(
                    clip: clipApplyingTrimEnd(result, to: baseline),
                    result: result
                )
                updateSnapHaptic(kind: "trim-end", snapped: result.snapped, value: result.edgeTime)
            }
            .onEnded { value in
                if let trimBaseline {
                    let seconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                    let result = onTrimEnd(seconds, trimBaseline, true)
                    committedInteractiveEdit = true
                    updateSnapHaptic(kind: "trim-end", snapped: result?.snapped == true, value: result?.edgeTime)
                }
                finishTimelineGesture()
            }
    }

    private func updateDragPreview(with drag: DragGesture.Value) {
        if dragStartTimelineStart == nil {
            dragStartTimelineStart = clip.timelineStart
            dragStartTrackIndex = sourceTrackIndex
            dragPreview = TimelinePlacementResult(start: clip.timelineStart, trackIndex: sourceTrackIndex, snapped: false)
            isClipDragArmed = true
            EditorHaptics.dragStart()
            onBeginEdit()
        }

        let start = (dragStartTimelineStart ?? clip.timelineStart) + Double(drag.translation.width / max(pixelsPerSecond, 1))
        let target = targetTrack(for: drag.translation.height)
        let result = onPreviewMove(start, target.trackIndex, target.insertionIndex)
        dragTranslation = drag.translation
        let placement = result ?? TimelinePlacementResult(start: max(0, start), trackIndex: target.trackIndex, snapped: false)
        dragPreview = placement
        var overlayClip = clip
        overlayClip.timelineStart = placement.start
        onClipDragChanged(TimelineClipDragState(
            clipID: clip.id,
            clipKind: clipKind,
            targetTrackIndex: placement.trackIndex,
            insertionTrackIndex: target.insertionIndex,
            sourceTrackIndex: sourceTrackIndex,
            translationY: drag.translation.height,
            overlayClip: overlayClip
        ))
        updateSnapHaptic(kind: "move", snapped: result?.snapped == true, value: result?.start)
    }

    private func beginTrimIfNeeded() -> TimelineClip {
        if let trimBaseline {
            return trimBaseline
        }

        trimBaseline = clip
        EditorHaptics.trimStart()
        onBeginEdit()
        return clip
    }

    private func targetTrack(for translationY: CGFloat) -> (trackIndex: Int, insertionIndex: Int?) {
        let base = dragStartTrackIndex ?? sourceTrackIndex
        let rowPosition = CGFloat(base) + translationY / max(rowStride, 1)
        let nearestTrack = min(max(Int(rowPosition.rounded()), 0), max(trackCount - 1, 0))
        let lowerSlot = min(max(Int(floor(rowPosition)) + 1, 0), trackCount)
        let fraction = rowPosition - floor(rowPosition)
        let isBetweenExistingRows = lowerSlot > 0 && lowerSlot < trackCount && abs(fraction - 0.5) < 0.24
        let isPastBottom = rowPosition > CGFloat(trackCount - 1) + 0.56
        let isPastTop = rowPosition < -0.56

        if isBetweenExistingRows {
            return (lowerSlot, lowerSlot)
        }
        if isPastBottom {
            return (trackCount, trackCount)
        }
        if isPastTop {
            return (0, 0)
        }
        return (nearestTrack, nil)
    }

    private func clipApplyingTrimStart(_ result: TimelineTrimResult, to baseline: TimelineClip) -> TimelineClip {
        var preview = baseline
        preview.timelineStart = result.edgeTime
        preview.sourceRange = TimeRangeValue(
            start: baseline.sourceRange.start + result.appliedDelta,
            duration: max(baseline.sourceRange.duration - result.appliedDelta, 0.1)
        )
        return preview
    }

    private func clipApplyingTrimEnd(_ result: TimelineTrimResult, to baseline: TimelineClip) -> TimelineClip {
        var preview = baseline
        preview.sourceRange = TimeRangeValue(
            start: baseline.sourceRange.start,
            duration: max(baseline.sourceRange.duration + result.appliedDelta, 0.1)
        )
        return preview
    }

    private func finishTimelineGesture() {
        let hadInteraction = isClipDragArmed || trimBaseline != nil
        if committedInteractiveEdit {
            onFinishInteractiveEdit()
            EditorHaptics.editCommit()
        }

        isClipDragArmed = false
        dragStartTimelineStart = nil
        dragStartTrackIndex = nil
        dragTranslation = .zero
        dragPreview = nil
        trimBaseline = nil
        trimPreview = nil
        committedInteractiveEdit = false
        activeSnapKey = nil
        if hadInteraction {
            onClipDragChanged(nil)
        }
    }

    private func updateSnapHaptic(kind: String, snapped: Bool, value: Double?) {
        let key = snapped ? "\(kind)-\(Int(((value ?? 0) * 1000).rounded()))" : nil
        let previousKey = activeSnapKey
        activeSnapKey = key
        guard let key, key != previousKey else { return }

        let now = Date()
        if key == lastSnapFeedbackKey,
           now.timeIntervalSince(lastSnapFeedbackAt) < 0.35 {
            return
        }

        lastSnapFeedbackKey = key
        lastSnapFeedbackAt = now
        EditorHaptics.snap()
    }
}

private enum TrimHandleEdge {
    case leading
    case trailing
}

private struct TimelineClipFill: View {
    let clip: TimelineClip
    let width: CGFloat
    let height: CGFloat
    let pixelsPerSecond: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var waveformSamples: [CGFloat] = []

    var body: some View {
        let thumbnailWidth = timelineThumbnailWidth
        let thumbnailCount = max(Int(ceil(width / max(thumbnailWidth, 1))) + 1, 1)
        let waveformCount = quantizedWaveformSampleCount

        ZStack {
            if clip.mediaType == .audio {
                TimelineWaveformView(samples: activeWaveformSamples)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<thumbnailCount, id: \.self) { index in
                            TimelineThumbnailTile(
                                clip: clip,
                                tileIndex: index,
                                tileWidth: thumbnailWidth,
                                height: height,
                                pixelsPerSecond: pixelsPerSecond,
                                displayScale: displayScale
                            )
                            .frame(width: thumbnailWidth, height: height)
                        }
                    }
                }
                .scrollDisabled(true)
                .allowsHitTesting(false)
                .frame(width: width, height: height, alignment: .leading)
                .clipped()
            }

        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: taskID) {
            let requestID = taskID
            if clip.mediaType == .audio {
                let samples = await TimelineAudioWaveformLoader.samples(
                    for: clip,
                    targetCount: waveformCount
                )
                guard !Task.isCancelled, requestID == taskID else { return }
                waveformSamples = samples
            }
        }
    }

    private var activeWaveformSamples: [CGFloat] {
        if !waveformSamples.isEmpty {
            return waveformSamples
        }
        return Array(repeating: 0.02, count: quantizedWaveformSampleCount)
    }

    private var timelineThumbnailWidth: CGFloat {
        let storedSize = clip.source.naturalSize?.cgSize ?? CGSize(width: 16, height: 9)
        let naturalSize = CGSize(width: max(abs(storedSize.width), 1), height: max(abs(storedSize.height), 1))
        let aspectRatio = min(max(naturalSize.width / max(naturalSize.height, 1), 0.35), 4)
        return max(height * aspectRatio, 24)
    }

    private var quantizedWaveformSampleCount: Int {
        let rawCount = min(max(Int(width / 2), 80), 900)
        return max(Int((Double(rawCount) / 24).rounded()) * 24, 72)
    }

    private var taskID: String {
        [
            clip.id.uuidString,
            "\(Int(ceil(width / max(timelineThumbnailWidth, 1))))",
            "\(Int(timelineThumbnailWidth.rounded()))",
            "\(quantizedWaveformSampleCount)",
            "\(Int(displayScale.rounded()))",
            clip.source.url.path,
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration)
        ].joined(separator: "|")
    }
}

private struct TimelineThumbnailTile: View {
    let clip: TimelineClip
    let tileIndex: Int
    let tileWidth: CGFloat
    let height: CGFloat
    let pixelsPerSecond: CGFloat
    let displayScale: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.38), Color.white.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(width: tileWidth, height: height)
        .clipped()
        .task(id: taskID) {
            let loaded = await TimelineThumbnailLoader.tileImage(
                for: clip,
                tileIndex: tileIndex,
                tileWidth: tileWidth,
                tileHeight: height,
                pixelsPerSecond: pixelsPerSecond,
                displayScale: displayScale
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private var taskID: String {
        [
            clip.id.uuidString,
            "\(tileIndex)",
            "\(Int(tileWidth.rounded()))",
            "\(Int(height.rounded()))",
            "\(Int((displayScale * 100).rounded()))",
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration)
        ].joined(separator: "|")
    }
}

private struct TimelineWaveformView: View {
    let samples: [CGFloat]

    var body: some View {
        Canvas { context, size in
            guard size.width > 1, size.height > 1, !samples.isEmpty else { return }

            let midY = size.height * 0.5
            let maxAmplitude = max(size.height * 0.47, 1)
            let step = size.width / CGFloat(max(samples.count - 1, 1))
            var upper: [CGPoint] = []
            var lower: [CGPoint] = []
            upper.reserveCapacity(samples.count)
            lower.reserveCapacity(samples.count)

            for index in samples.indices {
                let x = CGFloat(index) * step
                let amplitude = min(max(samples[index], 0), 1) * maxAmplitude
                upper.append(CGPoint(x: x, y: midY - amplitude))
                lower.append(CGPoint(x: x, y: midY + amplitude))
            }

            var fillPath = Path()
            fillPath.move(to: lower[0])
            for point in lower.dropFirst() {
                fillPath.addLine(to: point)
            }
            for point in upper.reversed() {
                fillPath.addLine(to: point)
            }
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .color(Color(red: 0.16, green: 0.03, blue: 0.32))
            )
        }
    }
}

private actor TimelineThumbnailCache {
    static let shared = TimelineThumbnailCache()
    private var cache: [String: [UIImage]] = [:]
    private var tileCache: [String: UIImage] = [:]

    func images(for clip: TimelineClip, targetCount: Int, targetSize: CGSize, displayScale: CGFloat) async -> [UIImage] {
        let key = [
            clip.source.url.path,
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration),
            "\(targetCount)",
            "\(Int(targetSize.width.rounded()))",
            "\(Int(targetSize.height.rounded()))",
            "\(Int((displayScale * 100).rounded()))"
        ].joined(separator: "|")

        if let cached = cache[key] {
            return cached
        }

        let images = await TimelineThumbnailLoader.generateImages(
            for: clip,
            targetCount: targetCount,
            targetSize: targetSize,
            displayScale: displayScale
        )
        cache[key] = images
        return images
    }

    func tileImage(
        for clip: TimelineClip,
        tileIndex: Int,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        pixelsPerSecond: CGFloat,
        displayScale: CGFloat
    ) async -> UIImage? {
        let secondsPerTile = Double(tileWidth / max(pixelsPerSecond, 1))
        let localTime = clip.mediaType == .image
            ? 0
            : min(max(Double(tileIndex) * secondsPerTile + secondsPerTile * 0.5, 0), max(clip.sourceRange.duration - 0.001, 0))
        let sourceTime = clip.sourceRange.start + localTime
        let key = [
            clip.source.url.path,
            clip.mediaType.rawValue,
            "\(tileIndex)",
            String(format: "%.3f", sourceTime),
            "\(Int(tileWidth.rounded()))",
            "\(Int(tileHeight.rounded()))",
            "\(Int((displayScale * 100).rounded()))"
        ].joined(separator: "|")

        if let cached = tileCache[key] {
            return cached
        }

        let image = await TimelineThumbnailLoader.generateImage(
            for: clip,
            sourceTime: sourceTime,
            targetSize: CGSize(width: tileWidth, height: tileHeight),
            displayScale: displayScale
        )
        if let image {
            tileCache[key] = image
        }
        return image
    }
}

private enum TimelineThumbnailLoader {
    static func images(for clip: TimelineClip, targetCount: Int, targetSize: CGSize, displayScale: CGFloat) async -> [UIImage] {
        await TimelineThumbnailCache.shared.images(
            for: clip,
            targetCount: targetCount,
            targetSize: targetSize,
            displayScale: displayScale
        )
    }

    static func image(for clip: TimelineClip, timelineTime: Double, targetHeight: CGFloat) async -> UIImage? {
        let localTime = min(max(timelineTime - clip.timelineStart, 0), max(clip.sourceRange.duration - 0.01, 0))
        let sourceTime = clip.sourceRange.start + localTime
        return await generateImage(for: clip, sourceTime: sourceTime, targetHeight: targetHeight)
    }

    static func tileImage(
        for clip: TimelineClip,
        tileIndex: Int,
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        pixelsPerSecond: CGFloat,
        displayScale: CGFloat
    ) async -> UIImage? {
        await TimelineThumbnailCache.shared.tileImage(
            for: clip,
            tileIndex: tileIndex,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            pixelsPerSecond: pixelsPerSecond,
            displayScale: displayScale
        )
    }

    fileprivate static func generateImages(for clip: TimelineClip, targetCount: Int, targetSize: CGSize, displayScale: CGFloat) async -> [UIImage] {
        let url = clip.source.url
        let sourceStart = clip.sourceRange.start
        let sourceDuration = clip.sourceRange.duration
        return await Task<[UIImage], Never>.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: max(targetSize.width * displayScale, 12),
                height: max(targetSize.height * displayScale, 12)
            )
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let count = max(targetCount, 1)
            let duration = max(sourceDuration, 0.001)
            let safeEnd = max(sourceStart, sourceStart + duration - 0.001)
            return (0..<count).compactMap { index in
                let fraction = (Double(index) + 0.5) / Double(count)
                let seconds = min(max(sourceStart + duration * fraction, sourceStart), safeEnd)
                guard let cgImage = copyImage(
                    using: generator,
                    fallbackSeconds: [
                        seconds,
                        sourceStart + duration * 0.5,
                        sourceStart,
                        safeEnd,
                        min(sourceStart + 0.05, safeEnd),
                        0
                    ]
                ) else { return nil }
                return UIImage(cgImage: cgImage, scale: max(displayScale, 1), orientation: .up)
            }
        }.value
    }

    fileprivate static func generateImage(for clip: TimelineClip, sourceTime: Double, targetHeight: CGFloat) async -> UIImage? {
        let url = clip.source.url
        let sourceStart = clip.sourceRange.start
        return await Task<UIImage?, Never>.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: max(targetHeight * 2, 120), height: max(targetHeight * 2, 120))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            guard let cgImage = copyImage(
                using: generator,
                fallbackSeconds: [sourceTime, sourceStart, 0]
            ) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }

    fileprivate static func generateImage(for clip: TimelineClip, sourceTime: Double, targetSize: CGSize, displayScale: CGFloat) async -> UIImage? {
        let url = clip.source.url
        let sourceStart = clip.sourceRange.start
        let sourceEnd = clip.sourceRange.end
        return await Task<UIImage?, Never>.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: max(targetSize.width * displayScale, 24),
                height: max(targetSize.height * displayScale, 24)
            )
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
            guard let cgImage = copyImage(
                using: generator,
                fallbackSeconds: [
                    sourceTime,
                    min(max(sourceTime + 0.04, sourceStart), sourceEnd),
                    max(sourceStart, min(sourceEnd, sourceStart + max(clip.sourceRange.duration, 0.001) * 0.5)),
                    sourceStart,
                    0
                ]
            ) else {
                return nil
            }
            return UIImage(cgImage: cgImage, scale: max(displayScale, 1), orientation: .up)
        }.value
    }

    private static func copyImage(using generator: AVAssetImageGenerator, fallbackSeconds: [Double]) -> CGImage? {
        for seconds in fallbackSeconds {
            guard seconds.isFinite else { continue }
            let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return cgImage
            }
        }
        return nil
    }
}

private actor TimelineAudioWaveformCache {
    static let shared = TimelineAudioWaveformCache()
    private var cache: [String: [CGFloat]] = [:]

    func samples(for clip: TimelineClip, targetCount: Int) async -> [CGFloat] {
        let key = [
            clip.source.url.path,
            String(format: "%.3f", clip.sourceRange.start),
            String(format: "%.3f", clip.sourceRange.duration),
            "\(targetCount)"
        ].joined(separator: "|")

        if let cached = cache[key] {
            return cached
        }

        let samples = await TimelineAudioWaveformLoader.generateSamples(for: clip, targetCount: targetCount)
        cache[key] = samples
        return samples
    }
}

private enum TimelineAudioWaveformLoader {
    static func samples(for clip: TimelineClip, targetCount: Int) async -> [CGFloat] {
        await TimelineAudioWaveformCache.shared.samples(for: clip, targetCount: targetCount)
    }

    fileprivate static func generateSamples(for clip: TimelineClip, targetCount: Int) async -> [CGFloat] {
        let url = clip.source.url
        let sourceStart = clip.sourceRange.start
        let sourceDuration = clip.sourceRange.duration

        return await Task<[CGFloat], Never>.detached(priority: .utility) {
            let count = max(targetCount, 1)
            let fallback = fallbackSamples(count: count)
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset)
            else { return fallback }

            let sampleRate = 22_050.0
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else { return fallback }
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: max(sourceDuration, 0.05), preferredTimescale: 600)
            )
            reader.add(output)
            guard reader.startReading() else { return fallback }

            var buckets = Array(repeating: Float(0), count: count)
            let totalSamples = max(Int(max(sourceDuration, 0.05) * sampleRate), 1)
            var sampleIndex = 0
            var readSamples = 0

            while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length > 0 else { continue }

                var data = Data(count: length)
                let status = data.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: bytes.baseAddress!
                    )
                }
                guard status == kCMBlockBufferNoErr else { continue }

                data.withUnsafeBytes { bytes in
                    let samples = bytes.bindMemory(to: Int16.self)
                    for sample in samples {
                        let progress = min(Double(sampleIndex) / Double(totalSamples), 0.999)
                        let bucketIndex = min(Int(progress * Double(count)), count - 1)
                        let amplitude = min(Float(abs(Int32(sample))) / 32_767, 1)
                        buckets[bucketIndex] = max(buckets[bucketIndex], amplitude)
                        sampleIndex += 1
                        readSamples += 1
                    }
                }
            }

            guard reader.status == .completed || reader.status == .reading else { return fallback }
            guard readSamples > 0 else { return fallback }

            let peak = max(buckets.max() ?? 0, 0)
            guard peak > 0.0001 else {
                return Array(repeating: 0.015, count: count)
            }
            let gain = min(1 / peak, 3.2)
            let normalized = buckets.map { value in
                let boosted = CGFloat(value * gain)
                return min(max(sqrt(boosted), 0.015), 1)
            }
            return normalized
        }.value
    }

    private static func fallbackSamples(count: Int) -> [CGFloat] {
        Array(repeating: 0.015, count: count)
    }
}

private struct TrimHandle: View {
    let edge: TrimHandleEdge

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.92))
            .frame(width: 7, height: 30)
            .overlay {
                Capsule()
                    .fill(Color.black.opacity(0.16))
                    .frame(width: 2, height: 18)
            }
            .accessibilityLabel(edge == .leading ? "Trim start" : "Trim end")
    }
}

private struct CoreToolBar: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var selectedMediaItems: [PhotosPickerItem]
    @Binding var activePanel: CoreEditorPanel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedMediaItems, matching: .any(of: [.images, .videos])) {
                    CoreToolButtonContent(systemName: "plus", title: "Media", isProminent: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Import media")

                CoreToolButton(
                    systemName: "scissors",
                    title: "Cut",
                    isDisabled: viewModel.duration == 0
                ) {
                    viewModel.splitSelectedClip()
                }

                CoreToolButton(
                    systemName: "crop.rotate",
                    title: "Transform",
                    isSelected: activePanel == .transform,
                    isDisabled: viewModel.selectedClip == nil || viewModel.selectedClip?.mediaType == .audio
                ) {
                    activePanel = activePanel == .transform ? .timeline : .transform
                }

                CoreToolButton(
                    systemName: "waveform.badge.plus",
                    title: "Extract",
                    isDisabled: viewModel.selectedClip?.mediaType != .video
                ) {
                    viewModel.extractAudioFromSelectedClip()
                }

                CoreToolButton(
                    systemName: "doc.on.doc",
                    title: "Copy",
                    isDisabled: viewModel.selectedClip == nil
                ) {
                    viewModel.duplicateSelectedClip()
                }

                CoreToolButton(
                    systemName: "trash",
                    title: "Delete",
                    isDisabled: viewModel.selectedClip == nil
                ) {
                    viewModel.deleteSelectedClip()
                }

                Divider()
                    .frame(height: 38)
                    .overlay(Color.white.opacity(0.14))

                CanvasRatioMenu(viewModel: viewModel)
            }
            .padding(8)
        }
        .motionaryGlass(cornerRadius: 20)
    }
}

private struct CanvasRatioMenu: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        Menu {
            Button {
                EditorHaptics.tap()
                viewModel.setCanvasToSelectedClipOriginalRatio()
            } label: {
                Label("Original", systemImage: isOriginalSelected ? "checkmark" : "rectangle.ratio")
            }
            .disabled(!viewModel.canApplySelectedClipOriginalRatio)

            Divider()

            ForEach(CanvasRatioPreset.presets) { preset in
                Button {
                    EditorHaptics.tap()
                    viewModel.setCanvasPreset(preset)
                } label: {
                    Label(preset.title, systemImage: isSelected(preset) ? "checkmark" : "rectangle.ratio")
                }
            }
        } label: {
            CoreToolButtonContent(systemName: "rectangle.ratio", title: "Ratio")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Canvas ratio")
    }

    private var isOriginalSelected: Bool {
        guard let clip = viewModel.selectedClip,
              clip.mediaType != .audio,
              let size = clip.source.naturalSize?.cgSize
        else { return false }
        let width = max(Int(abs(size.width).rounded()), 1)
        let height = max(Int(abs(size.height).rounded()), 1)
        return viewModel.project.renderSettings.width == width &&
            viewModel.project.renderSettings.height == height
    }

    private func isSelected(_ preset: CanvasRatioPreset) -> Bool {
        viewModel.project.renderSettings.width == preset.width &&
            viewModel.project.renderSettings.height == preset.height
    }
}

private struct TransformWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.045))

            if let clip = viewModel.selectedClip, clip.mediaType != .audio {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "crop.rotate")
                            .foregroundStyle(MotionaryTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transform")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(MotionaryTheme.textPrimary)
                            Text(clip.name)
                                .font(.caption)
                                .foregroundStyle(MotionaryTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            EditorHaptics.tap()
                            viewModel.setSelectedTransform(
                                positionX: 0,
                                positionY: 0,
                                scale: 1,
                                rotationDegrees: 0,
                                opacity: 1
                            )
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 34, height: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MotionaryTheme.textPrimary)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityLabel("Reset transform")
                    }

                    ScrollView {
                        VStack(spacing: 14) {
                            InspectorSlider(
                                title: "X",
                                systemImage: "arrow.left.and.right",
                                value: binding(
                                    get: { $0.transform.positionX.baseValue },
                                    set: { viewModel.setSelectedTransform(positionX: $0) }
                                ),
                                range: -1...1,
                                step: 0.01,
                                onKeyframe: { viewModel.addKeyframe(.positionX) }
                            )

                            InspectorSlider(
                                title: "Y",
                                systemImage: "arrow.up.and.down",
                                value: binding(
                                    get: { $0.transform.positionY.baseValue },
                                    set: { viewModel.setSelectedTransform(positionY: $0) }
                                ),
                                range: -1...1,
                                step: 0.01,
                                onKeyframe: { viewModel.addKeyframe(.positionY) }
                            )

                            InspectorSlider(
                                title: "Scale",
                                systemImage: "arrow.up.left.and.arrow.down.right",
                                value: binding(
                                    get: { $0.transform.scale.baseValue },
                                    set: { viewModel.setSelectedTransform(scale: $0) }
                                ),
                                range: 0.05...4,
                                step: 0.01,
                                onKeyframe: { viewModel.addKeyframe(.scale) }
                            )

                            InspectorSlider(
                                title: "Rotation",
                                systemImage: "rotate.right",
                                value: binding(
                                    get: { $0.transform.rotationDegrees.baseValue },
                                    set: { viewModel.setSelectedTransform(rotationDegrees: $0) }
                                ),
                                range: -180...180,
                                step: 1,
                                onKeyframe: { viewModel.addKeyframe(.rotation) }
                            )

                            InspectorSlider(
                                title: "Opacity",
                                systemImage: "circle.lefthalf.filled",
                                value: binding(
                                    get: { $0.transform.opacity.baseValue },
                                    set: { viewModel.setSelectedTransform(opacity: $0) }
                                ),
                                range: 0...1,
                                step: 0.01,
                                onKeyframe: { viewModel.addKeyframe(.opacity) }
                            )
                        }
                        .padding(.bottom, 4)
                    }
                }
                .padding(16)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.title2)
                    Text("Select a visual clip")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(MotionaryTheme.textSecondary)
            }
        }
        .motionaryGlass(cornerRadius: 20)
    }

    private func binding(
        get: @escaping (TimelineClip) -> Double,
        set: @escaping (Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: {
                guard let clip = viewModel.selectedClip else { return 0 }
                return get(clip)
            },
            set: set
        )
    }
}

private struct TrimWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.045))

            if let clip = viewModel.selectedClip {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Trim")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(MotionaryTheme.textPrimary)
                            Text(clip.name)
                                .font(.caption)
                                .foregroundStyle(MotionaryTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(formatSeconds(clip.sourceRange.duration))s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(MotionaryTheme.textSecondary)
                    }

                    HStack(spacing: 10) {
                        TrimCommandButton(title: "Start -", systemName: "backward.frame") {
                            viewModel.trimSelectedStart(by: -0.1)
                        }
                        TrimCommandButton(title: "Start +", systemName: "forward.frame") {
                            viewModel.trimSelectedStart(by: 0.1)
                        }
                        TrimCommandButton(title: "Split", systemName: "scissors", prominent: true) {
                            viewModel.splitSelectedClip()
                        }
                        TrimCommandButton(title: "End -", systemName: "backward.end") {
                            viewModel.trimSelectedEnd(by: -0.1)
                        }
                        TrimCommandButton(title: "End +", systemName: "forward.end") {
                            viewModel.trimSelectedEnd(by: 0.1)
                        }
                    }

                    HStack {
                        ReadoutPill(title: "Source", value: "\(formatSeconds(clip.sourceRange.start))s")
                        ReadoutPill(title: "End", value: "\(formatSeconds(clip.sourceRange.end))s")
                        ReadoutPill(title: "Placed", value: "\(formatSeconds(clip.timelineStart))s")
                    }
                }
                .padding(16)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click")
                        .font(.title2)
                    Text("Select a clip")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(MotionaryTheme.textSecondary)
            }
        }
        .motionaryGlass(cornerRadius: 20)
    }
}

private struct TrimSliderBar: View {
    @ObservedObject var viewModel: EditorViewModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CompactIconButton(systemName: "chevron.down", title: "Back to timeline", action: onClose)

            Text("Position")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MotionaryTheme.textSecondary)

            Slider(
                value: Binding(
                    get: { viewModel.selectedClip?.timelineStart ?? 0 },
                    set: { viewModel.setSelectedClipTimelineStart($0) }
                ),
                in: 0...max(viewModel.duration + 5, 5),
                step: 0.05
            )
            .tint(MotionaryTheme.accent)
            .disabled(viewModel.selectedClip == nil)

            Text(formatSeconds(viewModel.selectedClip?.timelineStart ?? 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(MotionaryTheme.textPrimary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .motionaryGlass(cornerRadius: 20)
    }
}

private struct CoreToolButton: View {
    let systemName: String
    let title: String
    var isSelected = false
    var isDisabled = false
    var action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            CoreToolButtonContent(systemName: systemName, title: title, isProminent: isSelected)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .accessibilityLabel(title)
    }
}

private struct CoreToolButtonContent: View {
    let systemName: String
    let title: String
    var isProminent = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(isProminent ? Color.black : MotionaryTheme.textPrimary)
        .frame(width: 62, height: 54)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isProminent ? MotionaryTheme.accent : Color.white.opacity(0.075))
        }
    }
}

private struct CompactIconButton: View {
    let systemName: String
    let title: String
    var isProminent = false
    var isDisabled = false
    var action: () -> Void
    var isBordered = true

    var body: some View {
        ZStack {
            Button {
                EditorHaptics.tap()
                action()
            } label: {
                Image(systemName: systemName)
                    .font(.system(size: isBordered ? 16 : 18, weight: .semibold))
                    .frame(width: isBordered ? 40 : 18, height: isBordered ? 36 : 18)
                    .foregroundStyle(isBordered ? Color.clear : Color.primary)
                    .background {
                        if isBordered {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(isProminent ? MotionaryTheme.accent : Color.white.opacity(0.09))
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(title)
            if isBordered {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 36)
                    .foregroundStyle(isProminent ? Color.black : MotionaryTheme.textPrimary)
            }
        }
    }
}

private struct TrimCommandButton: View {
    let title: String
    let systemName: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(prominent ? Color.black : MotionaryTheme.textPrimary)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(prominent ? MotionaryTheme.accent : Color.white.opacity(0.075))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ReadoutPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(MotionaryTheme.textSecondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(MotionaryTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EditorBusyOverlay: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        if viewModel.isImporting || viewModel.isExporting {
            VStack(spacing: 12) {
                ProgressView(value: viewModel.isExporting ? viewModel.exportProgress : nil)
                    .tint(MotionaryTheme.accent)
                Text(viewModel.isExporting ? "Exporting \(Int(viewModel.exportProgress * 100))%" : "Importing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textPrimary)
            }
            .padding(18)
            .motionaryGlass(cornerRadius: 18)
        }
    }
}

private func formatClock(_ value: Double) -> String {
    let seconds = max(Int(value.rounded(.down)), 0)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

private func formatSeconds(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func aspectFitRect(in size: CGSize, aspectRatio: CGFloat) -> CGRect {
    guard size.width > 0, size.height > 0, aspectRatio > 0 else {
        return CGRect(origin: .zero, size: size)
    }

    let containerRatio = size.width / size.height
    let fittedSize: CGSize
    if containerRatio > aspectRatio {
        let height = size.height
        fittedSize = CGSize(width: height * aspectRatio, height: height)
    } else {
        let width = size.width
        fittedSize = CGSize(width: width, height: width / aspectRatio)
    }

    return CGRect(
        x: (size.width - fittedSize.width) * 0.5,
        y: (size.height - fittedSize.height) * 0.5,
        width: fittedSize.width,
        height: fittedSize.height
    )
}

private func timelineDragHaptic() {
    EditorHaptics.dragStart()
}

private enum EditorHaptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func dragStart() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)
    }

    static func trimStart() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.75)
    }

    static func scrubStart() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func snap() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
    }

    static func editCommit() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.65)
    }
}
