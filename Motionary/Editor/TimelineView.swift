import SwiftUI
import AVFoundation

struct Thumbnail: Identifiable {
    let id = UUID()
    let time: Double
    let image: UIImage
}

struct TimelineView: View {
    @Binding var clips: [Clip]
    @Binding var currentTime: Double
    var baseDuration: Double
    var asset: AVAsset?
    
    var onClipTap: (Clip) -> Void
    var onTimelineDrag: (Double) -> Void
    var selectedClip: Clip?
    
    @State private var thumbnails: [Thumbnail] = []
    @State private var dragTranslation: CGFloat = 0
    
    let fallbackColors: [Color] = [.blue, .orange, .purple, .pink, .yellow, .mint, .indigo]
    let pixelsPerSecond: CGFloat = 40
    
    var body: some View {
        GeometryReader { geo in
            let contentWidth = baseDuration * pixelsPerSecond
            let visibleCenter = geo.size.width / 2
            let baseOffset = visibleCenter - (CGFloat(currentTime) * pixelsPerSecond)
            let totalOffset = baseOffset + dragTranslation
            
            ZStack {
                HStack(spacing: 10) {
                    ForEach(clips.indices, id: \.self) { i in
                        let clip = clips[i]
                        let clipWidth = CGFloat(clip.end - clip.start) * pixelsPerSecond
                        ZStack {
                            let clipThumbs = thumbnails.filter { $0.time >= clip.start && $0.time <= clip.end }
                            if !clipThumbs.isEmpty {
                                let thumbWidth = clipWidth / CGFloat(clipThumbs.count)
                                HStack(spacing: 0) {
                                    ForEach(clipThumbs) { thumb in
                                        Image(uiImage: thumb.image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: thumbWidth, height: geo.size.height)
                                            .clipped()
                                    }
                                }
                            } else {
                                Rectangle()
                                    .fill(fallbackColor(for: i))
                                    .frame(width: clipWidth, height: geo.size.height)
                            }
                            if let sel = selectedClip, sel == clip {
                                Rectangle().stroke(Color.white, lineWidth: 3)
                            }
                        }
                        .frame(width: clipWidth, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { onClipTap(clip) }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .offset(x: totalOffset)
                .animation(.easeOut(duration: 0.2), value: totalOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragTranslation = value.translation.width
                            let newOffset = baseOffset + dragTranslation
                            let newTime = (visibleCenter - newOffset) / pixelsPerSecond
                            let clampedTime = min(max(newTime, 0), baseDuration)
                            onTimelineDrag(clampedTime)
                        }
                        .onEnded { _ in dragTranslation = 0 }
                )
                
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: geo.size.height)
                    .position(x: visibleCenter, y: geo.size.height / 2)
            }
        }
        .border(Color.green, width: 3)
        .clipped()
        .onAppear { generateThumbnails() }
    }
    
    func fallbackColor(for index: Int) -> Color {
        fallbackColors[index % fallbackColors.count]
    }
    
    func generateThumbnails() {
        guard let asset = asset, baseDuration > 0 else {
            print("Kein Asset oder ungültige Dauer")
            return
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let count = 20
        let step = baseDuration / Double(count - 1)
        var thumbs: [Thumbnail] = []
        let times: [CMTime] = (0..<count).map { i in
            CMTime(seconds: Double(i) * step, preferredTimescale: 600)
        }
        let timesNS = times.map { NSValue(time: $0) }
        var remaining = count
        
        generator.generateCGImagesAsynchronously(forTimes: timesNS) { requestedTime, cgImage, _, result, error in
            if let cgImage = cgImage, result == .succeeded {
                thumbs.append(Thumbnail(time: requestedTime.seconds, image: UIImage(cgImage: cgImage)))
            } else {
                print("Fehler beim Thumbnail: \(error?.localizedDescription ?? "unbekannter Fehler")")
            }
            remaining -= 1
            if remaining == 0 {
                DispatchQueue.main.async {
                    self.thumbnails = thumbs.sorted { $0.time < $1.time }
                }
            }
        }
    }
}
