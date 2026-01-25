import SwiftUI
import PhotosUI
import AVFoundation

struct ImportFootageView: View {
    /// Called when media is successfully imported.
    /// Passes the video URL and its duration (in seconds).
    var onImport: (URL, Double) -> Void

    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var isImporting = false
    @State private var importProgress = 0.0  // Value between 0.0 and 1.0
    @State private var importError: String? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Import screen UI
            VStack(spacing: 20) {
                Text("No footage imported.")
                    .foregroundColor(.white)
                PhotosPicker(selection: $selectedItem, matching: .any(of: [.images, .videos])) {
                    Text("Import Footage")
                        .padding()
                        .background(Color.white)
                        .foregroundColor(.black)
                        .cornerRadius(8)
                }
            }
            
            // Loading overlay
            if isImporting {
                VStack(spacing: 10) {
                    ProgressView(value: importProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .padding(.horizontal, 20)
                    Text("Importing footage... \(Int(importProgress * 100))%")
                        .foregroundColor(.white)
                }
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(10)
            }
        }
        .alert(isPresented: Binding<Bool>(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Alert(title: Text("Import Error"),
                  message: Text(importError ?? "Unknown error."),
                  dismissButton: .default(Text("OK")))
        }
        .onChange(of: selectedItem) { oldValue, newItem in
            Task {
                guard let newItem = newItem else { return }
                isImporting = true
                importProgress = 0.0
                importError = nil
                
                // Simulate progress updates.
                let progressTask = Task {
                    while !Task.isCancelled && importProgress < 1.0 {
                        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 sec
                        await MainActor.run {
                            importProgress += 0.05
                            if importProgress > 1.0 { importProgress = 1.0 }
                        }
                    }
                }
                
                // Try loading as an image first.
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    // Convert the image to a 5-second video.
                    if let videoURL = await convertImageToVideo(image: image, duration: 5.0) {
                        progressTask.cancel()
                        await MainActor.run { importProgress = 1.0 }
                        onImport(videoURL, 5.0)
                    } else {
                        progressTask.cancel()
                        await MainActor.run { importError = "Failed to convert image to video." }
                    }
                } else {
                    // Otherwise, try loading as video data.
                    do {
                        if let data = try await newItem.loadTransferable(type: Data.self) {
                            progressTask.cancel()
                            await MainActor.run { importProgress = 1.0 }
                            let tempURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent("\(UUID().uuidString).mov")
                            try data.write(to: tempURL)
                            
                            let asset = AVURLAsset(url: tempURL)
                            let loadedDuration: CMTime = try await asset.load(.duration)
                            let duration = CMTimeGetSeconds(loadedDuration)
                            onImport(tempURL, duration)
                        } else {
                            progressTask.cancel()
                            await MainActor.run { importError = "Failed to load media data." }
                        }
                    } catch {
                        progressTask.cancel()
                        await MainActor.run { importError = error.localizedDescription }
                    }
                }
                isImporting = false
            }
        }
    }
}

/// Converts a UIImage into a video file of the specified duration.
/// This is a simplified implementation. In production, you’d want to refine error handling.
func convertImageToVideo(image: UIImage, duration: Double) async -> URL? {
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
    guard let videoSize = image.cgImage.map({ CGSize(width: $0.width, height: $0.height) }) else {
        return nil
    }
    do {
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let sourceBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: videoSize.width,
            kCVPixelBufferHeightKey as String: videoSize.height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: sourceBufferAttributes)
        guard writer.canAdd(writerInput) else { return nil }
        writer.add(writerInput)
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        let fps: Int32 = 30
        let frameDuration = CMTime(value: 1, timescale: fps)
        let totalFrames = Int(duration * Double(fps))
        
        var frameCount = 0
        while frameCount < totalFrames {
            autoreleasepool {
                if let pixelBufferPool = adaptor.pixelBufferPool {
                    var pixelBufferOut: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBufferOut)
                    if status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut {
                        CVPixelBufferLockBaseAddress(pixelBuffer, [])
                        let context = CGContext(
                            data: CVPixelBufferGetBaseAddress(pixelBuffer),
                            width: Int(videoSize.width),
                            height: Int(videoSize.height),
                            bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                        )
                        context?.clear(CGRect(origin: .zero, size: videoSize))
                        context?.draw(image.cgImage!, in: CGRect(origin: .zero, size: videoSize))
                        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
                        while !writerInput.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                    }
                }
            }
            frameCount += 1
        }
        
        writerInput.markAsFinished()
        writer.finishWriting {
            // Completed writing.
        }
        
        return tempURL
    } catch {
        return nil
    }
}
