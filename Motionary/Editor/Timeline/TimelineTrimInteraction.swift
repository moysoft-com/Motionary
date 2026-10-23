// Directional UIKit trim gesture with an explicit cancellation path.

import SwiftUI
import UIKit

struct TimelineTrimInteractionTarget: UIViewRepresentable {
    let accessibilityIdentifier: String
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = accessibilityIdentifier
        view.accessibilityLabel = accessibilityIdentifier.hasSuffix("start") ? "Trim start" : "Trim end"
        let recognizer = TimelineTrimGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTrim(_:))
        )
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.finish(translation: 0, commit: false)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TimelineTrimInteractionTarget
        private var isActive = false

        init(parent: TimelineTrimInteractionTarget) { self.parent = parent }

        @objc func handleTrim(_ recognizer: TimelineTrimGestureRecognizer) {
            update(state: recognizer.state, translation: recognizer.translation.width)
        }

        func update(state: UIGestureRecognizer.State, translation: CGFloat) {
            switch state {
            case .began, .changed:
                isActive = true
                parent.onChanged(translation)
            case .ended:
                finish(translation: translation, commit: true)
            case .cancelled, .failed:
                finish(translation: translation, commit: false)
            default:
                break
            }
        }

        func finish(translation: CGFloat, commit: Bool) {
            guard isActive else { return }
            isActive = false
            parent.onEnded(translation, commit)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Let the handle decide the initial direction before its ancestor scrolls.
            // Vertical motion fails immediately; horizontal motion belongs to trimming.
            guard let scroll = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scroll.panGestureRecognizer
        }
    }
}

final class TimelineTrimGestureRecognizer: UIGestureRecognizer {
    private var trackedTouch: UITouch?
    private var startLocation = CGPoint.zero
    private(set) var translation = CGSize.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1,
            event.allTouches?.filter({ $0.phase != .ended && $0.phase != .cancelled }).count == 1,
            let touch = touches.first
        else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        trackedTouch = touch
        startLocation = touch.location(in: view?.window)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        updateTranslation()
        if state == .possible {
            switch TimelineGestureIntent.axis(for: translation) {
            case .horizontal: state = .began
            case .vertical: state = .failed
            case nil: break
            }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        updateTranslation()
        state = state == .began || state == .changed ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        translation = .zero
    }

    private func updateTranslation() {
        guard let trackedTouch else { return }
        let location = trackedTouch.location(in: view?.window)
        translation = CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)
    }
}
