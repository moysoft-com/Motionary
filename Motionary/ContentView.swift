import SwiftUI
import AVKit
import AVFoundation

struct ContentView: View {
    @State private var player: AVPlayer?
    @State private var videoURL: URL?
    
    var body: some View {
        VStack {
            if let player = player {
                VideoPlayer(player: player)
                    .frame(height: 300)
            } else {
                Text("Video nicht geladen")
            }
            Button("Trim Video") {
                trimVideo()
            }
            .padding()
        }
        .onAppear {
            if let url = Bundle.main.url(forResource: "sample", withExtension: "mp4") {
                videoURL = url
                player = AVPlayer(url: url)
                player?.play()
            }
        }
    }
    
    func trimVideo() {
        guard let videoURL = videoURL else { return }
        let asset = AVURLAsset(url: videoURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else { return }
        
        let start = CMTime(seconds: 2, preferredTimescale: 600)
        let end = CMTime(seconds: 5, preferredTimescale: 600)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("trimmed.mp4")
        try? FileManager.default.removeItem(at: outputURL)
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = CMTimeRange(start: start, duration: CMTimeSubtract(end, start))
        
        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                if exportSession.status == .completed {
                    print("Video getrimmt: \(outputURL)")
                } else {
                    print("Fehler: \(exportSession.error?.localizedDescription ?? "unbekannter Fehler")")
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
