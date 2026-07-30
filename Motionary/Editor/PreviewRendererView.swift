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
