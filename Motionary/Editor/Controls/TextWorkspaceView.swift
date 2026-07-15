// Focused text content, typography, style, and motion workspaces.

import SwiftUI
import UIKit

enum TextWorkspaceMode: Equatable {
    case content
    case type
    case style
    case motion

    var title: String {
        switch self {
        case .content: "Text"
        case .type: "Type"
        case .style: "Style"
        case .motion: "Motion"
        }
    }

    var systemImage: String {
        switch self {
        case .content: "text.cursor"
        case .type: "textformat.size"
        case .style: "paintbrush"
        case .motion: "sparkles"
        }
    }

    var keyframeSection: KeyframeSection? {
        switch self {
        case .type: .textType
        case .style: .textStyle
        case .content, .motion: nil
        }
    }
}

struct TextWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TextTimelineItem?
    let mode: TextWorkspaceMode
    @Binding var activeMotionPhase: TextAnimationPhase

    @State private var fontPickerRequest: TextFontPickerRequest?
    @State private var hasActiveEditingSession = false
    @FocusState private var isTextFocused: Bool

    var body: some View {
        let isEnabled = currentItem.map(isWorkspaceEnabled(for:)) ?? false
        EditorWorkspaceShell(
            title: mode.title,
            systemImage: mode.systemImage,
            isEnabled: isEnabled,
            emptyState: currentItem == nil
                ? EditorWorkspaceEmptyState(title: "Select a text layer", systemImage: "textformat")
                : nil,
            disablesContentWhenUnavailable: true,
            accessory: {
                if let currentItem, let section = mode.keyframeSection {
                    SectionKeyframeButton(
                        viewModel: viewModel,
                        itemID: currentItem.id,
                        section: section,
                        isEnabled: isEnabled
                    )
                }
            },
            content: {
                if let currentItem {
                    switch mode {
                    case .content:
                        contentControls(currentItem)
                    case .type:
                        typographyControls(currentItem)
                    case .style:
                        styleControls(currentItem)
                    case .motion:
                        TextAnimationControls(
                            viewModel: viewModel,
                            item: currentItem,
                            activePhase: $activeMotionPhase
                        )
                    }
                }
            }
        )
        .sheet(item: $fontPickerRequest) { request in
            TextFontPickerView(selectedFontName: request.selectedFontName) { fontName in
                update(interactive: false) { $0.style.fontName = fontName }
            }
        }
        .onChange(of: isTextFocused) { wasFocused, focused in
            if focused, !wasFocused {
                beginEditingSession()
            } else if wasFocused, !focused {
                finishEditingSession()
            }
        }
        .onChange(of: item?.id) { previousID, currentID in
            guard previousID != currentID else { return }
            dismissKeyboardAndCommit()
            focusEditorIfNeeded(itemID: currentID)
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .content {
                focusEditorIfNeeded(itemID: item?.id)
            } else {
                dismissKeyboardAndCommit()
            }
        }
        .onChange(of: currentItemIsEnabled) { _, isEnabled in
            if !isEnabled {
                dismissKeyboardAndCommit()
            }
        }
        .onDisappear {
            dismissKeyboardAndCommit()
        }
    }

    private var currentItem: TextTimelineItem? {
        guard let item,
            case .text(let current) = viewModel.project.item(id: item.id)
        else { return nil }
        return current
    }

    private var currentItemIsEnabled: Bool {
        currentItem.map(isWorkspaceEnabled(for:)) ?? false
    }

    private func contentControls(_ item: TextTimelineItem) -> some View {
        TextEditor(
            text: Binding(
                get: { currentItem?.text ?? item.text },
                set: { value in
                    update(interactive: true) {
                        $0.text = value
                        $0.name = textLayerName(for: value)
                    }
                }
            )
        )
        .font(.body)
        .focused($isTextFocused)
        .frame(minHeight: 118)
        .padding(8)
        .scrollContentBackground(.hidden)
        .background(MotionaryTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Text content")
        .accessibilityHint("Edits the selected text layer")
        .onAppear { focusEditorIfNeeded(itemID: item.id) }
    }

    private func typographyControls(_ item: TextTimelineItem) -> some View {
        VStack(spacing: 10) {
            EditorWorkspaceCard {
                Button {
                    fontPickerRequest = TextFontPickerRequest(selectedFontName: item.style.fontName)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat")
                            .foregroundStyle(MotionaryTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Font")
                                .font(.caption)
                                .foregroundStyle(MotionaryTheme.textSecondary)
                            Text(TextFontCatalog.displayName(for: item.style.fontName))
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MotionaryTheme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Font")
                .accessibilityValue(TextFontCatalog.displayName(for: item.style.fontName))
                .accessibilityHint("Opens the font picker")

                Divider().overlay(MotionaryTheme.separator)

                animatedTextScrubber(
                    "Size",
                    systemImage: "textformat.size",
                    item: item,
                    target: .textFontSize,
                    range: 8...512,
                    step: 1,
                    format: { "\(Int($0.rounded())) pt" }
                )
            }

            EditorWorkspaceCard {
                HStack {
                    Label("Alignment", systemImage: "text.alignleft")
                        .font(.callout.weight(.medium))
                    Spacer()
                }

                Picker(
                    "Alignment",
                    selection: Binding(
                        get: { item.style.alignment },
                        set: { alignment in
                            update(interactive: false) { $0.style.alignment = alignment }
                        }
                    )
                ) {
                    Label("Left", systemImage: "text.alignleft").tag(TextStyle.TextAlignment.leading)
                    Label("Center", systemImage: "text.aligncenter").tag(TextStyle.TextAlignment.center)
                    Label("Right", systemImage: "text.alignright").tag(TextStyle.TextAlignment.trailing)
                }
                .pickerStyle(.segmented)
            }

            EditorWorkspaceCard {
                animatedTextScrubber(
                    "Tracking",
                    systemImage: "character.cursor.ibeam",
                    item: item,
                    target: .textLetterSpacing,
                    range: -20...80,
                    step: 0.5,
                    format: { $0.formatted(.number.precision(.fractionLength(1))) }
                )

                animatedTextScrubber(
                    "Line spacing",
                    systemImage: "line.3.horizontal",
                    item: item,
                    target: .textLineSpacing,
                    range: -30...200,
                    step: 1,
                    format: { "\(Int($0.rounded()))" }
                )
            }
        }
    }

    private func styleControls(_ item: TextTimelineItem) -> some View {
        VStack(spacing: 10) {
            EditorWorkspaceCard {
                EditorWorkspaceColorRow(
                    title: "Fill",
                    color: (item.color(for: .fill, at: localTime(for: item)) ?? item.style.color)
                        .swiftUIColor,
                    systemImage: "paintpalette",
                    spacing: 10,
                    titleWeight: .semibold
                ) { color in
                    viewModel.setSelectedTextColor(RGBAColor(color), property: .fill)
                }
                animatedTextScrubber(
                    "Opacity",
                    systemImage: "circle.lefthalf.filled",
                    item: item,
                    target: .opacity,
                    range: 0...1,
                    step: 0.01,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )
                animatedTextScrubber(
                    "Text box",
                    systemImage: "rectangle.horizontal",
                    item: item,
                    target: .textWidthFraction,
                    range: 0.1...1,
                    step: 0.01,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )
            }

            styleSection(
                title: "Outline",
                systemImage: "scribble.variable",
                isEnabled: item.style.stroke != nil,
                onChange: { enabled in
                    update(interactive: false) { item in
                        item.style.stroke = enabled
                            ? TextStrokeStyle(
                                color: item.propertyAnimations.strokeColor.baseValue,
                                width: item.propertyAnimations.strokeWidth.baseValue
                            )
                            : nil
                    }
                }
            ) {
                if let stroke = item.style.stroke {
                    colorRow(
                        "Outline color",
                        color: item.color(for: .stroke, at: localTime(for: item)) ?? stroke.color
                    ) { color in
                        viewModel.setSelectedTextColor(color, property: .stroke)
                    }
                    animatedTextScrubber(
                        "Width",
                        systemImage: "scribble.variable",
                        item: item,
                        target: .textStrokeWidth,
                        range: 0...40,
                        step: 0.5,
                        format: { $0.formatted(.number.precision(.fractionLength(1))) }
                    )
                }
            }

            styleSection(
                title: "Shadow",
                systemImage: "shadow",
                isEnabled: item.style.shadow != nil,
                onChange: { enabled in
                    update(interactive: false) { item in
                        item.style.shadow = enabled
                            ? TextShadowStyle(
                                color: item.propertyAnimations.shadowColor.baseValue,
                                offsetX: item.propertyAnimations.shadowOffsetX.baseValue,
                                offsetY: item.propertyAnimations.shadowOffsetY.baseValue,
                                blur: item.propertyAnimations.shadowBlur.baseValue
                            )
                            : nil
                    }
                }
            ) {
                if let shadow = item.style.shadow {
                    colorRow(
                        "Shadow color",
                        color: item.color(for: .shadow, at: localTime(for: item)) ?? shadow.color
                    ) { color in
                        viewModel.setSelectedTextColor(color, property: .shadow)
                    }
                    animatedTextScrubber(
                        "Offset X",
                        systemImage: "arrow.left.and.right",
                        item: item,
                        target: .textShadowOffsetX,
                        range: -100...100,
                        step: 1,
                        format: { "\(Int($0.rounded()))" }
                    )
                    animatedTextScrubber(
                        "Offset Y",
                        systemImage: "arrow.up.and.down",
                        item: item,
                        target: .textShadowOffsetY,
                        range: -100...100,
                        step: 1,
                        format: { "\(Int($0.rounded()))" }
                    )
                    animatedTextScrubber(
                        "Blur",
                        systemImage: "drop.halffull",
                        item: item,
                        target: .textShadowBlur,
                        range: 0...100,
                        step: 1,
                        format: { "\(Int($0.rounded()))" }
                    )
                }
            }

            styleSection(
                title: "Background",
                systemImage: "rectangle.fill",
                isEnabled: item.style.background != nil,
                onChange: { enabled in
                    update(interactive: false) { item in
                        item.style.background = enabled
                            ? TextBackgroundStyle(
                                color: item.propertyAnimations.backgroundColor.baseValue,
                                padding: item.propertyAnimations.backgroundPadding.baseValue,
                                cornerRadius: item.propertyAnimations.backgroundCornerRadius.baseValue
                            )
                            : nil
                    }
                }
            ) {
                if let background = item.style.background {
                    colorRow(
                        "Background color",
                        color: item.color(for: .background, at: localTime(for: item)) ?? background.color
                    ) { color in
                        viewModel.setSelectedTextColor(color, property: .background)
                    }
                    animatedTextScrubber(
                        "Padding",
                        systemImage: "arrow.left.and.right",
                        item: item,
                        target: .textBackgroundPadding,
                        range: 0...120,
                        step: 1,
                        format: { "\(Int($0.rounded()))" }
                    )
                    animatedTextScrubber(
                        "Corners",
                        systemImage: "rectangle.roundedtop",
                        item: item,
                        target: .textBackgroundCornerRadius,
                        range: 0...120,
                        step: 1,
                        format: { "\(Int($0.rounded()))" }
                    )
                }
            }
        }
    }

    private func animatedTextScrubber(
        _ title: String,
        systemImage: String,
        item: TextTimelineItem,
        target: KeyframeTarget,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        EditorValueScrubber(
            title: title,
            systemImage: systemImage,
            value: item.value(for: target, at: localTime(for: item)) ?? 0,
            range: range,
            step: step,
            format: format,
            onBegan: viewModel.beginInteractiveEdit,
            onChanged: { value in
                viewModel.setSelectedTextKeyframeValue(
                    value,
                    target: target,
                    interactive: true
                )
            },
            onEnded: viewModel.finishTextEditing
        )
    }

    private func localTime(for item: TextTimelineItem) -> Double {
        min(max(viewModel.currentTime - item.timelineStart, 0), item.duration)
    }

    private func styleSection<Content: View>(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        onChange: @escaping (Bool) -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        EditorWorkspaceCard {
            Button {
                onChange(!isEnabled)
                EditorHaptics.tap()
            } label: {
                HStack {
                    Label(title, systemImage: systemImage)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(isEnabled ? "On" : "Off")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isEnabled ? MotionaryTheme.accent : MotionaryTheme.textSecondary)
                    Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isEnabled ? MotionaryTheme.accent : MotionaryTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) style")
            .accessibilityValue(isEnabled ? "On" : "Off")

            if isEnabled {
                Divider().overlay(MotionaryTheme.separator)
                content()
            }
        }
    }

    private func colorRow(
        _ title: String,
        color: RGBAColor,
        onChange: @escaping (RGBAColor) -> Void
    ) -> some View {
        EditorWorkspaceColorRow(title: title, color: color.swiftUIColor) {
            onChange(RGBAColor($0))
        }
    }

    private func focusEditorIfNeeded(itemID: UUID?) {
        guard mode == .content,
            let itemID,
            currentItem?.id == itemID,
            currentItemIsEnabled
        else { return }
        DispatchQueue.main.async {
            guard mode == .content,
                currentItem?.id == itemID,
                currentItemIsEnabled
            else { return }
            isTextFocused = true
        }
    }

    private func isWorkspaceEnabled(for item: TextTimelineItem) -> Bool {
        viewModel.selectedTimelineItemID == item.id
            && viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
    }

    private func beginEditingSession() {
        guard !hasActiveEditingSession else { return }
        hasActiveEditingSession = true
        viewModel.beginInteractiveEdit()
    }

    private func finishEditingSession() {
        guard hasActiveEditingSession else { return }
        hasActiveEditingSession = false
        viewModel.finishTextEditing()
    }

    private func dismissKeyboardAndCommit() {
        isTextFocused = false
        finishEditingSession()
    }

    private func update(
        interactive: Bool,
        _ change: @escaping (inout TextTimelineItem) -> Void
    ) {
        guard let item else { return }
        viewModel.updateTextItem(item.id, interactive: interactive, change)
    }

    private func textLayerName(for text: String) -> String {
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Text" }
        return String(trimmed.prefix(28))
    }
}

private struct TextFontPickerRequest: Identifiable {
    let id = UUID()
    let selectedFontName: String
}

private struct TextFontFace: Identifiable {
    let family: String
    let name: String

    var id: String { name }
    var title: String {
        UIFont(name: name, size: 17)?.fontDescriptor.object(forKey: .face) as? String
            ?? name.replacingOccurrences(of: family, with: "").trimmingCharacters(in: .punctuationCharacters)
    }
}

private enum TextFontCatalog {
    static let faces: [TextFontFace] = {
        var values = [TextFontFace(family: "System", name: ".AppleSystemUIFont")]
        values += UIFont.familyNames.sorted().flatMap { family in
            UIFont.fontNames(forFamilyName: family).sorted().map { TextFontFace(family: family, name: $0) }
        }
        return values
    }()

    static func displayName(for fontName: String) -> String {
        guard fontName != ".AppleSystemUIFont",
            let font = UIFont(name: fontName, size: 17)
        else { return "System Semibold" }
        let face = font.fontDescriptor.object(forKey: .face) as? String
        return face.map { "\(font.familyName) \($0)" } ?? font.familyName
    }
}

private struct TextFontPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    let selectedFontName: String
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List(filteredFaces) { face in
                Button {
                    onSelect(face.name)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(face.family)
                                .font(face.name == ".AppleSystemUIFont" ? .body : .custom(face.name, size: 18))
                            Text(face.title)
                                .font(.caption)
                                .foregroundStyle(MotionaryTheme.textSecondary)
                        }
                        Spacer()
                        if face.name == selectedFontName {
                            Image(systemName: "checkmark")
                                .foregroundStyle(MotionaryTheme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, prompt: "Search fonts")
            .navigationTitle("Fonts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var filteredFaces: [TextFontFace] {
        guard !query.isEmpty else { return TextFontCatalog.faces }
        return TextFontCatalog.faces.filter {
            $0.family.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
        }
    }
}
