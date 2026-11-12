// Segment-only easing editor. Keyframe times and values remain fixed.

import SwiftUI

struct KeyframeWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
    }

    var body: some View {
        Group {
            if let context = graphContext {
                EditorWorkspaceShell(
                    title: context.segment.section == .speed ? "Time Remapping" : context.segment.section.rawValue,
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                    isEnabled: context.isActive,
                    contentStyle: .fixed,
                    disablesContentWhenUnavailable: true,
                    accessory: {
                        Menu {
                            Button("Cut", systemImage: "scissors") {
                                EditorClipboard.graph = context.segment.interpolation
                                viewModel.setInterpolation(
                                    .linear,
                                    section: context.segment.section,
                                    startTime: context.segment.startTime
                                )
                            }
                            Button("Copy", systemImage: "doc.on.doc") {
                                EditorClipboard.graph = context.segment.interpolation
                            }
                            Button("Paste", systemImage: "doc.on.clipboard") {
                                guard let graph = EditorClipboard.graph else { return }
                                viewModel.setInterpolation(
                                    graph,
                                    section: context.segment.section,
                                    startTime: context.segment.startTime
                                )
                            }
                            .disabled(!context.isActive)
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                viewModel.setInterpolation(
                                    .linear,
                                    section: context.segment.section,
                                    startTime: context.segment.startTime
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 16, height: 16)
                                .offset(x: 7)
                                .frame(width: 36, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!context.isActive)
                        .accessibilityLabel("Graph options")
                    },
                    content: {
                        EditorEasingGraph(
                            viewModel: viewModel,
                            timelineStart: context.timelineStart,
                            range: context.segment.startTime...context.segment.endTime,
                            interpolation: context.segment.interpolation,
                            horizontalInset: 22,
                            exposesDefaultHandles: context.segment.section == .speed,
                            overshoot: context.segment.section == .speed ? .clamped(0...1) : .rubberBanded,
                            reversesVerticalAxis: reversesSourceTime(context.segment, in: context.item),
                            onHandleBegan: {},
                            onInterpolationChanged: { interpolation in
                                viewModel.setInterpolation(
                                    interpolation,
                                    section: context.segment.section,
                                    startTime: context.segment.startTime,
                                    interactive: true
                                )
                            },
                            onHandleEnded: {
                                viewModel.finishInteractiveEdit()
                                if context.segment.section == .speed {
                                    viewModel.refreshGraphSegment()
                                }
                            }
                        )

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(presets(for: context.segment.section)) { preset in
                                    EditorWorkspacePillButton(
                                        title: preset.title,
                                        isSelected: context.segment.interpolation == preset.interpolation
                                    ) {
                                        viewModel.setInterpolation(
                                            preset.interpolation,
                                            section: context.segment.section,
                                            startTime: context.segment.startTime
                                        )
                                    }
                                    .frame(width: 76)
                                }
                            }
                        }
                    }
                )
            } else {
                Color.clear
                    .motionaryGlass(cornerRadius: MotionaryDesign.Radius.panel)
            }
        }
    }

    private func reversesSourceTime(_ segment: KeyframeSegment, in item: TimelineItem) -> Bool {
        guard segment.section == .speed, case .media(let media) = item,
            let remap = media.speedMap.timeRemap
        else { return false }
        return remap.sourceTime(at: segment.startTime) > remap.sourceTime(at: segment.endTime)
    }

    private func presets(for section: KeyframeSection) -> [KeyframeCurvePreset] {
        section == .speed ? [.linear, .easeIn, .easeOut, .easeInOut, .hold, .fast, .slow] : KeyframeCurvePreset.allCases
    }

    private var graphContext:
        (
            item: TimelineItem,
            timelineStart: Double,
            segment: KeyframeSegment,
            isActive: Bool
        )?
    {
        guard let segment = viewModel.graphSegment ?? viewModel.displayedGraphSegment,
            let item = viewModel.project.item(id: segment.clipID)
        else { return nil }
        let isLocked = segment.section == .speed
            && viewModel.project.itemLocation(id: item.id).map { viewModel.project.tracks[$0.track].isLocked } == true
        return (item, item.timelineStart, segment, viewModel.graphSegment != nil && !isLocked)
    }
}

struct KeyframeDiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}
