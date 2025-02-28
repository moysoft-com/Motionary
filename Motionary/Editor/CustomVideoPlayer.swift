//
//  PlayerView.swift
//  Motionary
//
//  Created by Lian on 28.02.25.
//


import SwiftUI
import AVFoundation

class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct CustomVideoPlayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let playerView = uiView as? PlayerView {
            playerView.playerLayer.player = player
            playerView.playerLayer.frame = uiView.bounds
        }
    }
}