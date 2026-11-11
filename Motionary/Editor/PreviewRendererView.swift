// AVPlayer-backed SwiftUI preview surface.

import AVFoundation
import SwiftUI
import UIKit

/// Hosts an `AVPlayerLayer` as the view's backing layer.
final class PreviewPlayerContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as? AVPlayerLayer ?? AVPlayerLayer()
    }
}

/// Displays an AVFoundation player without introducing SwiftUI video controls.
struct PreviewRendererView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PreviewPlayerContainerView {
        let view = PreviewPlayerContainerView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.playerLayer.player = player
        view.playerLayer.backgroundColor = UIColor.clear.cgColor
        view.playerLayer.isOpaque = false
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewPlayerContainerView, context: Context) {
        uiView.backgroundColor = .clear
        uiView.playerLayer.backgroundColor = UIColor.clear.cgColor
        uiView.playerLayer.player = player
    }

    static func dismantleUIView(_ uiView: PreviewPlayerContainerView, coordinator: Void) {
        // SwiftUI may retain the removed view graph. Release its media client
        // immediately instead of keeping the previous player's layer attached.
        uiView.playerLayer.player = nil
    }
}

/// Delivers completed frames straight to UIKit. Routing GPU completions
/// through @Published/SwiftUI adds an extra UI transaction to every frame.
@MainActor
final class LivePreviewPresentation: ObservableObject {
    private var storedFrame: CVPixelBuffer?
    @Published private(set) var frameTime: Double?
    var frame: CVPixelBuffer? {
        get { storedFrame }
        set { setFrame(newValue, at: nil) }
    }
    private weak var surface: LivePreviewSampleView?

    var maximumFramesPerSecond: Int {
        surface?.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
    }

    func setFrame(_ frame: CVPixelBuffer?, at time: Double?) {
        storedFrame = frame
        // `frameTime` is observed by the preview canvas, so publishing the
        // same time again (the common case for inspector/canvas drags at a
        // fixed playhead) would invalidate the whole canvas for no visual
        // reason — the frame itself reaches the display layer directly.
        if let time, frame != nil, frameTime != time {
            frameTime = time
        } else if frame == nil || time == nil, frameTime != nil {
            frameTime = nil
        }
        surface?.present(frame)
    }

    func attach(_ view: LivePreviewSampleView) {
        guard surface !== view else { return }
        surface?.present(nil)
        surface = view
        view.present(frame)
    }

    func detach(_ view: LivePreviewSampleView) {
        guard surface === view else { return }
        view.present(nil)
        surface = nil
    }

    /// Drops the frame's model ownership while keeping the already displayed
    /// sample buffer in place until a replacement arrives. Scrubbing can then
    /// cover decoder gaps without treating that held frame as the current one.
    func clearFramePreservingDisplay() {
        storedFrame = nil
    }
}

final class LivePreviewSampleView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private var presentedFrame: CVPixelBuffer?
    private var displayLink: CADisplayLink?
    private var waitingSample: (sample: CMSampleBuffer, frame: CVPixelBuffer)?
    // Sample-buffer construction is pure CoreMedia work (format description +
    // a wrapper sample buffer); only the `enqueue` itself must stay on Main
    // because it touches UIKit. Construction moves to a dedicated serial
    // queue so the MainActor no longer pays it per frame; the latest request
    // wins, so a slow queue can never reorder frames.
    private let presentQueue = DispatchQueue(label: "com.motionary.live-preview.present", qos: .userInitiated)
    private var presentGeneration: UInt64 = 0
    private var offMainFormatDescription: CMVideoFormatDescription?

    // A weak target avoids a view/display-link retain cycle when a window
    // disappears during an interaction.
    private final class DisplayLinkTarget: NSObject {
        weak var view: LivePreviewSampleView?
        @objc func tick() {
            view?.retryWaitingSample()
        }
    }
    private let displayLinkTarget = DisplayLinkTarget()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    private func updateDisplayLink() {
        // A paused edit can hit backpressure too. Retry its latest frame even
        // after the gesture has ended, rather than leaving the old image up.
        guard waitingSample != nil,
            let screen = window?.windowScene?.screen
        else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        guard displayLink == nil else { return }
        displayLinkTarget.view = self
        let link = CADisplayLink(target: displayLinkTarget, selector: #selector(DisplayLinkTarget.tick))
        let maximum = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximum), maximum: maximum, preferred: maximum
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    deinit { displayLink?.invalidate() }

    func present(_ frame: CVPixelBuffer?) {
        // An older backpressured sample must never supersede a new request.
        presentGeneration &+= 1
        waitingSample = nil
        updateDisplayLink()
        guard let frame else {
            presentedFrame = nil
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
            isHidden = true
            return
        }
        guard presentedFrame !== frame || displayLayer.sampleBufferRenderer.status == .failed else { return }
        let generation = presentGeneration
        // Visibility flips synchronously on Main; only the sample build and
        // the `enqueue` itself are deferred. An empty display layer is
        // transparent, and the canonical player frame / opening placeholder
        // behind this surface already shows through, so presenting early
        // stays invisible while callers can rely on the view being visible
        // without awaiting the off-main build. A failed build restores the
        // previous visibility instead of stranding an empty view.
        let wasHidden = isHidden
        isHidden = false
        presentQueue.async { [weak self, frame] in
            guard let self else { return }
            self.makeSample(for: frame) { [weak self] sample in
                guard let self else { return }
                DispatchQueue.main.async { [weak self, frame, wasHidden] in
                    guard let self, self.presentGeneration == generation else { return }
                    self.enqueue(sample, frame: frame, fallbackHidden: wasHidden)
                }
            }
        }
    }

    /// Builds the sample buffer off the main thread. CoreMedia wrapper
    /// construction has no UIKit dependency, so the produced sample is
    /// byte-identical to the previous main-thread version.
    private func makeSample(for frame: CVPixelBuffer, completion: @escaping (CMSampleBuffer?) -> Void) {
        if offMainFormatDescription.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: frame) }) != true {
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: frame,
                formatDescriptionOut: &format
            ) == noErr, let format else {
                completion(nil)
                return
            }
            offMainFormatDescription = format
        }
        guard let format = offMainFormatDescription else {
            completion(nil)
            return
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: .zero,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame,
            formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            completion(nil)
            return
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true
        ) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        completion(sample)
    }

    /// Runs on Main only: backpressure, `enqueue` and visibility all touch
    /// UIKit and therefore stay on the main queue.
    private func enqueue(_ sample: CMSampleBuffer?, frame: CVPixelBuffer, fallbackHidden: Bool) {
        guard let sample else {
            isHidden = fallbackHidden
            return
        }
        waitingSample = (sample, frame)
        retryWaitingSample()
    }

    private func retryWaitingSample() {
        guard let (sample, frame) = waitingSample else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else {
            updateDisplayLink()
            return
        }
        waitingSample = nil
        updateDisplayLink()
        renderer.enqueue(sample)
        presentedFrame = frame
        isHidden = false
    }
}

struct LivePreviewSurface: UIViewRepresentable {
    let presentation: LivePreviewPresentation

    @MainActor
    final class Coordinator {
        weak var presentation: LivePreviewPresentation?
        init(_ presentation: LivePreviewPresentation) { self.presentation = presentation }
    }

    func makeCoordinator() -> Coordinator { Coordinator(presentation) }

    func makeUIView(context: Context) -> LivePreviewSampleView {
        let view = LivePreviewSampleView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.displayLayer.videoGravity = .resizeAspect
        presentation.attach(view)
        return view
    }

    func updateUIView(_ view: LivePreviewSampleView, context: Context) {
        if context.coordinator.presentation !== presentation {
            context.coordinator.presentation?.detach(view)
            context.coordinator.presentation = presentation
        }
        presentation.attach(view)
    }

    static func dismantleUIView(_ view: LivePreviewSampleView, coordinator: Coordinator) {
        coordinator.presentation?.detach(view)
    }
}
