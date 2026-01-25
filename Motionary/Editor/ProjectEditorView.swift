import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins

enum VideoEffect: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case sepia = "Sepia"
    case noir = "Noir"
    case chrome = "Chrome"

    var id: String { rawValue }
}

struct ProjectEditorView: View {
    let projectID: UUID
    @ObservedObject var projectStore: ProjectStore
    let initialContent: ProjectContent

    // MARK: - Player & Timeline State
    @State private var player: AVPlayer? = nil
    @State private var currentTime: Double = 0    // Virtual time (across all clips)
    @State private var totalTime: Double = 0        // Sum of all clip durations
    @State private var timeObserver: Any?
    @State private var isPlaying: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var wasPlayingBeforeScrub: Bool = false

    // MARK: - Clip Editing State
    @State private var clips: [Clip] = []
    @State private var selectedClipID: UUID? = nil

    // MARK: - Extra Footage Import State
    @State private var extraFootageItem: PhotosPickerItem? = nil
    @State private var isExtraImporting: Bool = false
    @State private var extraImportProgress: Double = 0.0

    // MARK: - Audio Import State
    @State private var isAudioImporterPresented: Bool = false
    @State private var audioImportError: String? = nil

    // MARK: - Export State
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var exportError: String? = nil
    @State private var exportURL: URL? = nil
    @State private var isShareSheetPresented = false
    @State private var exportSession: AVAssetExportSession? = nil

    // MARK: - Effects / Keyframes
    @State private var selectedEffect: VideoEffect = .none
    @State private var effectIntensity: Double = 0.6
    @State private var keyframes: [Keyframe] = []
    @State private var isRestoring = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                playerSection
                Spacer()
            }
            .padding(.bottom, 60)
            .contentShape(Rectangle())
            .onTapGesture { selectedClipID = nil }

            bottomClipActionMenu

            exportOverlay
            importOverlay
        }
        .toolbar {
            // Extra footage import plus button on the right.
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    exportVideo()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.white)
                }
                PhotosPicker(selection: $extraFootageItem, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "plus")
                        .foregroundColor(.white)
                }
                Button {
                    isAudioImporterPresented = true
                } label: {
                    Image(systemName: "waveform")
                        .foregroundColor(.white)
                }
            }
        }
        .alert("Export Error", isPresented: Binding<Bool>(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportError ?? "Unknown error.")
        }
        .alert("Audio Import Error", isPresented: Binding<Bool>(
            get: { audioImportError != nil },
            set: { if !$0 { audioImportError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(audioImportError ?? "Unknown error.")
        }
        .sheet(isPresented: $isShareSheetPresented, onDismiss: {
            exportURL = nil
        }) {
            if let exportURL = exportURL {
                ActivityView(activityItems: [exportURL])
            }
        }
        .onAppear { setupInitialComposition() }
        .onDisappear { persistContent() }
        .onChange(of: extraFootageItem) { oldValue, newItem in
            Task {
                guard let newItem = newItem else { return }
                isExtraImporting = true
                extraImportProgress = 0.0
                // Simulate progress updates for extra footage import.
                let progressTask = Task {
                    while !Task.isCancelled && extraImportProgress < 1.0 {
                        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 sec
                        await MainActor.run {
                            extraImportProgress += 0.05
                            if extraImportProgress > 1.0 { extraImportProgress = 1.0 }
                        }
                    }
                }
                // Try to load as image first.
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    if let videoURL = await convertImageToVideo(image: image, duration: 5.0) {
                        progressTask.cancel()
                        extraImportProgress = 1.0
                        appendExtraClip(from: videoURL, duration: 5.0)
                    }
                } else {
                    do {
                        if let data = try await newItem.loadTransferable(type: Data.self) {
                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
                            try data.write(to: tempURL)
                            let asset = AVURLAsset(url: tempURL)
                            let loadedDuration: CMTime = try await asset.load(.duration)
                            let duration = CMTimeGetSeconds(loadedDuration)
                            progressTask.cancel()
                            extraImportProgress = 1.0
                            appendExtraClip(from: tempURL, duration: duration)
                        }
                    } catch {
                        progressTask.cancel()
                        print("Error loading extra footage: \(error.localizedDescription)")
                    }
                }
                isExtraImporting = false
            }
        }
        .onChange(of: selectedEffect) { oldValue, _ in
            guard !isRestoring else { return }
            Task {
                await rebuildCompositionAsync(seekTo: currentTime)
            }
            persistContent()
        }
        .onChange(of: effectIntensity) { oldValue, _ in
            guard !isRestoring else { return }
            Task {
                await rebuildCompositionAsync(seekTo: currentTime)
            }
            persistContent()
        }
        .onChange(of: keyframes) { oldValue, _ in
            guard !isRestoring else { return }
            Task {
                await rebuildCompositionAsync(seekTo: currentTime)
            }
            persistContent()
        }
        .onChange(of: clips) { oldValue, _ in
            guard !isRestoring else { return }
            persistContent()
        }
        .fileImporter(
            isPresented: $isAudioImporterPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: url, to: tempURL)
                let asset = AVURLAsset(url: tempURL)
                Task {
                    do {
                        let loadedDuration: CMTime = try await asset.load(.duration)
                        let duration = CMTimeGetSeconds(loadedDuration)
                        appendExtraClip(from: tempURL, duration: duration, mediaType: .audio)
                    } catch {
                        audioImportError = error.localizedDescription
                    }
                }
            } catch {
                audioImportError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var playerSection: some View {
        if let player = player {
            PreviewRendererView(player: player)
                .frame(height: 300)
                .cornerRadius(12)
                .padding()

            ControlButtonsView(
                isPlaying: isPlaying,
                onCut: { performCut(at: currentTime) },
                onTogglePlay: { togglePlayPause() }
            )

            EditedTimelineView(
                clips: clips,
                currentTime: currentTime,
                totalTime: totalTime,
                selectedClipID: selectedClipID,
                onSelectClip: { clip in selectedClipID = clip?.id },
                onScrubStart: {
                    wasPlayingBeforeScrub = isPlaying
                    player.pause()
                    isPlaying = false
                    isScrubbing = true
                },
                onScrubChanged: { newTime in seekPlayer(to: newTime) },
                onScrubEnd: { newTime in
                    seekPlayer(to: newTime)
                    isScrubbing = false
                    if wasPlayingBeforeScrub {
                        if newTime >= totalTime { seekPlayer(to: 0) }
                        player.play()
                        isPlaying = true
                    }
                },
                onMoveClip: { fromIndex, toIndex in moveClip(from: fromIndex, to: toIndex) }
            )
            .frame(height: 120)

            EffectsPanelView(
                selectedEffect: $selectedEffect,
                effectIntensity: $effectIntensity,
                keyframes: $keyframes,
                totalTime: totalTime,
                canAddKeyframe: selectedEffect != .none && totalTime > 0,
                onAddKeyframe: { addKeyframe() },
                onClearKeyframes: {
                    keyframes.removeAll()
                    Task {
                        await rebuildCompositionAsync(seekTo: currentTime)
                    }
                }
            )
        } else {
            Text("Loading video...")
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    private var bottomClipActionMenu: some View {
        VStack {
            Spacer()
            if selectedClipID != nil {
                ClipActionMenuView(onDelete: {
                    if let selID = selectedClipID {
                        deleteClip(with: selID)
                    }
                })
                .transition(.move(edge: .bottom))
                .animation(.default, value: selectedClipID)
            }
        }
        .edgesIgnoringSafeArea(.bottom)
    }

    @ViewBuilder
    private var exportOverlay: some View {
        if isExporting {
            VStack(spacing: 10) {
                ProgressView(value: exportProgress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .padding(.horizontal, 20)
                Text("Exporting: \(Int(exportProgress * 100))%")
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(10)
        }
    }

    @ViewBuilder
    private var importOverlay: some View {
        if isExtraImporting {
            VStack(spacing: 10) {
                ProgressView(value: extraImportProgress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .padding(.horizontal, 20)
                Text("Importing extra footage: \(Int(extraImportProgress * 100))%")
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color.black.opacity(0.8))
            .cornerRadius(10)
        }
    }

    // MARK: - Helper Functions

    func totalVirtualTime() -> Double {
        clips.reduce(0) { $0 + ($1.endTime - $1.startTime) }
    }

    func togglePlayPause() {
        guard let player = player else { return }
        if !isPlaying && currentTime >= totalVirtualTime() {
            seekPlayer(to: 0)
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seekPlayer(to newVirtualTime: Double) {
        guard let player = player else { return }
        let clamped = min(max(0, newVirtualTime), totalVirtualTime())
        let cmTime = CMTimeMakeWithSeconds(clamped, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func setupInitialComposition() {
        configureAudioSession()
        clips = initialContent.clips
        keyframes = initialContent.keyframes
        selectedEffect = initialContent.selectedEffect
        effectIntensity = initialContent.effectIntensity
        Task {
            await rebuildCompositionAsync(seekTo: 0)
            isRestoring = false
        }
    }

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    func appendExtraClip(from url: URL, duration: Double, mediaType: ClipMediaType = .video) {
        let storedURL = projectStore.storeMedia(from: url, projectID: projectID)
        let newClip = Clip(sourceURL: storedURL, startTime: 0, endTime: duration, mediaType: mediaType)
        clips.append(newClip)
        Task {
            await rebuildCompositionAsync(seekTo: currentTime)
        }
    }

    func buildComposition() async -> AVMutableComposition? {
        let composition = AVMutableComposition()
        var compositionVideoTrack: AVMutableCompositionTrack? = nil
        var mainAudioTrack: AVMutableCompositionTrack? = nil
        var currentCompTime = CMTime.zero
        let hasVideoClips = clips.contains { $0.mediaType == .video }

        for clip in clips {
            let asset = AVURLAsset(url: clip.sourceURL)
            let start = CMTimeMakeWithSeconds(clip.startTime, preferredTimescale: 600)
            let duration = CMTimeMakeWithSeconds(clip.endTime - clip.startTime, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: start, duration: duration)
            do {
                if clip.mediaType == .video {
                    if compositionVideoTrack == nil {
                        compositionVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                                            preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    let videoTracks = try? await asset.loadTracks(withMediaType: .video)
                    if let assetVideoTrack = videoTracks?.first {
                        try compositionVideoTrack?.insertTimeRange(timeRange, of: assetVideoTrack, at: currentCompTime)
                    }
                    let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
                    if let assetAudioTrack = audioTracks?.first {
                        if mainAudioTrack == nil {
                            mainAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        try mainAudioTrack?.insertTimeRange(timeRange, of: assetAudioTrack, at: currentCompTime)
                    }
                    currentCompTime = currentCompTime + duration
                } else {
                    // Audio-only clip: mix under the timeline when video exists; otherwise, build sequential audio.
                    let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
                    if let assetAudioTrack = audioTracks?.first {
                        let extraAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        let startTime = hasVideoClips ? .zero : currentCompTime
                        try extraAudioTrack?.insertTimeRange(timeRange, of: assetAudioTrack, at: startTime)
                        if !hasVideoClips {
                            currentCompTime = currentCompTime + duration
                        }
                    }
                }
            } catch {
                print("Error inserting clip: \(error)")
            }
        }
        return composition
    }

    func rebuildComposition(seekTo virtualTime: Double) {
        Task {
            await rebuildCompositionAsync(seekTo: virtualTime)
        }
    }

    func rebuildCompositionAsync(seekTo virtualTime: Double) async {
        guard let composition = await buildComposition() else { return }
        let newItem = AVPlayerItem(asset: composition)
        if let videoComposition = makeVideoComposition(for: composition) {
            newItem.videoComposition = videoComposition
        }
        if player == nil {
            player = AVPlayer(playerItem: newItem)
            player?.isMuted = false
            player?.volume = 1.0
        } else {
            player?.replaceCurrentItem(with: newItem)
        }
        totalTime = totalVirtualTime()

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        let observer = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                       queue: .main) { time in
            let seconds = CMTimeGetSeconds(time)
            if !isScrubbing { currentTime = seconds }
            totalTime = totalVirtualTime()
            if seconds >= totalVirtualTime() - 0.1 {
                player?.pause()
                isPlaying = false
            }
        }
        timeObserver = observer

        let cmTime = CMTimeMakeWithSeconds(virtualTime, preferredTimescale: 600)
        await player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = virtualTime
    }

    func persistContent() {
        guard !isRestoring else { return }
        let content = ProjectContent(
            clips: clips,
            keyframes: keyframes,
            selectedEffect: selectedEffect,
            effectIntensity: effectIntensity
        )
        projectStore.saveContent(content, for: projectID)
    }

    func moveClip(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              clips.indices.contains(fromIndex),
              clips.indices.contains(toIndex) else { return }
        let movedClip = clips.remove(at: fromIndex)
        clips.insert(movedClip, at: toIndex)
        Task {
            await rebuildCompositionAsync(seekTo: currentTime)
        }
    }

    func addKeyframe() {
        guard totalTime > 0 else { return }
        let clampedTime = min(max(currentTime, 0), totalTime)
        let newFrame = Keyframe(time: clampedTime, value: effectIntensity)
        if let index = keyframes.firstIndex(where: { abs($0.time - clampedTime) < 0.05 }) {
            keyframes[index] = newFrame
        } else {
            keyframes.append(newFrame)
        }
        keyframes.sort { $0.time < $1.time }
        Task {
            await rebuildCompositionAsync(seekTo: currentTime)
        }
    }

    func effectIntensity(at time: Double) -> Double {
        guard !keyframes.isEmpty else { return effectIntensity }
        let sorted = keyframes.sorted { $0.time < $1.time }
        if time <= sorted[0].time { return sorted[0].value }
        if time >= sorted[sorted.count - 1].time { return sorted[sorted.count - 1].value }
        for index in 0..<(sorted.count - 1) {
            let left = sorted[index]
            let right = sorted[index + 1]
            if time >= left.time && time <= right.time {
                let ratio = (time - left.time) / max((right.time - left.time), 0.001)
                return left.value + ratio * (right.value - left.value)
            }
        }
        return effectIntensity
    }

    func makeVideoComposition(for composition: AVComposition) -> AVVideoComposition? {
        guard !composition.tracks(withMediaType: .video).isEmpty else { return nil }
        guard selectedEffect != .none else { return nil }

        let videoComposition = AVVideoComposition(asset: composition, applyingCIFiltersWithHandler: { request in
            let sourceImage = request.sourceImage.clampedToExtent()
            let time = CMTimeGetSeconds(request.compositionTime)
            let intensityValue = effectIntensity(at: time)
            let outputImage: CIImage
            switch selectedEffect {
            case .sepia:
                let filter = CIFilter.sepiaTone()
                filter.inputImage = sourceImage
                filter.intensity = Float(intensityValue)
                outputImage = filter.outputImage ?? sourceImage
            case .noir:
                let filter = CIFilter.photoEffectNoir()
                filter.inputImage = sourceImage
                outputImage = filter.outputImage ?? sourceImage
            case .chrome:
                let filter = CIFilter.photoEffectChrome()
                filter.inputImage = sourceImage
                outputImage = filter.outputImage ?? sourceImage
            case .none:
                outputImage = sourceImage
            }
            let cropped = outputImage.cropped(to: request.sourceImage.extent)
            request.finish(with: cropped, context: nil)
        })
        return videoComposition
    }

    func performCut(at virtualTime: Double) {
        var cumulative: Double = 0
        for (index, clip) in clips.enumerated() {
            let clipDuration = clip.endTime - clip.startTime
            if cumulative <= virtualTime && virtualTime < cumulative + clipDuration {
                let offset = virtualTime - cumulative
                let cutTime = clip.startTime + offset
                clips.remove(at: index)
                let firstClip = Clip(sourceURL: clip.sourceURL, startTime: clip.startTime, endTime: cutTime)
                let secondClip = Clip(sourceURL: clip.sourceURL, startTime: cutTime, endTime: clip.endTime)
                if firstClip.endTime - firstClip.startTime > 0 {
                    clips.insert(firstClip, at: index)
                    clips.insert(secondClip, at: index + 1)
                } else {
                    clips.insert(secondClip, at: index)
                }
                break
            }
            cumulative += clipDuration
        }
        Task {
            await rebuildCompositionAsync(seekTo: virtualTime)
        }
    }

    func deleteClip(with id: UUID) {
        if let index = clips.firstIndex(where: { $0.id == id }) {
            clips.remove(at: index)
            if clips.isEmpty {
                player?.pause()
                player = nil
            } else {
                let newVirtualTime = min(currentTime, totalVirtualTime())
                Task {
                    await rebuildCompositionAsync(seekTo: newVirtualTime)
                }
            }
            selectedClipID = nil
        }
    }
    
    // MARK: - Export Functionality

    func exportVideo() {
        Task {
            await exportVideoAsync()
        }
    }
    
    func exportVideoAsync() async {
        guard let composition = await buildComposition() else { return }
        isExporting = true
        exportProgress = 0.0

        let hasVideo = !composition.tracks(withMediaType: .video).isEmpty && composition.tracks(withMediaType: .video).first?.segments.isEmpty == false
        let presetName = hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A

        guard let newSession = AVAssetExportSession(asset: composition, presetName: presetName) else {
            isExporting = false
            exportError = "Could not create export session."
            return
        }
        exportSession = newSession
        guard let exportSession = exportSession else { return }

        let filename = hasVideo ? "\(UUID().uuidString)_export.mov" : "\(UUID().uuidString)_export.m4a"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = hasVideo ? .mov : .m4a
        exportSession.shouldOptimizeForNetworkUse = true
        if hasVideo, let videoComposition = makeVideoComposition(for: composition) {
            exportSession.videoComposition = videoComposition
        }

        Task {
            do {
                // Start export asynchronously
                await exportSession.export()

                // Poll progress until finished/failed/cancelled
                while true {
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 sec
                    let status = exportSession.status
                    let progress = exportSession.progress
                    await MainActor.run {
                        self.exportProgress = Double(progress)
                    }
                    switch status {
                    case .completed:
                        await MainActor.run {
                            self.isExporting = false
                            self.exportURL = outputURL
                            self.isShareSheetPresented = true
                        }
                        await MainActor.run { self.exportSession = nil }
                        return
                    case .failed:
                        let errorDescription = exportSession.error?.localizedDescription ?? "Unknown export error."
                        await MainActor.run {
                            self.isExporting = false
                            self.exportError = errorDescription
                        }
                        await MainActor.run { self.exportSession = nil }
                        return
                    case .cancelled:
                        await MainActor.run {
                            self.isExporting = false
                        }
                        await MainActor.run { self.exportSession = nil }
                        return
                    default:
                        break
                    }
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.exportError = error.localizedDescription
                }
                await MainActor.run { self.exportSession = nil }
            }
        }
    }
    
    // MARK: - Extracted Subviews to help type-checker
    private struct ControlButtonsView: View {
        let isPlaying: Bool
        let onCut: () -> Void
        let onTogglePlay: () -> Void
        var body: some View {
            HStack {
                Button(action: onCut) {
                    Image(systemName: "scissors")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                Spacer()
                Button(action: onTogglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
                Spacer()
            }
            .padding(.horizontal, 40)
        }
    }

    private struct EffectsPanelView: View {
        @Binding var selectedEffect: VideoEffect
        @Binding var effectIntensity: Double
        @Binding var keyframes: [Keyframe]
        let totalTime: Double
        let canAddKeyframe: Bool
        let onAddKeyframe: () -> Void
        let onClearKeyframes: () -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Effects & Keyframes")
                    .font(.headline)
                    .foregroundColor(.white)

                Picker("Effect", selection: $selectedEffect) {
                    ForEach(VideoEffect.allCases) { effect in
                        Text(effect.rawValue).tag(effect)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Intensity")
                        .foregroundColor(.white)
                    Slider(value: $effectIntensity, in: 0...1)
                        .disabled(selectedEffect == .none || selectedEffect == .noir || selectedEffect == .chrome)
                }

                HStack {
                    Button("Add Keyframe") { onAddKeyframe() }
                        .disabled(!canAddKeyframe)
                        .buttonStyle(.borderedProminent)

                    Spacer()

                    Button("Clear Keyframes") { onClearKeyframes() }
                        .buttonStyle(.bordered)
                }

                KeyframeGraphView(keyframes: keyframes, totalTime: totalTime)
                    .frame(height: 80)
            }
            .padding(.horizontal, 20)
        }
    }
}

