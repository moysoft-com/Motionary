// Shared text layout and rasterization for editor preview and export.

import CoreImage
import Foundation
import UIKit

struct TextLayerGeometry: Equatable {
    let layerSize: CGSize
    let textRect: CGRect
    let backgroundRect: CGRect?
}

struct TextLayerRenderResult {
    let image: CIImage
    let geometry: TextLayerGeometry
}

/// Produces the exact same text pixels for the editor player and final export.
/// Canvas overlays can use `geometry` and `resolvedFont` to mirror its layout.
final class TextLayerRenderer {
    private final class CachedLayer: NSObject {
        let result: TextLayerRenderResult

        init(result: TextLayerRenderResult) {
            self.result = result
        }
    }

    private struct RasterCacheKey: Encodable {
        let text: String
        let style: TextStyle
        let layout: TextLayout
        let renderWidth: Double
        let renderHeight: Double
        let renderScale: Double
        let rasterScaleX: Double
        let rasterScaleY: Double
        let visibleUTF16Length: Int
    }

    private struct PreparedLayer {
        let attributedText: NSMutableAttributedString
        let geometry: TextLayerGeometry
    }

    private let cache: NSCache<NSString, CachedLayer> = {
        let cache = NSCache<NSString, CachedLayer>()
        cache.countLimit = 64
        cache.totalCostLimit = GeneratedRasterPolicy.textCacheBytes
        return cache
    }()

    func removeAllObjects() {
        cache.removeAllObjects()
    }

    func render(
        item: TextTimelineItem,
        renderSize: CGSize,
        renderScale: CGFloat,
        rasterScaleMultiplier: CGFloat = 1,
        rasterScale requestedRasterScale: CGSize? = nil,
        at localTime: Double? = nil,
        glyphReveal: Double = 1
    ) -> TextLayerRenderResult {
        let item = localTime.map { item.resolved(at: $0) } ?? item
        let visibleUTF16Length = Self.visibleUTF16Length(
            in: item.text,
            progress: glyphReveal
        )
        let prepared = Self.prepare(
            item: item,
            renderSize: renderSize,
            renderScale: renderScale,
            visibleUTF16Length: visibleUTF16Length
        )
        let requestedRasterScale = requestedRasterScale
            ?? CGSize(width: rasterScaleMultiplier, height: rasterScaleMultiplier)
        let rasterScale = GeneratedRasterPolicy.boundedRasterScale(
            requestedRasterScale,
            logicalSize: prepared.geometry.layerSize
        )
        let key = cacheKey(
            item: item,
            renderSize: renderSize,
            renderScale: renderScale,
            rasterScale: rasterScale,
            visibleUTF16Length: visibleUTF16Length
        )
        if let cached = cache.object(forKey: key) {
            return cached.result
        }

        let rasterLayerSize = CGSize(
            width: max(ceil(prepared.geometry.layerSize.width * rasterScale.width), 1),
            height: max(ceil(prepared.geometry.layerSize.height * rasterScale.height), 1)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let raster = UIGraphicsImageRenderer(
            size: rasterLayerSize,
            format: format
        ).image { context in
            context.cgContext.scaleBy(x: rasterScale.width, y: rasterScale.height)
            if let background = item.style.background,
                let backgroundRect = prepared.geometry.backgroundRect
            {
                Self.uiColor(background.color).setFill()
                UIBezierPath(
                    roundedRect: backgroundRect,
                    cornerRadius: min(
                        CGFloat(background.cornerRadius) * max(renderScale, 0),
                        min(backgroundRect.width, backgroundRect.height) * 0.5
                    )
                ).fill()
            }
            if item.style.stroke?.width ?? 0 > 0 {
                prepared.attributedText.draw(
                    with: prepared.geometry.textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                let fillText = NSMutableAttributedString(attributedString: prepared.attributedText)
                let fullRange = NSRange(location: 0, length: fillText.length)
                fillText.removeAttribute(.strokeColor, range: fullRange)
                fillText.removeAttribute(.strokeWidth, range: fullRange)
                fillText.removeAttribute(.shadow, range: fullRange)
                fillText.draw(
                    with: prepared.geometry.textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            } else {
                prepared.attributedText.draw(
                    with: prepared.geometry.textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            }
        }
        let image = raster.cgImage.map(CIImage.init(cgImage:)) ?? CIImage.empty()
        let result = TextLayerRenderResult(image: image, geometry: prepared.geometry)
        cache.setObject(
            CachedLayer(result: result),
            forKey: key,
            cost: max(
                Int(rasterLayerSize.width * rasterLayerSize.height * 4),
                1
            )
        )
        return result
    }

    static func geometry(
        for item: TextTimelineItem,
        renderSize: CGSize,
        renderScale: CGFloat,
        at localTime: Double? = nil
    ) -> TextLayerGeometry {
        let item = localTime.map { item.resolved(at: $0) } ?? item
        return prepare(
            item: item,
            renderSize: renderSize,
            renderScale: renderScale,
            visibleUTF16Length: item.text.utf16.count
        ).geometry
    }

    static func resolvedFont(for style: TextStyle, renderScale: CGFloat) -> UIFont {
        let fontSize = max(CGFloat(style.fontSize) * max(renderScale, 0), 1)
        if style.fontName == ".AppleSystemUIFont" || style.fontName.isEmpty {
            return UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        }
        return UIFont(name: style.fontName, size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize, weight: .semibold)
    }

    private func cacheKey(
        item: TextTimelineItem,
        renderSize: CGSize,
        renderScale: CGFloat,
        rasterScale: CGSize,
        visibleUTF16Length: Int
    ) -> NSString {
        let value = RasterCacheKey(
            text: item.text,
            style: item.style,
            layout: item.layout,
            renderWidth: renderSize.width,
            renderHeight: renderSize.height,
            renderScale: renderScale,
            rasterScaleX: rasterScale.width,
            rasterScaleY: rasterScale.height,
            visibleUTF16Length: visibleUTF16Length
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(value)) ?? Data()
        return encoded.base64EncodedString() as NSString
    }

    private static func prepare(
        item: TextTimelineItem,
        renderSize: CGSize,
        renderScale: CGFloat,
        visibleUTF16Length: Int
    ) -> PreparedLayer {
        let scale = max(renderScale, 0)
        let font = resolvedFont(for: item.style, renderScale: scale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = CGFloat(item.style.lineSpacing) * scale
        switch item.style.alignment {
        case .leading:
            paragraph.alignment = .left
        case .center:
            paragraph.alignment = .center
        case .trailing:
            paragraph.alignment = .right
        }

        let textColor = uiColor(item.style.color)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
            .kern: CGFloat(item.style.letterSpacing) * scale
        ]
        if let stroke = item.style.stroke, stroke.width > 0 {
            let scaledStrokeWidth = CGFloat(stroke.width) * scale
            attributes[.strokeColor] = uiColor(stroke.color)
            attributes[.strokeWidth] = (scaledStrokeWidth * 2 / max(font.pointSize, 1)) * 100
        }
        if let shadow = item.style.shadow {
            let textShadow = NSShadow()
            textShadow.shadowColor = uiColor(shadow.color)
            textShadow.shadowOffset = CGSize(
                width: CGFloat(shadow.offsetX) * scale,
                height: CGFloat(shadow.offsetY) * scale
            )
            textShadow.shadowBlurRadius = CGFloat(shadow.blur) * scale
            attributes[.shadow] = textShadow
        }

        let attributedText = NSMutableAttributedString(
            string: item.text,
            attributes: attributes
        )
        let backgroundPadding = CGFloat(item.style.background?.padding ?? 0) * scale
        let strokeInset = CGFloat(item.style.stroke?.width ?? 0) * scale
        let contentInset = backgroundPadding + strokeInset
        let shadowInset: CGFloat
        if let shadow = item.style.shadow {
            shadowInset = (
                CGFloat(shadow.blur) * 2
                    + max(abs(CGFloat(shadow.offsetX)), abs(CGFloat(shadow.offsetY)))
            ) * scale
        } else {
            shadowInset = 0
        }
        let maximumBoxWidth = max(
            renderSize.width * CGFloat(item.layout.widthFraction),
            1
        )
        let maximumTextWidth = max(maximumBoxWidth - contentInset * 2, 1)
        let measured = attributedText.boundingRect(
            with: CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textWidth = min(max(ceil(measured.width), 1), maximumTextWidth)
        let contentBoxWidth = max(textWidth + contentInset * 2, 1)
        let boxWidth = item.style.background == nil
            ? contentBoxWidth
            : maximumBoxWidth
        let explicitLineCount = max(
            item.text.split(separator: "\n", omittingEmptySubsequences: false).count,
            1
        )
        let explicitLineHeight = font.lineHeight * CGFloat(explicitLineCount)
            + paragraph.lineSpacing * CGFloat(max(explicitLineCount - 1, 0))
        let textHeight = max(ceil(measured.height), ceil(explicitLineHeight), 1)
        let boxHeight = max(textHeight + contentInset * 2, 1)
        let layerSize = CGSize(
            width: max(ceil(boxWidth + shadowInset * 2), 1),
            height: max(ceil(boxHeight + shadowInset * 2), 1)
        )
        let textRect = CGRect(
            x: shadowInset + contentInset,
            y: shadowInset + contentInset,
            width: textWidth,
            height: textHeight
        )
        let geometry = TextLayerGeometry(
            layerSize: layerSize,
            textRect: textRect,
            backgroundRect: item.style.background == nil
                ? nil
                : CGRect(
                    x: shadowInset,
                    y: shadowInset,
                    width: boxWidth,
                    height: boxHeight
                )
        )

        let fullLength = attributedText.length
        let visibleLength = min(max(visibleUTF16Length, 0), fullLength)
        if visibleLength < fullLength {
            let hiddenRange = NSRange(
                location: visibleLength,
                length: fullLength - visibleLength
            )
            attributedText.addAttribute(
                .foregroundColor,
                value: UIColor.clear,
                range: hiddenRange
            )
            if item.style.stroke != nil {
                attributedText.addAttribute(
                    .strokeColor,
                    value: UIColor.clear,
                    range: hiddenRange
                )
            }
            if item.style.shadow != nil {
                let hiddenShadow = NSShadow()
                hiddenShadow.shadowColor = UIColor.clear
                attributedText.addAttribute(
                    .shadow,
                    value: hiddenShadow,
                    range: hiddenRange
                )
            }
        }
        return PreparedLayer(attributedText: attributedText, geometry: geometry)
    }

    private static func visibleUTF16Length(in text: String, progress: Double) -> Int {
        let clamped = min(max(progress, 0), 1)
        guard clamped < 1 else { return text.utf16.count }
        guard clamped > 0 else { return 0 }
        let visibleCharacterCount = Int(
            floor(Double(text.count) * clamped + 0.000_001)
        )
        let endIndex = text.index(
            text.startIndex,
            offsetBy: min(max(visibleCharacterCount, 0), text.count)
        )
        return text[..<endIndex].utf16.count
    }

    private static func uiColor(_ color: RGBAColor) -> UIColor {
        UIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }
}
