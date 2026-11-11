// UIKit gesture bridge for timeline tap, double-tap, long-press, and drag handling.

import SwiftUI
import UIKit

struct TimelineLongPressInteractionTarget: UIViewRepresentable {
    let minimumPressDuration: TimeInterval
    let allowableMovement: CGFloat
    var accessibilityIdentifier: String = ""
    var accessibilityLabel: String = "Timeline item"
    let onTap: () -> Void
    var tapMenu: (() -> UIMenu)? = nil
    var onDoubleTap: (() -> Void)? = nil
    let onLongPressBegan: () -> Void
    let onLongPressChanged: (TimelineLongPressDragValue) -> Void
    let onLongPressEnded: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = TimelineAccessibleInteractionView()
        view.onActivate = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return false }
            if coordinator.parent.tapMenu != nil {
                coordinator.presentTapMenu(from: view)
            } else {
                coordinator.parent.onTap()
            }
            return true
        }
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = accessibilityIdentifier
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityTraits = .button

        if tapMenu != nil {
            let editMenu = UIEditMenuInteraction(delegate: context.coordinator)
            context.coordinator.editMenuInteraction = editMenu
            view.addInteraction(editMenu)
        }

        let tap = TimelineTapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        if onDoubleTap != nil {
            let doubleTap = TimelineTapGestureRecognizer(
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
        longPress.allowableMovement = min(allowableMovement, TimelineGestureIntent.selectionSlop)
        longPress.numberOfTouchesRequired = 1
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        view.addGestureRecognizer(longPress)
        tap.require(toFail: longPress)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        uiView.accessibilityIdentifier = accessibilityIdentifier
        uiView.accessibilityLabel = accessibilityLabel
        if let longPress = uiView.gestureRecognizers?.compactMap({ $0 as? UILongPressGestureRecognizer }).first {
            longPress.minimumPressDuration = minimumPressDuration
            longPress.allowableMovement = min(allowableMovement, TimelineGestureIntent.selectionSlop)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cancelActiveDrag()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
        var parent: TimelineLongPressInteractionTarget
        private var startLocation: CGPoint = .zero
        private var isActive = false
        weak var editMenuInteraction: UIEditMenuInteraction?

        init(parent: TimelineLongPressInteractionTarget) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !hasActiveScroll(in: recognizer.view) else { return }
            if parent.tapMenu != nil, let view = recognizer.view {
                presentTapMenu(from: view)
            } else {
                parent.onTap()
            }
        }

        func presentTapMenu(from view: UIView) {
            guard parent.tapMenu != nil, let editMenuInteraction else {
                parent.onTap()
                return
            }
            editMenuInteraction.presentEditMenu(
                with: UIEditMenuConfiguration(
                    identifier: parent.accessibilityIdentifier as NSString,
                    sourcePoint: CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                )
            )
        }

        func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor configuration: UIEditMenuConfiguration,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            parent.tapMenu?()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !hasActiveScroll(in: recognizer.view) else { return }
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
                parent.onLongPressEnded(true)
            case .cancelled, .failed:
                guard isActive else { return }
                isActive = false
                parent.onLongPressEnded(false)
            default:
                break
            }
        }

        func cancelActiveDrag() {
            guard isActive else { return }
            isActive = false
            parent.onLongPressEnded(false)
        }

        private func hasActiveScroll(in view: UIView?) -> Bool {
            var ancestor = view?.superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView,
                    scroll.isDragging || scroll.isDecelerating || scroll.isZooming
                {
                    return true
                }
                ancestor = current.superview
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // A touch used to stop momentum must not later select or lift a layer.
            !hasActiveScroll(in: gestureRecognizer.view)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            !hasActiveScroll(in: gestureRecognizer.view)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // A scroll that wins must invalidate tap/hold for the entire touch sequence.
            // A hold that wins first owns the subsequent drag instead.
            false
        }
    }
}

/// Tracks the furthest excursion, so moving out and back never becomes a tap.
struct TimelineGestureIntent {
    static let selectionSlop: CGFloat = 6
    static let directionSlop: CGFloat = 3
    private(set) var maximumDistance: CGFloat = 0

    mutating func record(_ translation: CGSize) {
        maximumDistance = max(maximumDistance, hypot(translation.width, translation.height))
    }

    var permitsSelection: Bool { maximumDistance <= Self.selectionSlop }

    static func axis(for translation: CGSize) -> Axis? {
        guard max(abs(translation.width), abs(translation.height)) >= directionSlop else { return nil }
        return abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
    }
}

final class TimelineTapGestureRecognizer: UITapGestureRecognizer {
    private var startLocation: CGPoint?
    private var intent = TimelineGestureIntent()

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        startLocation = touches.first?.location(in: view?.window)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard recordMovement(touches, event: event) else { return }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard recordMovement(touches, event: event) else { return }
        super.touchesEnded(touches, with: event)
    }

    private func recordMovement(_ touches: Set<UITouch>, event: UIEvent) -> Bool {
        if let startLocation, let touch = touches.first {
            for sample in event.coalescedTouches(for: touch) ?? [touch] {
                let location = sample.location(in: view?.window)
                intent.record(CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y))
            }
        }
        if !intent.permitsSelection, state == .possible {
            state = .failed
            return false
        }
        return true
    }

    override func reset() {
        super.reset()
        startLocation = nil
        intent = TimelineGestureIntent()
    }
}

struct TimelineLongPressDragValue {
    let translation: CGSize
    let locationInWindow: CGPoint
}

private final class TimelineAccessibleInteractionView: UIView {
    var onActivate: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        onActivate?() ?? false
    }
}
