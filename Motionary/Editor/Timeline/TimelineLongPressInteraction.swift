// UIKit gesture bridge for timeline tap, double-tap, long-press, and drag handling.

import SwiftUI
import UIKit

struct TimelineLongPressInteractionTarget: UIViewRepresentable {
    let minimumPressDuration: TimeInterval
    let allowableMovement: CGFloat
    let onTap: () -> Void
    var onDoubleTap: (() -> Void)? = nil
    let onLongPressBegan: () -> Void
    let onLongPressChanged: (TimelineLongPressDragValue) -> Void
    let onLongPressEnded: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = InteractionView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        if onDoubleTap != nil {
            let doubleTap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleDoubleTap(_:))
            )
            doubleTap.numberOfTapsRequired = 2
            doubleTap.cancelsTouchesInView = false
            doubleTap.delegate = context.coordinator
            view.addGestureRecognizer(doubleTap)
            tap.require(toFail: doubleTap)
        }

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = minimumPressDuration
        longPress.allowableMovement = allowableMovement
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)
        tap.require(toFail: longPress)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        if let longPress = uiView.gestureRecognizers?.compactMap({ $0 as? UILongPressGestureRecognizer }).first {
            longPress.minimumPressDuration = minimumPressDuration
            longPress.allowableMovement = allowableMovement
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TimelineLongPressInteractionTarget
        private var startLocation: CGPoint = .zero
        private var isActive = false

        init(parent: TimelineLongPressInteractionTarget) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onTap()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onDoubleTap?()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view.window)

            switch recognizer.state {
            case .began:
                startLocation = location
                isActive = true
                parent.onLongPressBegan()
            case .changed:
                guard isActive else { return }
                parent.onLongPressChanged(
                    TimelineLongPressDragValue(
                        translation: CGSize(
                            width: location.x - startLocation.x,
                            height: location.y - startLocation.y
                        ),
                        locationInWindow: location
                    )
                )
            case .ended:
                guard isActive else { return }
                isActive = false
                (view as? InteractionView)?.resetTouchTracking()
                parent.onLongPressEnded(true)
            case .cancelled, .failed:
                guard isActive else { return }
                isActive = false
                (view as? InteractionView)?.resetTouchTracking()
                parent.onLongPressEnded(false)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer is UILongPressGestureRecognizer,
                let view = gestureRecognizer.view as? InteractionView,
                let translation = view.touchTranslation
            else {
                return true
            }

            let horizontal = abs(translation.width)
            let vertical = abs(translation.height)
            if horizontal > 12, horizontal > vertical * 1.35 {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }

    final class InteractionView: UIView {
        var initialTouchLocation: CGPoint?
        private var latestTouchLocation: CGPoint?

        var touchTranslation: CGSize? {
            guard let initialTouchLocation, let latestTouchLocation else { return nil }
            return CGSize(
                width: latestTouchLocation.x - initialTouchLocation.x,
                height: latestTouchLocation.y - initialTouchLocation.y
            )
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first {
                let location = touch.location(in: self)
                initialTouchLocation = location
                latestTouchLocation = location
            }
            super.touchesBegan(touches, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first {
                latestTouchLocation = touch.location(in: self)
            }
            super.touchesMoved(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            resetTouchTracking()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            resetTouchTracking()
        }

        func resetTouchTracking() {
            initialTouchLocation = nil
            latestTouchLocation = nil
        }
    }
}

struct TimelineLongPressDragValue {
    let translation: CGSize
    let locationInWindow: CGPoint
}
