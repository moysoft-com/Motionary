// Fullscreen release notes with Motionary's safe-area header and accent button.

import SwiftUI

struct WhatsNewView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let release: WhatsNewRelease
    let onAcknowledge: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading) {

                if !release.features.isEmpty {
                    VStack(alignment: .leading, spacing: MotionaryDesign.Spacing.lg) {
                        Text(verbatim: "What’s new?")
                            .font(.title3.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(release.features.indices, id: \.self) { index in
                            HStack(alignment: .firstTextBaseline, spacing: MotionaryDesign.Spacing.md) {
                                Text("-")
                                    .foregroundStyle(MotionaryTheme.textSecondary)
                                    .accessibilityHidden(true)
                                Text(verbatim: release.features[index])
                            }
                        }
                        .padding(.horizontal, MotionaryDesign.Spacing.xxl)

                    }
                    .font(.body)
                    .padding(.vertical, MotionaryDesign.Spacing.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    //                    .motionaryGlass(cornerRadius: MotionaryDesign.Radius.panel)
                }

                ForEach(release.sections.indices, id: \.self) { index in
                    releaseSection(release.sections[index])
                }
            }
            .frame(maxWidth: 500, alignment: .leading)
            .padding(.horizontal, MotionaryDesign.Spacing.xxl)
//            .padding(.vertical, MotionaryDesign.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(MotionaryTheme.textPrimary)
        .motionaryTopBar {
            HStack(spacing: 7) {
                Text(verbatim: release.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(MotionaryTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Image("MotionarySF")
                    .renderingMode(.template)
                    .symbolRenderingMode(.hierarchical)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(MotionaryTheme.accent)
                    .accessibilityHidden(true)
            }
            .padding(MotionaryDesign.Spacing.xxl)
        }
        .motionaryBottomBar {
            continueButton
        }
        .background {
            ZStack {
                MotionaryTheme.background(for: colorScheme)
                WhatsNewAccentMesh()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var continueButton: some View {
        Button {
            onAcknowledge()
            dismiss()
        } label: {
            Text(verbatim: release.buttonTitle)
                .font(.headline)
                .foregroundStyle(MotionaryTheme.foregroundOnAccent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background {
                    RoundedRectangle(cornerRadius: MotionaryDesign.Radius.graph)
                        .fill(MotionaryTheme.accent)
                        .motionaryGlassEffect(in: RoundedRectangle(cornerRadius: MotionaryDesign.Radius.graph))
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("whats-new-continue")
        .frame(maxWidth: 500)
        .padding(.horizontal, MotionaryDesign.Spacing.xxl)
        .padding(.vertical, MotionaryDesign.Spacing.lg)
        .frame(maxWidth: .infinity)
    }

    private func releaseSection(_ section: WhatsNewRelease.Section) -> some View {
        VStack(alignment: .leading, spacing: MotionaryDesign.Spacing.xs) {
            Text(verbatim: section.title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(
                (try? AttributedString(
                    markdown: section.body,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(section.body)
            )
            .font(.body)
            .foregroundStyle(MotionaryTheme.textSecondary)
            .padding(.horizontal, MotionaryDesign.Spacing.xxl)

        }
        .padding(.vertical, MotionaryDesign.Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        //        .motionaryGlass(cornerRadius: MotionaryDesign.Radius.panel)
    }
}

private struct WhatsNewAccentMesh: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var animationOrigin: ContinuousClock.Instant?
    @State private var entranceDuration = 1.5
    @State private var hapticPlayback = HapticPlayback()

    var body: some View {
        Group {
            if reduceMotion {
                mesh(at: 0, entrance: 1)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: scenePhase != .active)) { _ in
                    let elapsed = animationOrigin?.duration(to: .now).components
                    let seconds = Double(elapsed?.seconds ?? 0) + Double(elapsed?.attoseconds ?? 0) / 1e18
                    let progress = min(max(seconds / entranceDuration, 0), 1)
                    mesh(at: seconds, entrance: progress)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard !reduceMotion, animationOrigin == nil else { return }
            // Let the sheet become visible before the entrance starts.
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            if let url = Bundle.main.url(forResource: "WhatsNewEntranceHaptics", withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let items = try? JSONDecoder().decode([HapticTimelineItem].self, from: data),
                let end = items.map({ $0.timelineStart + $0.duration }).max(),
                end > 0,
                let track = try? HapticTrack.render(items, through: end)
            {
                entranceDuration = end
                animationOrigin = scenePhase == .active ? hapticPlayback.audition(track) ?? .now : .now
            } else {
                animationOrigin = .now
            }
        }
        .onDisappear { hapticPlayback.stopAudition() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { hapticPlayback.stopAudition() }
        }
    }

    private func mesh(at time: Double, entrance: Double) -> MeshGradient {
        // Both rows drift with independent phases and keep their order at every frame.
        let phase = Float(time * 0.65)
        let upperLeft = 0.39 + 0.12 * sin(phase)
        let upperRight = 0.25 + 0.10 * sin(phase - 1.7)
        let lowerLeft = 0.68 + 0.13 * sin(phase * 0.71 + 1.35)
        let lowerRight = 0.52 + 0.14 * sin(phase * 0.71 - 0.65)
        let leftDrift = 0.07 * cos(phase * 0.84)
        let rightDrift = 0.07 * sin(phase * 0.77 - 0.8)
        let accent = MotionaryTheme.accent
        let strength = colorScheme == .dark ? 0.40 : 0.46
        let levels: [Double] = [
            1.00, 0.85, 0.53, 0.29,
            0.90, 0.74, 0.47, 0.23,
            0.45, 0.33, 0.19, 0.12,
            0.13, 0.11, 0.08, 0.05
        ]
        // Reveal the vertex colors diagonally inside a stationary, full-screen mesh.
        let colors = levels.enumerated().map { index, level in
            let delay = 0.12 * Double(index % 4) + 0.09 * Double(index / 4)
            let progress = min(max((entrance - delay) / 0.36, 0), 1)
            let intensity = progress * progress * (3 - 2 * progress)
            return accent.opacity(strength * level * intensity)
        }

        return MeshGradient(
            width: 4,
            height: 4,
            points: [
                .init(0, 0), .init(0.33, 0), .init(0.67, 0), .init(1, 0),
                .init(0, 0.47), .init(0.33 + leftDrift, upperLeft),
                .init(0.67 + rightDrift, upperRight), .init(1, 0.22),
                .init(0, 0.78), .init(0.33 - leftDrift, lowerLeft),
                .init(0.67 - rightDrift, lowerRight), .init(1, 0.44),
                .init(0, 1), .init(0.33, 1), .init(0.67, 1), .init(1, 1)
            ],
            colors: colors
        )
    }
}

#if DEBUG
    #Preview("What’s New") {
        if let release = WhatsNewRelease.current() {
            WhatsNewView(release: release, onAcknowledge: {})
        } else {
            ContentUnavailableView(
                "No release notes",
                systemImage: "doc.text",
                description: Text("Add an entry for the current version in WhatsNew.json.")
            )
        }
    }
#endif
