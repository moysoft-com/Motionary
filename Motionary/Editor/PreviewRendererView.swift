// AVPlayer-backed SwiftUI preview surface.

import AVFoundation
import SwiftUI
import UIKit

/// Mount the editor's existing playback layer. Rebuilding the surrounding
/// SwiftUI layout must not disconnect the decoder from its display client.
struct PreviewRendererView: UIViewRepresentable {
    let playerLayer: AVPlayerLayer

    final class Host: UIView {
        var playbackLayer: AVPlayerLayer? {
            didSet {
                if oldValue?.superlayer === layer { oldValue?.removeFromSuperlayer() }
                if let playbackLayer { layer.addSublayer(playbackLayer) }
                setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let playbackLayer, playbackLayer.superlayer === layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playbackLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.isOpaque = false
        host.isAccessibilityElement = true
        host.accessibilityIdentifier = "editor-preview-image"
        host.accessibilityLabel = String(localized: "Preview")
        host.accessibilityTraits = .image
        host.playbackLayer = playerLayer
        return host
    }

    func updateUIView(_ view: Host, context: Context) {
        if view.playbackLayer !== playerLayer { view.playbackLayer = playerLayer }
    }

    static func dismantleUIView(_ view: Host, coordinator: ()) {
        view.playbackLayer = nil
    }
}

/// Delivers completed frames straight to UIKit. Routing GPU completions
/// through @Published/SwiftUI adds an extra UI transaction to every frame.
@MainActor
final class LivePreviewPresentation: ObservableObject {
    let playerLayer = AVPlayerLayer()
    var playing = false {
        didSet { if playing { frame = nil } }
    }
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
        guard frame == nil || !playing else { return }
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
    private var formatDescription: CMVideoFormatDescription?

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
        guard let frame else {
            waitingSample = nil
            presentedFrame = nil
            formatDescription = nil
            updateDisplayLink()
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
            isHidden = true
            return
        }
        if waitingSample?.frame === frame { return }
        waitingSample = nil
        guard presentedFrame !== frame || displayLayer.sampleBufferRenderer.status == .failed else {
            updateDisplayLink()
            return
        }

        // A sample wraps the existing pixel buffer. Keep only the latest
        // waiting sample if the display layer applies backpressure.
        guard let sample = makeSample(for: frame) else {
            updateDisplayLink()
            return
        }
        waitingSample = (sample, frame)
        retryWaitingSample()
    }

    private func makeSample(for frame: CVPixelBuffer) -> CMSampleBuffer? {
        if formatDescription.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: frame) }) != true {
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: frame,
                formatDescriptionOut: &format
            ) == noErr else { return nil }
            formatDescription = format
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame,
            formatDescription: formatDescription, sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true
        ) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
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
