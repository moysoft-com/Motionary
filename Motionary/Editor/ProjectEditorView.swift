import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import Photos
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins

enum VideoEffect: String, CaseIterable, Identifiable {
    case none = "None"
    case sepia = "Sepia"
    case noir = "Noir"
    case chrome = "Chrome"

    var id: String { rawValue }
}

struct ProjectEditorView: View {
    // The initial footage becomes the first clip.
    var initialVideoURL: URL
    var initialDuration: Double

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

    // MARK: - Effects / Keyframes
    @State private var selectedEffect: VideoEffect = .none
    @State private var effectIntensity: Double = 0.6
    @State private var keyframes: [Keyframe] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                if let player = player {
                    // Video preview with export button overlay at top-right.
                    ZStack(alignment: .topTrailing) {
                        VideoPlayer(player: player)
                            .frame(height: 300)
                            .cornerRadius(12)
                            .padding()
                        Button(action: {
                            exportVideo()
                        }) {
                            Text("Export")
                                .padding(8)
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                        .padding()
                    }
                    
                    // Control buttons: Cut and Play/Pause.
                    HStack {
                        Button {
                            performCut(at: currentTime)
                        } label: {
                            Image(systemName: "scissors")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Button {
                            togglePlayPause()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 40)
                    
                    // Timeline view wrapped in a horizontal scroll view.
                    ScrollView(.horizontal, showsIndicators: true) {
                        EditedTimelineView(
                            clips: clips,
                            currentTime: currentTime,
                            totalTime: totalTime,
                            selectedClipID: selectedClipID,
                            onSelectClip: { clip in
                                selectedClipID = clip?.id
                            },
                            onScrubStart: {
                                wasPlayingBeforeScrub = isPlaying
                                player.pause()
                                isPlaying = false
                                isScrubbing = true
                            },
                            onScrubChanged: { newTime in
                                seekPlayer(to: newTime)
                            },
                            onScrubEnd: { newTime in
                                seekPlayer(to: newTime)
                                isScrubbing = false
                                if wasPlayingBeforeScrub {
                                    if newTime >= totalTime {
                                        seekPlayer(to: 0)
                                    }
                                    player.play()
                                    isPlaying = true
                                }
                            },
                            onMoveClip: { fromIndex, toIndex in
                                moveClip(from: fromIndex, to: toIndex)
                            }
                        )
                    }
                    .frame(height: 120)

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
                            Button("Add Keyframe") {
                                addKeyframe()
                            }
                            .disabled(selectedEffect == .none || totalTime == 0)
                            .buttonStyle(.borderedProminent)

                            Spacer()

                            Button("Clear Keyframes") {
                                keyframes.removeAll()
                                rebuildComposition(seekTo: currentTime)
                            }
                            .buttonStyle(.bordered)
                        }

                        KeyframeGraphView(keyframes: keyframes, totalTime: totalTime)
                            .frame(height: 80)
                    }
                    .padding(.horizontal, 20)
                } else {
                    Text("Loading video...")
                        .foregroundColor(.white)
                }
                Spacer()
            }
            .padding(.bottom, 60)
            .contentShape(Rectangle())
            .onTapGesture { selectedClipID = nil }
            
            // ClipActionMenuView anchored at the bottom.
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
            
            // Export progress overlay.
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
            
            // Extra footage importing overlay.
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
        .toolbar {
            // Extra footage import plus button on the right.
            ToolbarItemGroup(placement: .navigationBarTrailing) {
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
        .onAppear { setupInitialComposition() }
        .onChange(of: extraFootageItem) { newItem in
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
                            let asset = AVAsset(url: tempURL)
                            let duration = CMTimeGetSeconds(asset.duration)
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
        .onChange(of: selectedEffect) { _ in
            rebuildComposition(seekTo: currentTime)
        }
        .onChange(of: effectIntensity) { _ in
            rebuildComposition(seekTo: currentTime)
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
                let asset = AVAsset(url: tempURL)
                let duration = CMTimeGetSeconds(asset.duration)
                appendExtraClip(from: tempURL, duration: duration, mediaType: .audio)
            } catch {
                audioImportError = error.localizedDescription
            }
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
        clips = [Clip(sourceURL: initialVideoURL, startTime: 0, endTime: initialDuration, mediaType: .video)]
        rebuildComposition(seekTo: 0)
    }

    func appendExtraClip(from url: URL, duration: Double, mediaType: ClipMediaType = .video) {
        let newClip = Clip(sourceURL: url, startTime: 0, endTime: duration, mediaType: mediaType)
        clips.append(newClip)
        rebuildComposition(seekTo: currentTime)
    }

    func buildComposition() -> AVMutableComposition? {
        let composition = AVMutableComposition()
        let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid)
        let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid)
        var currentCompTime = CMTime.zero
        for clip in clips {
            let asset = AVAsset(url: clip.sourceURL)
            let start = CMTimeMakeWithSeconds(clip.startTime, preferredTimescale: 600)
            let duration = CMTimeMakeWithSeconds(clip.endTime - clip.startTime, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: start, duration: duration)
            do {
                if clip.mediaType == .video, let assetVideoTrack = asset.tracks(withMediaType: .video).first {
                    try compositionVideoTrack?.insertTimeRange(timeRange, of: assetVideoTrack, at: currentCompTime)
                }
                if let assetAudioTrack = asset.tracks(withMediaType: .audio).first {
                    try compositionAudioTrack?.insertTimeRange(timeRange, of: assetAudioTrack, at: currentCompTime)
                }
                currentCompTime = currentCompTime + duration
            } catch {
                print("Error inserting clip: \(error)")
            }
        }
        return composition
    }

    func rebuildComposition(seekTo virtualTime: Double) {
        guard let composition = buildComposition() else { return }
        let newItem = AVPlayerItem(asset: composition)
        if let videoComposition = makeVideoComposition(for: composition) {
            newItem.videoComposition = videoComposition
        }
        if player == nil {
            player = AVPlayer(playerItem: newItem)
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
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = virtualTime
    }

    func moveClip(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              clips.indices.contains(fromIndex),
              clips.indices.contains(toIndex) else { return }
        let movedClip = clips.remove(at: fromIndex)
        clips.insert(movedClip, at: toIndex)
        rebuildComposition(seekTo: currentTime)
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
        rebuildComposition(seekTo: currentTime)
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
        return AVVideoComposition(asset: composition) { request in
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
        }
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
        rebuildComposition(seekTo: virtualTime)
    }

    func deleteClip(with id: UUID) {
        if let index = clips.firstIndex(where: { $0.id == id }) {
            clips.remove(at: index)
            if clips.isEmpty {
                player?.pause()
                player = nil
            } else {
                let newVirtualTime = min(currentTime, totalVirtualTime())
                rebuildComposition(seekTo: newVirtualTime)
            }
            selectedClipID = nil
        }
    }
    
    // MARK: - Export Functionality

    func exportVideo() {
        guard let composition = buildComposition() else { return }
        isExporting = true
        exportProgress = 0.0
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            isExporting = false
            exportError = "Could not create export session."
            return
        }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_export.mov")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true
        if let videoComposition = makeVideoComposition(for: composition) {
            exportSession.videoComposition = videoComposition
        }
        
        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                if exportSession.status == .completed {
                    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                        DispatchQueue.main.async {
                            if status == .authorized || status == .limited {
                                PHPhotoLibrary.shared().performChanges({
                                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                                }) { success, error in
                                    DispatchQueue.main.async {
                                        self.isExporting = false
                                        if !success {
                                            self.exportError = error?.localizedDescription ?? "Export failed to save."
                                        }
                                    }
                                }
                            } else {
                                self.isExporting = false
                                self.exportError = "Photo Library access denied."
                            }
                        }
                    }
                } else {
                    self.isExporting = false
                    self.exportError = exportSession.error?.localizedDescription ?? "Export failed."
                }
            }
        }
        
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            DispatchQueue.main.async {
                self.exportProgress = Double(exportSession.progress)
                if exportSession.status == .completed || exportSession.status == .failed || exportSession.status == .cancelled {
                    timer.invalidate()
                }
            }
        }
    }
}

