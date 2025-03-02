import SwiftUI
import AVKit
import AVFoundation
import PhotosUI

// Updated Clip model.
struct Clip: Identifiable, Equatable {
    let id = UUID()
    var sourceURL: URL
    var startTime: Double   // seconds in source
    var endTime: Double     // seconds in source
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

    // MARK: - Export State
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var exportError: String? = nil

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
                            }
                        )
                    }
                    .frame(height: 120)
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
            ToolbarItem(placement: .navigationBarTrailing) {
                PhotosPicker(selection: $extraFootageItem, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "plus")
                        .foregroundColor(.white)
                }
            }
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
        clips = [Clip(sourceURL: initialVideoURL, startTime: 0, endTime: initialDuration)]
        rebuildComposition(seekTo: 0)
    }

    func appendExtraClip(from url: URL, duration: Double) {
        let newClip = Clip(sourceURL: url, startTime: 0, endTime: duration)
        clips.append(newClip)
        rebuildComposition(seekTo: currentTime)
    }

    func buildComposition() -> AVMutableComposition? {
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var currentCompTime = CMTime.zero
        for clip in clips {
            let asset = AVAsset(url: clip.sourceURL)
            guard let assetVideoTrack = asset.tracks(withMediaType: .video).first else { continue }
            let start = CMTimeMakeWithSeconds(clip.startTime, preferredTimescale: 600)
            let duration = CMTimeMakeWithSeconds(clip.endTime - clip.startTime, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: start, duration: duration)
            do {
                try compositionVideoTrack.insertTimeRange(timeRange, of: assetVideoTrack, at: currentCompTime)
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
        
        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                self.isExporting = false
                if exportSession.status == .completed {
                    UISaveVideoAtPathToSavedPhotosAlbum(outputURL.path, nil, nil, nil)
                } else {
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
