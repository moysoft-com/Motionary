// Project dashboard and new-project media import workflow.

import PhotosUI
import SwiftUI

struct HomeView: View {
    @AppStorage(AppPreferences.newProjectFrameRateKey)
    private var newProjectFrameRate = AppPreferences.defaultFrameRate
    @StateObject private var projectStore: ProjectStore
    @Environment(\.colorScheme) private var colorScheme
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
                                            projectStore.finalizeRename(projectID: project.id)
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
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Back to projects")
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
            .alert(
                "Motionary",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 7) {
                Text("Projects")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(MotionaryTheme.textPrimary)
            }

            Spacer()

            PhotosPicker(selection: $newProjectMediaItems, matching: .any(of: [.images, .videos])) {
                Label("New", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(MotionaryTheme.foregroundOnAccent)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(MotionaryTheme.accent)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .labelStyle(.titleAndIcon)
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
                    .foregroundStyle(MotionaryTheme.foregroundOnAccent)
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
            editorProject.renderSettings.frameRate = Int32(newProjectFrameRate)

            do {
                var importedByIndex: [Int: ImportedMedia] = [:]
                for batchStart in stride(from: 0, to: items.count, by: 3) {
                    try Task.checkCancellation()
                    let batchEnd = min(batchStart + 3, items.count)
                    let batch = Array(items[batchStart..<batchEnd].enumerated())
                    try await withThrowingTaskGroup(of: (Int, ImportedMedia).self) { group in
                        for (offset, item) in batch {
                            let index = batchStart + offset
                            group.addTask {
                                [
                                    importService,
                                    projectID = project.id,
                                    projectStore = self.projectStore
                                ] in
                                let imported = try await importService.importPhotosItem(
                                    item,
                                    projectID: projectID,
                                    projectStore: projectStore
                                )
                                return (index, imported)
                            }
                        }
                        for try await (index, imported) in group {
                            importedByIndex[index] = imported
                        }
                    }
                }

                for index in items.indices {
                    guard let imported = importedByIndex[index] else { continue }
                    appendInitialMedia(imported, to: &editorProject)
                }

                editorProject.synchronizeMediaLibrary()
                editorProject.updatedAt = Date()
                let content = ProjectContent(editorProject: editorProject)
                try await projectStore.repository.save(content, projectID: project.id)
                projectStore.recordSavedContent(content, projectID: project.id)
                selectedProject = projectStore.projects.first(where: { $0.id == project.id }) ?? project
            } catch {
                projectStore.deleteProject(with: project.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func appendInitialMedia(_ imported: ImportedMedia, to project: inout EditorProject) {
        let kind: TrackKind = imported.source.mediaType == .audio ? .audio : .visual
        let timelineStart =
            project.tracks
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
        var registeredClip = clip
        project.registerClipMedia(&registeredClip, source: imported.source)

        switch kind {
        case .undefined:
            return
        case .visual:
            let trackIndex: Int
            if let existingTrackIndex = project.tracks.firstIndex(where: { $0.kind == .visual }) {
                trackIndex = existingTrackIndex
            } else {
                project.tracks.insert(TimelineTrack(name: "Layer 1", kind: .visual), at: 0)
                trackIndex = 0
            }
            project.tracks[trackIndex].appendLegacyClip(registeredClip)

            let hasOnlyThisVisual =
                project.tracks
                .filter { $0.kind == .visual }
                .flatMap(\.clips)
                .count == 1
            if hasOnlyThisVisual, let naturalSize = imported.source.naturalSize?.cgSize {
                project.renderSettings = RenderSettings(
                    size: naturalSize,
                    frameRate: Int32(newProjectFrameRate)
                )
            }
        case .shape, .text:
            return
        case .audio:
            let trackIndex: Int
            if let existingTrackIndex = project.tracks.firstIndex(where: { $0.kind == .audio }) {
                trackIndex = existingTrackIndex
            } else {
                project.tracks.append(TimelineTrack(name: "Audio 1", kind: .audio))
                trackIndex = project.tracks.count - 1
            }
            project.tracks[trackIndex].appendLegacyClip(registeredClip)
        }
    }
}
