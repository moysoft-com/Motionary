// Project card presentation and asynchronously generated cover artwork.

import AVFoundation
import SwiftUI
import UIKit

struct ProjectCard: View {
    @Binding var project: Project
    let isRenaming: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onRenameCommit: () -> Void
    let onDelete: () -> Void
    @ObservedObject var projectStore: ProjectStore

    @State private var coverImage: UIImage?
    @FocusState private var isProjectNameFocused: Bool

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 10) {
                    cover
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    if isRenaming {
                        HStack(spacing: 8) {
                            TextField("Project name", text: $project.title)
                                .textFieldStyle(.plain)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(MotionaryTheme.textPrimary)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                                .submitLabel(.done)
                                .focused($isProjectNameFocused)
                                .onAppear { isProjectNameFocused = true }
                                .onSubmit(onRenameCommit)

                            Button(action: onRenameCommit) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(MotionaryTheme.accent)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Confirm project name")
                        }
                    } else {
                        HStack {
                            Text(project.title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(MotionaryTheme.textPrimary)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Menu {
                                Button("Rename", action: onRename)
                                Button("Delete", role: .destructive, action: onDelete)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }

                    Text("\(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                }
                .padding(14)
                .frame(alignment: .leading)
                .motionaryGlass(cornerRadius: 20)
            }
        }
        .buttonStyle(.plain)
        .task(id: project.updatedAt) {
            coverImage = await ProjectCoverLoader.cover(for: project, projectStore: projectStore)
        }
    }

    @ViewBuilder
    private var cover: some View {
        GeometryReader { geo in
            ZStack {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Color.primary.opacity(0.12), Color.primary.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "film.stack")
                            .font(.title2)
                            .foregroundStyle(MotionaryTheme.accent)
                    }
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

enum ProjectCoverLoader {
    static func cover(for project: Project, projectStore: ProjectStore) async -> UIImage? {
        guard let content = try? await projectStore.repository.load(projectID: project.id).content,
            let clip = content.editorProject.tracks
                .filter({ $0.kind == .visual })
                .flatMap(\.clips)
                .filter({ $0.mediaType != .audio })
                .min(by: { $0.timelineStart < $1.timelineStart })
        else { return nil }

        let editorProject = content.editorProject
        let url = projectStore.resolvedMediaURL(editorProject.mediaURL(for: clip), projectID: project.id)
        let sourceStart = clip.sourceRange.start
        return await Task<UIImage?, Never>.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 520, height: 520)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

            for seconds in [sourceStart, min(sourceStart + 0.05, clip.sourceRange.end), 0] {
                let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
                if let cgImage = try? await generator.image(at: time).image {
                    return UIImage(cgImage: cgImage)
                }
            }
            return nil
        }.value
    }
}
