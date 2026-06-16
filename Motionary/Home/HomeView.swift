import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct HomeView: View {
    @StateObject private var projectStore: ProjectStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProject: Project?
    @State private var editingProjectID: UUID?
    @State private var newProjectMediaItems: [PhotosPickerItem] = []
    @State private var isCreatingProject = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.adaptive(minimum: 156), spacing: 12)
    ]

    init(projectStore: ProjectStore = ProjectStore()) {
        _projectStore = StateObject(wrappedValue: projectStore)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if projectStore.projects.isEmpty {
                            emptyState
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach($projectStore.projects) { $project in
                                    ProjectCard(
                                        project: $project,
                                        isRenaming: editingProjectID == project.id,
                                        onOpen: {
                                            selectedProject = project
                                        },
                                        onRename: {
                                            editingProjectID = project.id
                                        },
                                        onRenameCommit: {
                                            editingProjectID = nil
                                            projectStore.save()
                                        },
                                        onDelete: {
                                            projectStore.deleteProject(with: project.id)
                                        },
                                        projectStore: projectStore
                                    )
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .background { MotionaryTheme.background(for: colorScheme).ignoresSafeArea() }
            .navigationDestination(item: $selectedProject) { project in
                ProjectDetailView(project: project, projectStore: projectStore)
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                selectedProject = nil
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                        }
                    }
            }
            .safeAreaBar(edge: .top) {
                dashboardHeader
                    .padding(18)
            }
            .overlay {
                if isCreatingProject {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(MotionaryTheme.accent)
                        Text("Importing")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MotionaryTheme.textPrimary)
                    }
                    .padding(18)
                    .motionaryGlass(cornerRadius: 18)
                }
            }
            .onChange(of: newProjectMediaItems) { _, items in
                guard !items.isEmpty else { return }
                createProject(from: items)
                newProjectMediaItems = []
            }
            .alert("Motionary", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("Motionary")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(MotionaryTheme.textPrimary)

            Spacer()

            PhotosPicker(selection: $newProjectMediaItems, matching: .any(of: [.images, .videos])) {
                Label("New", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color.black)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(MotionaryTheme.accent)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(MotionaryTheme.accent)
            Text("Create a project")
                .font(.headline)
                .foregroundStyle(MotionaryTheme.textPrimary)
            PhotosPicker(selection: $newProjectMediaItems, matching: .any(of: [.images, .videos])) {
                Label("New Project", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color.black)
                    .background(MotionaryTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .motionaryGlass(cornerRadius: 24)
    }

    private func createProject(from items: [PhotosPickerItem]) {
        Task {
            isCreatingProject = true
            defer { isCreatingProject = false }

            let project = projectStore.addProject()
            let importService = MediaImportService()
            var editorProject = EditorProject.empty(title: project.title)

            do {
                for item in items {
                    let imported = try await importService.importPhotosItem(
                        item,
                        projectID: project.id,
                        projectStore: projectStore
                    )
                    appendInitialMedia(imported, to: &editorProject)
                }

                editorProject.updatedAt = Date()
                projectStore.saveContent(ProjectContent(editorProject: editorProject), for: project.id)
                selectedProject = projectStore.projects.first(where: { $0.id == project.id }) ?? project
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func appendInitialMedia(_ imported: ImportedMedia, to project: inout EditorProject) {
        let kind: TrackKind = imported.source.mediaType == .audio ? .audio : .visual
        let timelineStart = project.tracks
            .filter { $0.kind == kind }
            .flatMap(\.clips)
            .map(\.timelineEnd)
            .max() ?? 0
        let clip = TimelineClip(
            name: imported.storedURL.deletingPathExtension().lastPathComponent,
            source: imported.source,
            timelineStart: timelineStart,
            sourceRange: TimeRangeValue(start: 0, duration: imported.source.originalDuration)
        )

        switch kind {
        case .visual:
            let trackIndex: Int
            if let existingTrackIndex = project.tracks.firstIndex(where: { $0.kind == .visual }) {
                trackIndex = existingTrackIndex
            } else {
                project.tracks.insert(TimelineTrack(name: "Layer 1", kind: .visual), at: 0)
                trackIndex = 0
            }
            project.tracks[trackIndex].clips.append(clip)
            project.tracks[trackIndex].clips.sort { $0.timelineStart < $1.timelineStart }

            let hasOnlyThisVisual = project.tracks
                .filter { $0.kind == .visual }
                .flatMap(\.clips)
                .count == 1
            if hasOnlyThisVisual, let naturalSize = imported.source.naturalSize?.cgSize {
                project.renderSettings = RenderSettings(size: naturalSize)
            }
        case .audio:
            let trackIndex: Int
            if let existingTrackIndex = project.tracks.firstIndex(where: { $0.kind == .audio }) {
                trackIndex = existingTrackIndex
            } else {
                project.tracks.append(TimelineTrack(name: "Audio 1", kind: .audio))
                trackIndex = project.tracks.count - 1
            }
            project.tracks[trackIndex].clips.append(clip)
            project.tracks[trackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
        }
    }
}

private struct ProjectCard: View {
    @Binding var project: Project
    let isRenaming: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onRenameCommit: () -> Void
    let onDelete: () -> Void
    @ObservedObject var projectStore: ProjectStore

    @State private var coverImage: UIImage?

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 10) {
                    cover
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    
                    if isRenaming {
                        TextField("Project name", text: $project.title)
                            .textFieldStyle(.plain)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(MotionaryTheme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .onSubmit(onRenameCommit)
                    } else {
                        HStack {
                            Text(project.title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(MotionaryTheme.textPrimary)
                                .lineLimit(2)
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

private enum ProjectCoverLoader {
    static func cover(for project: Project, projectStore: ProjectStore) async -> UIImage? {
        guard let content = projectStore.loadContent(for: project.id),
              let clip = content.editorProject.tracks
                .filter({ $0.kind == .visual })
                .flatMap(\.clips)
                .filter({ $0.mediaType != .audio })
                .min(by: { $0.timelineStart < $1.timelineStart })
        else { return nil }

        let url = projectStore.resolvedMediaURL(clip.source.url, projectID: project.id)
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
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    return UIImage(cgImage: cgImage)
                }
            }
            return nil
        }.value
    }
}

extension ProjectStore {
    static func mockWithProjects() -> ProjectStore {
        let store = ProjectStore()
        store.projects = [
            Project(id: UUID(), title: "Demo Project", updatedAt: .now)
        ]
        return store
    }
}

#Preview {
    HomeView(projectStore: .mockWithProjects())
}
