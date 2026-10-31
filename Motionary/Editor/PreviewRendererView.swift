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
}

/// Delivers completed frames straight to UIKit. Routing GPU completions
/// through @Published/SwiftUI adds an extra UI transaction to every frame.
@MainActor
final class LivePreviewPresentation: ObservableObject {
    private var storedFrame: CVPixelBuffer?
    var frame: CVPixelBuffer? {
        get { storedFrame }
        set {
            storedFrame = newValue
            surface?.present(newValue)
        }
    }
    private weak var surface: LivePreviewSampleView?
    private var isInteracting = false

    var maximumFramesPerSecond: Int {
        surface?.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
    }

    func setInteracting(_ active: Bool) {
        guard isInteracting != active else { return }
        isInteracting = active
        surface?.setInteracting(active)
    }

    func attach(_ view: LivePreviewSampleView) {
        guard surface !== view else { return }
        surface?.setInteracting(false)
        surface = view
        view.setInteracting(isInteracting)
        view.present(frame)
    }

    func detach(_ view: LivePreviewSampleView) {
        guard surface === view else { return }
        view.setInteracting(false)
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
    private var formatDescription: CMVideoFormatDescription?
    private var displayLink: CADisplayLink?
    private var isInteracting = false
    private var waitingFrame: CVPixelBuffer?

    // A weak target avoids a view/display-link retain cycle when a window
    // disappears during an interaction.
    private final class DisplayLinkTarget: NSObject {
        weak var view: LivePreviewSampleView?
        @objc func tick() {
            if let frame = view?.waitingFrame { view?.present(frame) }
        }
    }
    private let displayLinkTarget = DisplayLinkTarget()

    func setInteracting(_ active: Bool) {
        isInteracting = active
        updateDisplayLink()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    private func updateDisplayLink() {
        // A paused edit can hit backpressure too. Retry its latest frame even
        // after the gesture has ended, rather than leaving the old image up.
        guard isInteracting || waitingFrame != nil,
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
            waitingFrame = nil
            updateDisplayLink()
            presentedFrame = nil
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
            isHidden = true
            return
        }
        guard presentedFrame !== frame else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else {
            waitingFrame = frame
            updateDisplayLink()
            return
        }
        if formatDescription.map({ CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: frame) }) != true {
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: frame,
                formatDescriptionOut: &formatDescription
            ) == noErr else { return }
        }
        guard let format = formatDescription else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                       presentationTimeStamp: .zero,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame,
            formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true
        ) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        waitingFrame = nil
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
