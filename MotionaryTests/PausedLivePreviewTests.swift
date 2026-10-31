import AVFoundation
import CoreImage
import Testing
import SwiftUI
import UIKit
@testable import Motionary

@Suite(.serialized)
struct PreviewLayoutTests {
    @MainActor
    @Test func rearrangingWorkspacePreservesNativePreviewSurfaces() async throws {
        let presentation = LivePreviewPresentation()
        let player = AVPlayer()
        func content(wide: Bool, hidden: Bool = false) -> some View {
            EditorPreviewWorkspaceLayout(
                usesSideWorkspace: wide, hidesPreview: hidden,
                previewHeight: 220, inspectorWidth: 360, controlHeight: 42,
                animatesWorkspaceChanges: true,
                workspaceID: wide ? "inspector" : "timeline",
                preview: {
                    ZStack {
                        PreviewRendererView(player: player)
                        LivePreviewSurface(presentation: presentation)
                    }
                }, controls: { Color.clear }, workspace: { Color.gray }
            )
        }
        let host = UIHostingController(rootView: content(wide: false))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
            if let view = root as? T { return view }
            return root.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        let originalPlayer = try #require(find(PreviewPlayerContainerView.self, in: host.view))
        let originalSurface = try #require(find(LivePreviewSampleView.self, in: host.view))
        for (wide, hidden) in [(true, false), (false, false), (false, true), (false, false)] {
            withAnimation(.smooth(duration: 0.2, extraBounce: 0)) {
                host.rootView = content(wide: wide, hidden: hidden)
            }
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(450))
            #expect(find(PreviewPlayerContainerView.self, in: host.view) === originalPlayer)
            #expect(find(LivePreviewSampleView.self, in: host.view) === originalSurface)
            #expect(originalPlayer.playerLayer.player === player)
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 96, 96, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
            let frame = try #require(buffer)
            presentation.frame = frame
            // Enqueue readiness may recover on a later display tick, including
            // while paused. No new gesture or SwiftUI update should be needed.
            for _ in 0..<100 where originalSurface.isHidden {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!originalSurface.isHidden)
            presentation.frame = nil
        }
    }
}

@Suite(.serialized)
struct PausedLivePreviewTests {
    /// Exercises the real AVFoundation snapshot and Metal graph, rather than
    /// mocking the direct renderer: masks, blends and adjustment ordering must
    /// match a freshly requested canonical frame after each edit.
    @MainActor
    @Test(arguments: [false, true])
    func decodedSnapshotRendersLiveEditsWithoutAnotherSeek(withVideo: Bool) async throws {
        var shape = ShapeTimelineItem(
            name: "Live shape", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle,
                             color: RGBAColor(red: 1, green: 0.2, blue: 0.1, alpha: 1),
                             width: 60, height: 60),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        shape.visuals.mask = ItemMask(shape: .ellipse, widthScale: 0.8, heightScale: 0.8)
        shape.visuals.blendMode = .screen
        let noir = try #require(EffectRegistry.shared.makeEffect(moduleID: .noir))
        var adjustment = AdjustmentTimelineItem(
            timelineStart: 0, duration: 1,
            visuals: TimelineItemVisuals(effectStack: EffectStack(effects: [noir]))
        )
        let videoURL = try await MediaConversionHelper.blankVideoClockURL(duration: 1, frameRate: 30)
        let video = TimelineClip(
            name: "Decoded source", source: ClipSource(url: videoURL, mediaType: .video,
                                                       originalDuration: 1, naturalSize: CGSizeValue(width: 16, height: 16)),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        var tracks = [
            TimelineTrack(name: "Adjustment", kind: .visual, items: [.adjustment(adjustment)]),
            TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        ]
        if withVideo { tracks.append(TimelineTrack(name: "Video", kind: .visual, clips: [video])) }
        let project = EditorProject(
            title: "Direct preview", renderSettings: RenderSettings(width: 96, height: 96, frameRate: 30),
            tracks: tracks
        )
        let service = CompositionRenderService()
        let sessionID = UUID()
        let prepared = try #require(try await service.preparePreview(
            for: project, quality: .interactive,
            invalidation: [.previewFrame, .compositionTopology], renderSessionID: sessionID
        ))
        let generator = AVAssetImageGenerator(asset: prepared.composition)
        generator.videoComposition = prepared.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let original = try await generator.image(at: time).image
        let originalPixels = pixels(CIImage(cgImage: original))
        service.livePreviewState.setInteractiveQualityOverride(true)

        for step in 1...3 {
            var transform = ClipTransform()
            transform.positionX.baseValue = Double(step * 8)
            transform.scale.baseValue = ScaleValue(x: 0.8, y: 0.8)
            transform.rotationDegrees.baseValue = Double(step * 15)
            service.livePreviewState.setTransform(transform, for: withVideo ? video.id : shape.id)
            adjustment.visuals.transform.positionX.baseValue = Double(step * -5)
            adjustment.visuals.mask = ItemMask(shape: .ellipse, widthScale: 0.7, heightScale: 0.7)
            service.livePreviewState.setVisuals(adjustment.visuals, for: adjustment.id)

            let direct: CVPixelBuffer? = await withCheckedContinuation { continuation in
                let accepted = service.livePreviewState.renderPausedFrame(
                    at: 0.5, sessionID: sessionID
                ) { continuation.resume(returning: $0) }
                if !accepted { continuation.resume(returning: nil) }
            }
            let buffer = try #require(direct)
            let directPixels = pixels(CIImage(cvPixelBuffer: buffer))
            #expect(directPixels != originalPixels)
            let canonical = try await generator.image(at: time).image
            let canonicalPixels = pixels(CIImage(cgImage: canonical))
            let error = zip(directPixels, canonicalPixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(error <= 2)
        }
        // A seek between frame boundaries must also be able to bootstrap
        // and reuse its exact decoded snapshot.
        let betweenFrames = try await generator.image(at: CMTime(seconds: 0.517, preferredTimescale: 600))
        let actualTime = CMTimeGetSeconds(betweenFrames.actualTime)
        #expect(abs(actualTime - CMTimeGetSeconds(CMTime(seconds: 0.517, preferredTimescale: 600))) < 0.000_01)
        let betweenFrameBuffer: CVPixelBuffer? = await withCheckedContinuation { continuation in
            let accepted = service.livePreviewState.renderPausedFrame(at: actualTime, sessionID: sessionID) {
                continuation.resume(returning: $0)
            }
            if !accepted { continuation.resume(returning: nil) }
        }
        #expect(betweenFrameBuffer != nil)
        #expect(!service.livePreviewState.renderPausedFrame(at: 0.6, sessionID: sessionID) { _ in
            Issue.record("A different timeline time reused stale sources")
        })
        #expect(!service.livePreviewState.renderPausedFrame(at: 0.5, sessionID: UUID()) { _ in
            Issue.record("A different session reused stale sources")
        })
        service.livePreviewState.clearPausedFrameRenderer()
        #expect(!service.livePreviewState.renderPausedFrame(at: 0.5, sessionID: sessionID) { _ in })
        withExtendedLifetime(generator) {}
    }

    @MainActor
    @Test func measureDisplaySizedLiveFrameLatency() async throws {
        let shape = ShapeTimelineItem(
            name: "Latency", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 480, height: 300),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let project = EditorProject(
            title: "Latency", renderSettings: RenderSettings(width: 960, height: 540, frameRate: 60),
            tracks: [TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])]
        )
        let service = CompositionRenderService()
        let session = UUID()
        let prepared = try #require(try await service.preparePreview(
            for: project, quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology], renderSessionID: session
        ))
        let generator = AVAssetImageGenerator(asset: prepared.composition)
        generator.videoComposition = prepared.videoComposition
        _ = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        service.livePreviewState.setInteractiveQualityOverride(true)
        var milliseconds: [Double] = []
        for index in 0..<65 {
            var transform = ClipTransform()
            transform.positionX.baseValue = Double(index)
            transform.scale.baseValue = ScaleValue(x: 1 + Double(index) / 200, y: 1 + Double(index) / 200)
            service.livePreviewState.setTransform(transform, for: shape.id)
            let start = ProcessInfo.processInfo.systemUptime
            let frame: CVPixelBuffer? = await withCheckedContinuation { continuation in
                if !service.livePreviewState.renderPausedFrame(at: 0.5, sessionID: session, completion: {
                    continuation.resume(returning: $0)
                }) { continuation.resume(returning: nil) }
            }
            #expect(frame != nil)
            if index >= 5 { milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        }
        milliseconds.sort()
        let report = "LIVE_PREVIEW_GPU_MS median=\(milliseconds[30]) p95=\(milliseconds[57]) max=\(milliseconds[59])"
        Attachment.record(report, named: "live-preview-render-latency.txt")
        withExtendedLifetime(generator) {}
    }

    @MainActor
    @Test func nativeSurfacePresentsWithoutSwiftUITransaction() throws {
        let presentation = LivePreviewPresentation()
        let view = LivePreviewSampleView()
        presentation.attach(view)
        #expect(view.isHidden)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 96, 96, kCVPixelFormatType_32BGRA,
                                   [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        guard let buffer else { Issue.record("Could not allocate surface frame"); return }
        presentation.frame = buffer
        // No await, run-loop advance or SwiftUI body evaluation is needed.
        #expect(!view.isHidden)
        presentation.frame = nil
        #expect(view.isHidden)
        presentation.detach(view)
    }

    private func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 96 * 96 * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: 96 * 4,
                           bounds: CGRect(x: 0, y: 0, width: 96, height: 96),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }
}

@Suite(.serialized)
struct WorkspaceTimelineTests {
    @Test func wideTimelineKeepsAllTracksAndCompactTimelineKeepsTheEditedTrack() throws {
        let first = AdjustmentTimelineItem(timelineStart: 0, duration: 3)
        let neighbour = AdjustmentTimelineItem(timelineStart: 3, duration: 2)
        let other = AdjustmentTimelineItem(timelineStart: 0, duration: 5)
        let tracks = [
            TimelineTrack(name: "Edited", kind: .visual, items: [.adjustment(first), .adjustment(neighbour)]),
            TimelineTrack(name: "Other", kind: .visual, items: [.adjustment(other)])
        ]
        let context = TimelineWorkspaceContext(itemID: first.id, activeSection: .effects,
                                               activeEffectID: nil, graphSegment: nil)
        let focusedTrack = try #require(context.track(in: tracks))
        #expect(focusedTrack.id == tracks[0].id)
        #expect(focusedTrack.items.map(\.id) == [first.id, neighbour.id])
        #expect(context.track(in: [tracks[1]]) == nil)
        #expect(context.displayedTracks(in: tracks).map(\.id) == tracks.map(\.id))
        var compact = context
        compact.showsOnlySelectedTrack = true
        #expect(compact.displayedTracks(in: tracks).map(\.id) == [tracks[0].id])
        let anotherSection = TimelineWorkspaceContext(itemID: first.id, activeSection: .transform,
                                                       activeEffectID: nil, graphSegment: nil)
        #expect(context != anotherSection)
        #expect(context.contentRevision != anotherSection.contentRevision)
    }

    @MainActor
    @Test(arguments: [false, true])
    func workspaceTimelineRetainsNormalRowsSelectionAndKeyframeContext(compact: Bool) async throws {
        var tracks = (0..<12).map { index in
            TimelineTrack(name: "Layer \(index)", kind: .visual,
                          items: [.adjustment(AdjustmentTimelineItem(timelineStart: 0, duration: 6))])
        }
        let neighbour = AdjustmentTimelineItem(timelineStart: 6, duration: 3)
        tracks[8].items.append(.adjustment(neighbour))
        let itemID = tracks[8].items[0].id
        let project = EditorProject(title: "Workspace timeline", tracks: tracks)
        let model = EditorViewModel(projectID: UUID(), projectStore: ProjectStore(),
                                    initialContent: ProjectContent(editorProject: project))
        model.selectTimelineItem(itemID, trackID: tracks[8].id)
        model.currentTime = 1.25
        let originalProject = model.project
        var zoom: CGFloat = 120
        let zoomBinding = Binding(get: { zoom }, set: { zoom = $0 })
        func content(focused: Bool) -> some View {
            EditorPreviewWorkspaceLayout(
                usesSideWorkspace: focused, hidesPreview: false,
                previewHeight: 220, inspectorWidth: 384, controlHeight: 220,
                keepsTimelineVisible: true, animatesWorkspaceChanges: true,
                workspaceID: focused ? "inspector" : "timeline",
                preview: { Color.black },
                controls: {
                    CoreTimelineView(viewModel: model, pixelsPerSecond: zoomBinding,
                                     workspaceContext: focused ? TimelineWorkspaceContext(
                                        itemID: itemID, activeSection: .transform,
                                        activeEffectID: nil, graphSegment: nil,
                                        showsOnlySelectedTrack: compact
                                     ) : nil)
                }, workspace: { Color.gray }
            )
            .frame(width: 1000, height: 500)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: content(focused: false))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 540)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let scroll = try #require(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
        scroll.contentOffset.y = 180
        host.rootView = content(focused: true)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        #expect(descendants(host.view).compactMap { $0 as? UIScrollView }.first === scroll)
        #expect(scroll.alwaysBounceVertical == !compact)
        #expect(abs(scroll.contentOffset.y - (compact ? 0 : 180)) < 1)
        #expect(abs(scroll.bounds.width - 600) < 1)
        let trackLabels = descendants(scroll).compactMap(\.accessibilityIdentifier)
            .filter { $0.hasPrefix("timeline-track-") }
        #expect(trackLabels.contains("timeline-track-\(tracks[8].id.uuidString)"))
        #expect(compact ? trackLabels.count == 1 : trackLabels.count > 1)
        #expect(descendants(scroll).contains { ($0.accessibilityLabel ?? "").hasPrefix("Trim ") })
        #expect(model.currentTime == 1.25)
        let neighbourView = try #require(descendants(scroll).first {
            $0.accessibilityIdentifier == "timeline-item-\(neighbour.id.uuidString)"
        })
        #expect(neighbourView.accessibilityActivate())
        #expect(model.selectedClipID == neighbour.id)
        #expect(model.selectedTrackID == tracks[8].id)
        let selectedTime = model.currentTime
        #expect(zoom == 120)
        #expect(model.project == originalProject)
        host.rootView = content(focused: false)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        #expect(descendants(host.view).compactMap { $0 as? UIScrollView }.first === scroll)
        #expect(scroll.alwaysBounceVertical)
        #expect(abs(scroll.contentOffset.y - 180) < 1)
        #expect(abs(scroll.bounds.width - 1000) < 1)
        #expect(zoom == 120)
        #expect(model.currentTime == selectedTime)
        #expect(model.project == originalProject)
    }
}
