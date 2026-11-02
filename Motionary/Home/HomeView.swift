// Project dashboard and new-project media import workflow.

import PhotosUI
import SwiftUI

private struct ProjectEditorSelection: Identifiable, Equatable {
    let project: Project
    let initialContent: ProjectContent

    var id: UUID { project.id }
}

struct HomeView: View {
    @AppStorage(AppPreferences.newProjectFrameRateKey)
    private var newProjectFrameRate = AppPreferences.defaultFrameRate
    @StateObject private var projectStore: ProjectStore
    @Binding private var searchText: String
    @Binding private var isSearchPresented: Bool
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSearchHeader = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedProject: ProjectEditorSelection?
    @State private var editingProjectID: UUID?
    @State private var newProjectMediaItems: [PhotosPickerItem] = []
    private let newProjectRequest: UUID?
    private let onEditorPresentationChange: (Bool) -> Void
    @State private var isMediaPickerPresented = false
    @State private var isHomeVisible = false
    @State private var lastPresentedNewProjectRequest: UUID?
    @State private var isCreatingProject = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.adaptive(minimum: 156), spacing: 12)
    ]

    init(
        projectStore: ProjectStore = ProjectStore(),
        newProjectRequest: UUID? = nil,
        searchText: Binding<String> = .constant(""),
        isSearchPresented: Binding<Bool> = .constant(false),
        onEditorPresentationChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.newProjectRequest = newProjectRequest
        self.onEditorPresentationChange = onEditorPresentationChange
        _projectStore = StateObject(wrappedValue: projectStore)
        _searchText = searchText
        _isSearchPresented = isSearchPresented
    }

    var body: some View {
        ZStack {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if projectStore.projects.isEmpty {
                            emptyState
                        } else if filteredProjects.isEmpty {
                            noSearchResults
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach($projectStore.projects) { $project in
                                    if matchesSearch(project.title) {
                                        ProjectCard(
                                            project: $project,
                                            isRenaming: editingProjectID == project.id,
                                            onOpen: {
                                                dismissProjectSearch()
                                                selectedProject = ProjectEditorSelection(
                                                    project: project,
                                                    initialContent: projectStore.bestAvailableContent(for: project)
                                                )
                                            },
                                            onRename: {
                                                dismissProjectSearch()
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
                                        .accessibilityIdentifier("home-project-card-\(project.id)")
                                        .onAppear {
                                            projectStore.warmContent(for: project)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .background { MotionaryTheme.background(for: colorScheme).ignoresSafeArea() }
            .motionaryTopBar {
                animatedDashboardHeader
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

            if let selectedProject {
                NavigationStack {
                    ProjectDetailView(
                        project: selectedProject.project,
                        projectStore: projectStore,
                        initialContent: selectedProject.initialContent,
                        onClose: {
                            self.selectedProject = nil
                        }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { MotionaryTheme.background(for: colorScheme).ignoresSafeArea() }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .onChange(of: selectedProject?.id, initial: true) { _, projectID in
            onEditorPresentationChange(projectID != nil)
        }
        .onChange(of: isSearchPresented, initial: true) { _, presented in
            if presented {
                selectedProject = nil
                editingProjectID = nil
            } else {
                isSearchFocused = false
            }
            showsSearchHeader = presented
        }
        .photosPicker(
            isPresented: $isMediaPickerPresented,
            selection: $newProjectMediaItems,
            matching: .any(of: [.images, .videos])
        )
        .onAppear { isHomeVisible = true }
        .onDisappear { isHomeVisible = false }
        .task(id: isHomeVisible && scenePhase == .active ? newProjectRequest : nil) {
            // A UIKit host can replace its root before the new SwiftUI tree
            // has a presenter. Consume each shortcut only after attachment.
            await Task.yield()
            guard !Task.isCancelled, let request = newProjectRequest,
                request != lastPresentedNewProjectRequest, !isCreatingProject else { return }
            dismissProjectSearch()
            selectedProject = nil
            editingProjectID = nil
            lastPresentedNewProjectRequest = request
            isMediaPickerPresented = true
        }
        .animation(.easeInOut(duration: 0.18), value: selectedProject?.id)
    }

    private var animatedDashboardHeader: some View {
        // Measure only the normal header. Overlay contents never change the
        // safe-area height, even while both transition layers are present.
        dashboardHeader
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                ZStack {
                    if showsSearchHeader {
                        projectSearchHeader
                            .transition(reduceMotion ? .opacity : .offset(y: 8).combined(with: .opacity))
                    } else {
                        dashboardHeader
                            .transition(reduceMotion ? .opacity : .offset(y: -8).combined(with: .opacity))
                    }
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.24), value: showsSearchHeader)
    }

    private var projectSearchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(MotionaryDesign.Typography.compactIcon)
                .foregroundStyle(MotionaryTheme.textSecondary)
            TextField("Search projects", text: $searchText)
                .accessibilityIdentifier("home-project-search-field")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout)
                .tint(MotionaryTheme.accent)
                .submitLabel(.search)
                .focused($isSearchFocused)
                .task {
                    guard isSearchPresented else { return }
                    isSearchFocused = true
                }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "delete.backward")
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .frame(width: 32, height: 44)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .foregroundStyle(MotionaryTheme.textPrimary)
        .background(MotionaryDesign.Surface.control(), in: Capsule())
        .motionaryGlass(cornerRadius: 24)
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
                            .motionaryGlassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
        }
    }

    private var filteredProjects: [Project] {
        projectStore.projects.filter { matchesSearch($0.title) }
    }

    private func dismissProjectSearch() {
        isSearchFocused = false
        isSearchPresented = false
        searchText = ""
    }

    private func matchesSearch(_ title: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedCaseInsensitiveContains(query)
    }

    private var noSearchResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(MotionaryTheme.accent)
            Text("No projects found")
                .font(.headline)
                .foregroundStyle(MotionaryTheme.textPrimary)
            Text("Try a different name.")
                .font(.subheadline)
                .foregroundStyle(MotionaryTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
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
                    .motionaryGlassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
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
                schedulePosterRender(for: editorProject, projectID: project.id)
                let savedProject = projectStore.projects.first(where: { $0.id == project.id }) ?? project
                selectedProject = ProjectEditorSelection(
                    project: savedProject,
                    initialContent: content
                )
            } catch {
                projectStore.deleteProject(with: project.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func schedulePosterRender(for project: EditorProject, projectID: UUID) {
        let outputURL = projectStore.posterURL(for: projectID)
        Task(priority: .utility) {
            do {
                try await ProjectPosterService.shared.renderPoster(
                    for: project,
                    outputURL: outputURL
                )
                guard !Task.isCancelled else { return }
                projectStore.notePosterChanged()
            } catch ProjectPosterError.noVisualContent {
                projectStore.removePoster(for: projectID)
            } catch {
                AppLogger.rendering.warning(
                    "Failed to render project poster: \(error.localizedDescription, privacy: .public)"
                )
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
