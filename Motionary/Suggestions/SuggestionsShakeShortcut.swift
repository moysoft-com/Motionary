import SwiftUI
import UIKit

struct SuggestionsShakeShortcut: ViewModifier {
    let surface: SuggestionsToastSurface

    @Environment(\.scenePhase) private var scenePhase
    @State private var isToastVisible = false
    @State private var contentTop: CGFloat = 0
    @State private var showsSuggestions = false

    func body(content: Content) -> some View {
        content
            .background(alignment: .topLeading) {
                ShakeReceiver(
                    surface: surface,
                    onShake: showToast,
                    onContentTopChange: isToastVisible ? updateToastPosition : nil
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                if isToastVisible {
                    Button {
                        isToastVisible = false
                        showsSuggestions = true
                    } label: {
                        MotionaryConfirmationToast(
                            message: "Share an idea or report a bug",
                            systemImage: "ladybug.fill",
                            showsChevron: true
                        )
                        .contentShape(.rect(cornerRadius: 17))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.top, contentTop + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("suggestions-shake-toast")
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isToastVisible)
            .task(id: isToastVisible) {
                guard isToastVisible else { return }
                EditorHaptics.tap()
                do {
                    try await Task.sleep(for: .milliseconds(90))
                    EditorHaptics.editCommit()
                    try await Task.sleep(for: .milliseconds(5_910))
                    isToastVisible = false
                } catch {
                    return
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { isToastVisible = false }
            }
            .fullScreenCover(isPresented: $showsSuggestions) {
                NavigationStack {
                    SuggestionsListView(opensComposer: true)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showsSuggestions = false }
                            }
                        }
                }
            }
    }

    private func showToast(below top: CGFloat) {
        guard scenePhase == .active, !isToastVisible, !showsSuggestions else { return }
        contentTop = top
        isToastVisible = true
    }

    private func updateToastPosition(_ top: CGFloat) {
        if isToastVisible, contentTop != top { contentTop = top }
    }
}

enum SuggestionsToastSurface {
    case projects, editor, settings
}

extension View {
    func suggestionsToastBoundary(_ surface: SuggestionsToastSurface, alignment: Alignment = .bottom) -> some View {
        overlay(alignment: alignment) {
            ToastBoundary(surface: surface)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct ToastBoundary: UIViewRepresentable {
    let surface: SuggestionsToastSurface

    func makeUIView(context: Context) -> BoundaryView { BoundaryView(surface: surface) }

    func updateUIView(_ view: BoundaryView, context: Context) {
        view.surface = surface
    }

    final class BoundaryView: UIView {
        var surface: SuggestionsToastSurface

        init(surface: SuggestionsToastSurface) {
            self.surface = surface
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
    }
}

private struct ShakeReceiver: UIViewRepresentable {
    let surface: SuggestionsToastSurface
    let onShake: (CGFloat) -> Void
    let onContentTopChange: ((CGFloat) -> Void)?

    func makeUIView(context: Context) -> ResponderView { ResponderView() }

    func updateUIView(_ view: ResponderView, context: Context) {
        view.onShake = onShake
        view.surface = surface
        view.onContentTopChange = onContentTopChange
        view.scheduleActivation()
    }

    /// UIKit delivers shake events to the first responder. Leave active text inputs in control.
    final class ResponderView: UIView {
        var onShake: ((CGFloat) -> Void)?
        var onContentTopChange: ((CGFloat) -> Void)?
        var surface: SuggestionsToastSurface = .projects
        override var canBecomeFirstResponder: Bool { true }

        init() {
            super.init(frame: .zero)
            for name in [
                UIWindow.didBecomeKeyNotification,
                UIApplication.didBecomeActiveNotification,
                UITextField.textDidEndEditingNotification,
                UITextView.textDidEndEditingNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(restoreResponder), name: name, object: nil
                )
            }
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleActivation()
        }

        @objc private func restoreResponder(_: Notification) {
            scheduleActivation()
        }

        func scheduleActivation() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.isKeyWindow,
                      window.rootViewController?.presentedViewController == nil else { return }
                self.onContentTopChange?(self.contentTop(in: window))
                guard !self.isFirstResponder,
                      !self.containsEditingResponder(window) else { return }
                self.becomeFirstResponder()
            }
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard motion == .motionShake, let window, window.isKeyWindow,
                  window.rootViewController?.presentedViewController == nil,
                  window.undoManager?.canUndo != true, window.undoManager?.canRedo != true else {
                super.motionEnded(motion, with: event)
                return
            }
            onShake?(contentTop(in: window))
        }

        private func contentTop(in window: UIWindow) -> CGFloat {
            let origin = convert(.zero, to: window).y
            return max(0, visibleHeaderBottom(in: window, window: window) - origin)
        }

        private func visibleHeaderBottom(in view: UIView, window: UIWindow) -> CGFloat {
            guard !view.isHidden, view.alpha > 0.01 else { return 0 }

            if let marker = view as? ToastBoundary.BoundaryView, marker.surface == surface {
                return marker.convert(.zero, to: window).y
            }
            // Pushed Settings screens use UIKit navigation bars instead of our custom header.
            if surface == .settings, let bar = view as? UINavigationBar {
                let frame = bar.convert(bar.bounds, to: window)
                return frame.intersects(window.bounds) ? frame.maxY : 0
            }
            return view.subviews.reduce(CGFloat.zero) { bottom, child in
                max(bottom, visibleHeaderBottom(in: child, window: window))
            }
        }

        private func containsEditingResponder(_ view: UIView) -> Bool {
            if view.isFirstResponder && view is UITextInput { return true }
            return view.subviews.contains(where: containsEditingResponder)
        }
    }
}
