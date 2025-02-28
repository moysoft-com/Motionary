//
//  EditorView.swift
//  Motionary
//
//  Created by Lian on 28.02.25.
//


import SwiftUI
import AVFoundation

struct EditorView: View {
    let project: Project
    let onExit: () -> Void

    @State private var player: AVPlayer?
    @State private var totalDuration: Double = 0
    @State private var baseDuration: Double = 0
    @State private var asset: AVURLAsset?
    
    @State private var clips: [Clip] = []
    @State private var currentTime: Double = 0
    
    @State private var isPlaying: Bool = true
    @State private var selectedClip: Clip? = nil
    
    @State private var undoStack: [[Clip]] = []
    @State private var redoStack: [[Clip]] = []
    
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showKeepAtLeastOneAlert = false
    
    var body: some View {
        VStack {
            if let player = player {
                CustomVideoPlayer(player: player)
                    .frame(height: 240)
                    .background(Color.black)
                    .border(Color.green, width: 3)
            } else {
                Text("Video not loaded")
                    .foregroundColor(.red)
                    .border(Color.green, width: 3)
            }
            
            ControlBarView(isPlaying: isPlaying,
                           onPlayPause: {
                               if isPlaying { player?.pause() } else { player?.play() }
                               isPlaying.toggle()
                           },
                           onUndo: undoLastChange,
                           onRedo: redoLastChange,
                           onDelete: deleteSelectedClip,
                           canUndo: !undoStack.isEmpty,
                           canRedo: !redoStack.isEmpty,
                           hasSelection: selectedClip != nil)
            
            TimelineView(clips: $clips,
                         currentTime: $currentTime,
                         baseDuration: baseDuration,
                         asset: asset,
                         onClipTap: { clip in selectedClip = clip },
                         onTimelineDrag: { newTime in
                            currentTime = newTime
                            player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
                         },
                         selectedClip: selectedClip)
                .frame(height: 100)
                .border(Color.green, width: 3)
                .clipped()
            
            Button("Cut at Current Time") {
                addUndoState()
                cutClip(at: currentTime)
            }
            .buttonStyle(.borderedProminent)
            
            if showKeepAtLeastOneAlert {
                Text("You must keep at least 1 clip")
                    .foregroundColor(.red)
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Exit") { onExit() }
                    .foregroundColor(.blue)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Export") { exportVideo() }
            }
        }
        .task { await loadProjectMedia() }
        .alert("Error", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }
    
    // MARK: - Loading Media Assets
    
    func loadProjectMedia() async {
        // Falls keine Medien importiert wurden, Fallback auf sample.mp4
        guard !project.mediaPaths.isEmpty else {
            if let url = Bundle.main.url(forResource: "sample", withExtension: "mp4") {
                asset = AVURLAsset(url: url)
                totalDuration = asset?.duration.seconds ?? 0
                baseDuration = totalDuration
                clips = [Clip(start: 0, end: totalDuration)]
                let item = AVPlayerItem(asset: asset!)
                player = AVPlayer(playerItem: item)
                player?.play()
                isPlaying = true
            }
            return
        }
        
        let composition = AVMutableComposition()
        var currentCompTime = CMTime.zero
        
        for path in project.mediaPaths {
            guard let url = URL(string: path) else { continue }
            let mediaAsset: AVAsset
            if isImage(url: url) {
                if let imageAsset = await createVideoAssetFromImage(url: url, duration: 5) {
                    mediaAsset = imageAsset
                } else {
                    continue
                }
            } else {
                mediaAsset = AVURLAsset(url: url)
            }
            
            do {
                let videoTracks = try await mediaAsset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first,
                      let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                
                let duration = mediaAsset.duration
                try compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                                   of: videoTrack,
                                                   at: currentCompTime)
                if let audioTrack = (try? await mediaAsset.loadTracks(withMediaType: .audio))?.first,
                   let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try compAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                                       of: audioTrack,
                                                       at: currentCompTime)
                }
                currentCompTime = CMTimeAdd(currentCompTime, duration)
            } catch {
                print("Error inserting asset: \(error.localizedDescription)")
            }
        }
        
        totalDuration = currentCompTime.seconds
        baseDuration = totalDuration
        clips = [Clip(start: 0, end: totalDuration)]
        
        let newItem = AVPlayerItem(asset: composition)
        player = AVPlayer(playerItem: newItem)
        player?.play()
        isPlaying = true
    }
    
    // MARK: - Helper Functions
    
    func isImage(url: URL) -> Bool {
        let imageExtensions = ["jpg", "jpeg", "png"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
    
    /// Erstellt ein Video-Asset aus einem Bild (Standarddauer: 5 Sek).
    func createVideoAssetFromImage(url: URL, duration: Double = 5) async -> AVAsset? {
        guard let image = UIImage(contentsOfFile: url.path) else {
            print("Bild konnte nicht geladen werden")
            return nil
        }
        let size = image.size
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height
            ]
            let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            writerInput.expectsMediaDataInRealTime = false
            writer.add(writerInput)
            
            let sourceBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput,
                                                               sourcePixelBufferAttributes: sourceBufferAttributes)
            
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            
            let fps: Int32 = 30
            let frameCount = Int(duration * Double(fps))
            let frameDuration = CMTime(value: 1, timescale: fps)
            var frameTime = CMTime.zero
            
            for _ in 0..<frameCount {
                autoreleasepool {
                    if let pixelBufferPool = adaptor.pixelBufferPool {
                        var pixelBuffer: CVPixelBuffer?
                        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
                        if status == kCVReturnSuccess, let pixelBuffer = pixelBuffer {
                            CVPixelBufferLockBaseAddress(pixelBuffer, [])
                            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                                    width: Int(size.width),
                                                    height: Int(size.height),
                                                    bitsPerComponent: 8,
                                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                    space: CGColorSpaceCreateDeviceRGB(),
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
                            if let cgImage = image.cgImage {
                                context?.draw(cgImage, in: CGRect(origin: .zero, size: size))
                            }
                            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                            
                            while !writerInput.isReadyForMoreMediaData { }
                            adaptor.append(pixelBuffer, withPresentationTime: frameTime)
                            frameTime = CMTimeAdd(frameTime, frameDuration)
                        }
                    }
                }
            }
            writerInput.markAsFinished()
            writer.finishWriting {
                print("Image-Video fertig geschrieben")
            }
            while writer.status == .writing {
                await Task.yield()
            }
            if writer.status == .completed {
                return AVURLAsset(url: outputURL)
            }
        } catch {
            print("Fehler beim Erstellen des Image-Video Assets: \(error.localizedDescription)")
        }
        return nil
    }
    
    // MARK: - Undo, Cut, Delete, Update und Export Funktionen
    
    func addUndoState() {
        undoStack.append(clips)
        redoStack.removeAll()
    }
    
    func undoLastChange() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(clips)
        clips = last
        selectedClip = nil
        Task { await updatePlayerComposition() }
    }
    
    func redoLastChange() {
        guard let last = redoStack.popLast() else { return }
        undoStack.append(clips)
        clips = last
        selectedClip = nil
        Task { await updatePlayerComposition() }
    }
    
    func cutClip(at time: Double) {
        guard let index = clips.firstIndex(where: { time > $0.start && time < $0.end }) else { return }
        let clip = clips[index]
        guard time > clip.start + 0.05 && time < clip.end - 0.05 else { return }
        let firstClip = Clip(start: clip.start, end: time)
        let secondClip = Clip(start: time, end: clip.end)
        clips.remove(at: index)
        let gap = 0.5
        let adjustedFirst = Clip(start: firstClip.start, end: firstClip.end - gap / 2)
        let adjustedSecond = Clip(start: secondClip.start + gap / 2, end: secondClip.end)
        clips.insert(contentsOf: [adjustedFirst, adjustedSecond], at: index)
        selectedClip = nil
        Task { await updatePlayerComposition() }
    }
    
    func deleteSelectedClip() {
        guard let sel = selectedClip, let index = clips.firstIndex(of: sel) else { return }
        if clips.count == 1 {
            withAnimation { showKeepAtLeastOneAlert = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { showKeepAtLeastOneAlert = false }
            }
            return
        }
        addUndoState()
        clips.remove(at: index)
        if currentTime < sel.start, let prev = clips.last(where: { $0.end <= sel.start }) {
            currentTime = prev.end
        }
        selectedClip = nil
        Task { await updatePlayerComposition() }
    }
    
    func updatePlayerComposition() async {
        guard let _ = asset else { return }
        let composition = AVMutableComposition()
        do {
            var currentCompTime = CMTime.zero
            for clip in clips {
                let clipDuration = CMTime(seconds: clip.end - clip.start, preferredTimescale: 600)
                currentCompTime = CMTimeAdd(currentCompTime, clipDuration)
            }
            let newItem = AVPlayerItem(asset: composition)
            player?.replaceCurrentItem(with: newItem)
            isPlaying = false
        } catch {
            print("Error updating composition: \(error.localizedDescription)")
        }
    }
    
    func exportVideo() {
        alertMessage = "Export functionality not implemented yet."
        showAlert = true
    }
}