import SwiftUI

struct HapticsWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var playbackState: PlaybackState
    let item: HapticTimelineItem

    init(viewModel: EditorViewModel, item: HapticTimelineItem) {
        self.viewModel = viewModel
        _playbackState = ObservedObject(wrappedValue: viewModel.playbackState)
        self.item = item
    }

    var body: some View {
        EditorWorkspaceShell(
            title: "Haptics",
            systemImage: "waveform.path",
            isEnabled: canEdit,
            onTitleTap: { viewModel.auditionHaptic(item) },
            titleActionHint: "Plays the haptics for this clip",
            isTitleActionEnabled: HapticPlayback.isSupported,
            accessory: {
                if item.style != .impact {
                    SectionKeyframeButton(
                        viewModel: viewModel, itemID: item.id, section: .haptics, isEnabled: canEdit
                    )
                }
            },
            content: {
                VStack(alignment: .leading, spacing: MotionaryDesign.Spacing.lg) {
                    ForEach([KeyframeTarget.hapticIntensity, .hapticSharpness]) { target in
                        PropertyScrubber(viewModel: viewModel, haptic: item, target: target, isEnabled: canEdit)
                    }
                    if item.style != .impact {
                        EditorWorkspaceOnOffControl(title: "Pattern", isOn: item.isPatternEnabled) { enabled in
                            viewModel.updateHaptic(id: item.id) { $0.patternEnabled = enabled }
                        }
                        if item.isPatternEnabled {
                            ForEach([KeyframeTarget.hapticRepeat, .hapticLength]) { target in
                                PropertyScrubber(viewModel: viewModel, haptic: item, target: target, isEnabled: canEdit)
                            }
                        }
                    }
                }
                .disabled(!canEdit)
            }
        )
        .onChange(of: item) { viewModel.hapticPlayback.stopAudition() }
        .onDisappear { viewModel.hapticPlayback.stopAudition() }
    }

    private var canEdit: Bool {
        guard viewModel.selectedTimelineItemID == item.id,
            let location = viewModel.project.itemLocation(id: item.id),
            !viewModel.project.tracks[location.track].isLocked
        else { return false }
        return item.style == .impact || (item.timelineStart...item.timelineEnd).contains(playbackState.currentTime)
    }

}
