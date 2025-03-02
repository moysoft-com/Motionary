import SwiftUI
import AVKit
import AVFoundation
import PhotosUI

struct ProjectEditorView: View {
    var initialVideoURL: URL
    var initialDuration: Double
    
    // MARK: - Player & Timeline
    @State private var player: AVPlayer? = nil
    @State private var currentTime: Double = 0
    @State private var totalTime: Double = 0
    @State private var timeObserver: Any?
    @State private var isPlaying: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var wasPlayingBeforeScrub: Bool = false
    
    // MARK: - Clips
    @State private var clips: [Clip] = []
    @State private var selectedClipID: UUID? = nil
    
    // MARK: - Undo/Redo
    @State private var undoStack: [[Clip]] = []
    @State private var redoStack: [[Clip]] = []
    
    // MARK: - Extra Footage Import
    @State private var extraFootageItem: PhotosPickerItem? = nil
    @State private var isExtraImporting: Bool = false
    @State private var extraImportProgress: Double = 0.0
    
    // MARK: - Export
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var exportError: String? = nil
    
    // MARK: - Project Format
    @State private var projectFormat: ProjectFormat = .sixteenNine
    
    // MARK: - Alerts
    @State private var showCannotDeleteLastClip = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 1) Oberer Bereich
                    EditorTopView(
                        geo: geo,
                        projectFormat: projectFormat,
                        player: player
                    )
                    
                    // 2) Unterer Bereich
                    EditorBottomView(
                        geo: geo,
                        player: $player,
                        currentTime: $currentTime,
                        totalTime: $totalTime,
                        timeObserver: $timeObserver,
                        isPlaying: $isPlaying,
                        isScrubbing: $isScrubbing,
                        wasPlayingBeforeScrub: $wasPlayingBeforeScrub,
                        clips: $clips,
                        selectedClipID: $selectedClipID,
                        undoStack: $undoStack,
                        redoStack: $redoStack,
                        showCannotDeleteLastClip: $showCannotDeleteLastClip,
                        projectFormat: $projectFormat,
                        extraFootageItem: $extraFootageItem,
                        isExtraImporting: $isExtraImporting,
                        extraImportProgress: $extraImportProgress,
                        isExporting: $isExporting,
                        exportProgress: $exportProgress,
                        exportError: $exportError,
                        onSeek: { newTime in
                            seekPlayer(to: newTime)
                        },
                        onCut: { performCut(at: currentTime) },
                        onDeleteClip: { deleteClip(with: $0) },
                        onUndo: { undoAction() },
                        onRedo: { redoAction() },
                        onTogglePlay: { togglePlayPause() },
                        onRebuild: { newTime in
                            rebuildComposition(seekTo: newTime)
                        },
                        onAppendClip: { url, duration in
                            appendExtraClip(from: url, duration: duration)
                        },
                        onExport: { exportVideo() }
                    )
                }
                
                // Overlay: Extraimport-Fortschritt
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
                
                // Overlay: Export-Fortschritt
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
                
                // Alert: Letzter Clip
                .alert("You must keep at least one clip", isPresented: $showCannotDeleteLastClip) {
                    Button("OK", role: .cancel) { }
                }
                
                // Overlay: ClipActionMenu
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
            .onAppear {
                setupInitialComposition()
            }
            // Reagiere auf Extra-Footage-Import
            .onChange(of: extraFootageItem) { newItem in
                Task {
                    guard let newItem = newItem else { return }
                    isExtraImporting = true
                    extraImportProgress = 0.0
                    let progressTask = Task {
                        while !Task.isCancelled && extraImportProgress < 1.0 {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await MainActor.run {
                                extraImportProgress += 0.05
                                if extraImportProgress > 1.0 { extraImportProgress = 1.0 }
                            }
                        }
                    }
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
                                let tempURL = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("\(UUID().uuidString).mov")
                                try data.write(to: tempURL)
                                let asset = AVURLAsset(url: tempURL)
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
    
    func seekPlayer(to newTime: Double) {
        guard let player = player else { return }
        let clamped = min(max(0, newTime), totalVirtualTime())
        let cmTime = CMTimeMakeWithSeconds(clamped, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }
    
    func setupInitialComposition() {
        clips = [Clip(sourceURL: initialVideoURL, startTime: 0, endTime: initialDuration)]
        rebuildComposition(seekTo: 0)
    }
    
    func appendExtraClip(from url: URL, duration: Double) {
        undoStack.append(clips)
        redoStack.removeAll()
        let newClip = Clip(sourceURL: url, startTime: 0, endTime: duration)
        clips.append(newClip)
        rebuildComposition(seekTo: currentTime)
    }
    
    func buildComposition() -> AVMutableComposition? {
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        var currentCompTime = CMTime.zero
        for clip in clips {
            let asset = AVURLAsset(url: clip.sourceURL)
            guard let assetTrack = asset.tracks(withMediaType: .video).first else { continue }
            let start = CMTimeMakeWithSeconds(clip.startTime, preferredTimescale: 600)
            let duration = CMTimeMakeWithSeconds(clip.endTime - clip.startTime, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: start, duration: duration)
            do {
                try compTrack.insertTimeRange(timeRange, of: assetTrack, at: currentCompTime)
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
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = CMTimeGetSeconds(time)
            if !isScrubbing {
                currentTime = seconds
            }
            totalTime = totalVirtualTime()
            if seconds >= totalVirtualTime() - 0.1 {
                player?.pause()
                isPlaying = false
            }
        }
        
        let cmTime = CMTimeMakeWithSeconds(virtualTime, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = virtualTime
    }
    
    func performCut(at virtualTime: Double) {
        undoStack.append(clips)
        redoStack.removeAll()
        
        let cutTime = min(max(0, virtualTime), totalVirtualTime())
        var cumulative: Double = 0
        for (index, clip) in clips.enumerated() {
            let clipDur = clip.endTime - clip.startTime
            if cumulative <= cutTime && cutTime < cumulative + clipDur {
                let offset = cutTime - cumulative
                let actualCutTime = clip.startTime + offset
                clips.remove(at: index)
                let firstClip = Clip(sourceURL: clip.sourceURL, startTime: clip.startTime, endTime: actualCutTime)
                let secondClip = Clip(sourceURL: clip.sourceURL, startTime: actualCutTime, endTime: clip.endTime)
                if firstClip.endTime - firstClip.startTime > 0 {
                    clips.insert(firstClip, at: index)
                    clips.insert(secondClip, at: index + 1)
                } else {
                    clips.insert(secondClip, at: index)
                }
                break
            }
            cumulative += clipDur
        }
        rebuildComposition(seekTo: cutTime)
    }
    
    func deleteClip(with id: UUID) {
        guard clips.count > 1 else {
            showCannotDeleteLastClip = true
            return
        }
        if let index = clips.firstIndex(where: { $0.id == id }) {
            undoStack.append(clips)
            redoStack.removeAll()
            clips.remove(at: index)
            let newVirtualTime = min(currentTime, totalVirtualTime())
            rebuildComposition(seekTo: newVirtualTime)
            selectedClipID = nil
        }
    }
    
    // MARK: Undo/Redo
    
    func undoAction() {
        guard !undoStack.isEmpty else { return }
        redoStack.append(clips)
        let previous = undoStack.removeLast()
        clips = previous
        rebuildComposition(seekTo: currentTime)
    }
    
    func redoAction() {
        guard !redoStack.isEmpty else { return }
        undoStack.append(clips)
        let next = redoStack.removeLast()
        clips = next
        rebuildComposition(seekTo: currentTime)
    }
    
    // MARK: Export (iOS 18)
    func exportVideo() {
        guard let composition = buildComposition() else { return }
        isExporting = true
        exportProgress = 0.0
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            isExporting = false
            exportError = "Could not create export session."
            return
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)_export.mov")
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true
        
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            DispatchQueue.main.async {
                self.exportProgress = Double(exportSession.progress)
            }
        }
        
        Task {
            do {
                try await exportSession.export(to: outputURL, as: .mov)
                DispatchQueue.main.async {
                    UISaveVideoAtPathToSavedPhotosAlbum(outputURL.path, nil, nil, nil)
                    self.isExporting = false
                    progressTimer.invalidate()
                }
            } catch {
                DispatchQueue.main.async {
                    self.exportError = error.localizedDescription
                    self.isExporting = false
                    progressTimer.invalidate()
                }
            }
        }
    }
}
