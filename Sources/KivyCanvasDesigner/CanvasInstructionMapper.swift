import Foundation
import FigmaApi

// MARK: - Mapper

enum CanvasInstructionMapper {

    // MARK: - Public entry

    /// Maps a flat list of Figma nodes to canvas-instruction frame IRs.
    /// Each top-level FRAME, COMPONENT, or INSTANCE becomes one `CanvasFrameIR`.
    /// A top-level CANVAS/PAGE node is unwrapped one level so its children are processed.
    static func map(nodes: [FigmaNode]) -> [CanvasFrameIR] {
        var result: [CanvasFrameIR] = []
        for node in nodes {
            switch node.type {
            case .canvas, .page:
                for child in node.children ?? [] {
                    if let ir = frameToIR(child) { result.append(ir) }
                }
            default:
                if let ir = frameToIR(node) { result.append(ir) }
            }
        }
        return result
    }

    // MARK: - Frame → IR

    private static func frameToIR(_ node: FigmaNode) -> CanvasFrameIR? {
        // Accept frames/components/instances as normal containers.
        // Also accept groups if they are themselves named as a canvas layer
        // (i.e. the user locked/sent <canvas> directly).
        let selfIsCanvasLayer = canvasTarget(for: node.name) != nil
        switch node.type {
        case .frame, .component, .instance:
            break
        case .group where selfIsCanvasLayer:
            break
        default:
            return nil
        }

        let className = sanitiseName(node.name)
        let b = node.absoluteBoundingBox
        let w = Int((b?.width ?? 0).rounded())
        let h = Int((b?.height ?? 0).rounded())
        let layers = canvasLayersFor(node, parentBounds: b)
        return CanvasFrameIR(className: className, width: w, height: h, layers: layers)
    }

    // MARK: - Canvas layer detection

    /// Parses a Figma layer name into a `CanvasTarget` if it is a canvas sentinel name.
    /// Recognised names (case-insensitive):
    ///   `<canvas>`          → .before  (default)
    ///   `<canvas.before>`   → .before
    ///   `<canvas.after>`    → .after
    ///   `</canvas>`         → .after
    ///   `<canvas.main>`     → .main
    private static func canvasTarget(for name: String) -> CanvasTarget? {
        switch name.lowercased() {
        case "<canvas>", "<canvas.before>":
            return .before
        case "<canvas.after>", "</canvas>":
            return .after
        case "<canvas.main>":
            return .main
        default:
            return nil
        }
    }

    /// Derives the canvas layers for a frame node.
    ///
    /// The `<canvas>`, `<canvas.before>`, and `<canvas.after>` group labels are the
    /// **authoritative** boundary: only content inside those groups becomes canvas
    /// instructions.  Everything else in the frame is treated as a plain widget child.
    ///
    /// - If the node itself is a canvas-layer sentinel → single layer from its children.
    /// - If any direct children are canvas-layer sentinels → one layer per named child.
    /// - No sentinel found → returns an empty array (no canvas for this frame).
    private static func canvasLayersFor(
        _ node: FigmaNode,
        parentBounds: FigmaBounds?
    ) -> [CanvasLayerIR] {
        // Case 1: the node itself is a canvas sentinel (user locked/sent it directly).
        if let target = canvasTarget(for: node.name) {
            let items = collectItems(node.children ?? [], parentBounds: parentBounds)
            return [CanvasLayerIR(target: target, items: items)]
        }

        // Case 2: look for named canvas children — only items inside those groups count.
        // The <canvas>/<canvas.before>/<canvas.after> labels are required; no sentinel = no canvas.
        let namedLayers: [CanvasLayerIR] = (node.children ?? []).compactMap { child in
            guard let target = canvasTarget(for: child.name) else { return nil }
            let items = collectItems(child.children ?? [], parentBounds: parentBounds)
            return CanvasLayerIR(target: target, items: items)
        }
        return namedLayers
    }

    // MARK: - Item collection (recursive)

    private static func collectItems(
        _ children: [FigmaNode],
        parentBounds: FigmaBounds?
    ) -> [CanvasItem] {
        var items: [CanvasItem] = []
        for child in children {
            guard child.isVisible else { continue }
            // Any node type can carry an IMAGE fill — check first before type-specific handling.
            if let ir = imageToIR(child, parentBounds: parentBounds) {
                items.append(.image(ir))
                continue
            }
            switch child.type {
            case .rectangle, .vector:
                // VECTOR nodes with vectorPaths are exported as SVG; fall back to solid-fill rectangle.
                if child.type == .vector, let ir = svgToIR(child, parentBounds: parentBounds) {
                    items.append(.svg(ir))
                } else {
                    let radii = cornerRadii(for: child)
                    let kind: CanvasShapeKind = radii != nil ? .roundedRectangle : .rectangle
                    if let ir = shapeToIR(child, kind: kind, cornerRadii: radii, parentBounds: parentBounds) {
                        items.append(.shape(ir))
                    }
                }
            case .ellipse:
                if let ir = shapeToIR(child, kind: .ellipse, cornerRadii: nil, parentBounds: parentBounds) {
                    items.append(.shape(ir))
                }
            case .polygon, .regularPolygon:
                if let ir = shapeToIR(child, kind: .triangle, cornerRadii: nil, parentBounds: parentBounds) {
                    items.append(.shape(ir))
                }
            case .text:
                if let ir = textToIR(child, parentBounds: parentBounds) {
                    items.append(.text(ir))
                }
            case .group:
                if canvasTarget(for: child.name) != nil {
                    // Canvas sentinel: inline its children rather than creating a group.
                    items.append(contentsOf: collectItems(child.children ?? [], parentBounds: parentBounds))
                } else {
                    // Named Figma GROUP → InstructionGroup subclass.
                    let groupItems = collectItems(child.children ?? [], parentBounds: parentBounds)
                    if !groupItems.isEmpty {
                        items.append(.group(CanvasGroupIR(
                            className: sanitiseName(child.name),
                            items: groupItems,
                            frameWidth:  Int((parentBounds?.width  ?? 0).rounded()),
                            frameHeight: Int((parentBounds?.height ?? 0).rounded())
                        )))
                    }
                }
            case .frame, .instance, .component:
                // Per spec: any frame/component inside a <canvas> group is a new class container.
                // Treat the same as a named group — emit an InstructionGroup subclass.
                let containerItems = collectItems(child.children ?? [], parentBounds: parentBounds)
                if !containerItems.isEmpty {
                    items.append(.group(CanvasGroupIR(
                        className: sanitiseName(child.name),
                        items: containerItems,
                        frameWidth:  Int((parentBounds?.width  ?? 0).rounded()),
                        frameHeight: Int((parentBounds?.height ?? 0).rounded())
                    )))
                }
            default:
                break
            }
        }
        return items
    }

    // MARK: - Single SVG → IR

    private static func svgToIR(_ node: FigmaNode, parentBounds: FigmaBounds?) -> CanvasSvgIR? {
        guard let paths = node.vectorPaths, !paths.isEmpty,
              let b = node.absoluteBoundingBox else { return nil }

        let w = Int(b.width.rounded())
        let h = Int(b.height.rounded())

        // Derive fill colour: solid fill → solid stroke fallback → black default.
        // VECTOR nodes often have no fill (styled via stroke or inherited colour);
        // using black ensures the shape is always visible in the preview.
        func rgbaStr(_ color: FigmaColor, _ paintOpacity: Double) -> String {
            let r  = Int((color.r * 255).rounded())
            let g  = Int((color.g * 255).rounded())
            let bv = Int((color.b * 255).rounded())
            let a  = String(format: "%.3f", color.alpha * paintOpacity * node.effectiveOpacity)
            return "rgba(\(r),\(g),\(bv),\(a))"
        }
        let fillStr: String
        var strokeStr = "none"
        var strokeWidth = 0.0
        if let (color, paintOpacity) = solidColorAndOpacity(from: node.fills) {
            fillStr = rgbaStr(color, paintOpacity)
        } else if let (color, paintOpacity) = solidColorAndOpacity(from: node.strokes) {
            // No fill but has a stroke — render as a filled shape using the stroke colour.
            fillStr = rgbaStr(color, paintOpacity)
        } else {
            // No colour info at all — fall back to black so the shape is visible.
            fillStr = "#000000"
        }
        // Also include stroke if both fill and stroke paints are present.
        if fillStr != "none", let (sColor, sOpacity) = solidColorAndOpacity(from: node.strokes) {
            strokeStr = rgbaStr(sColor, sOpacity)
            strokeWidth = node.strokeWeight ?? 1.0
        }

        // Build <path> elements. vectorPaths from the Plugin API are already in node-local
        // coordinate space, so no translate transform is needed.
        var pathXml = ""
        for vp in paths {
            let rule = (vp.windingRule == "EVENODD") ? "evenodd" : "nonzero"
            var attrs = "fill=\"\(fillStr)\" fill-rule=\"\(rule)\""
            if strokeStr != "none" { attrs += " stroke=\"\(strokeStr)\" stroke-width=\"\(strokeWidth)\"" }
            pathXml += "<path \(attrs) d=\"\(vp.data)\"/>"
        }
        let svgContent = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">\(pathXml)</svg>"

        let x: Int
        let y: Int
        if let p = parentBounds {
            x = Int((b.x - p.x).rounded())
            y = Int((p.height - (b.y - p.y) - b.height).rounded())
        } else {
            x = Int(b.x.rounded())
            y = Int(b.y.rounded())
        }
        return CanvasSvgIR(
            x: x, y: y,
            width: w,
            height: h,
            nodeId: node.id ?? node.name,
            svgContent: svgContent,
            opacity: node.effectiveOpacity
        )
    }

    // MARK: - Single shape → IR

    private static func shapeToIR(
        _ node: FigmaNode,
        kind: CanvasShapeKind,
        cornerRadii: [Double]?,
        parentBounds: FigmaBounds?
    ) -> CanvasShapeIR? {
        guard let (color, paintOpacity) = solidColorAndOpacity(from: node.fills) else { return nil }
        // Polygons: absoluteBoundingBox covers the full square tile; absoluteRenderBounds
        // tightly wraps the actual shape, giving correct position and height.
        let b: FigmaBounds
        if kind == .triangle, let rb = node.absoluteRenderBounds {
            b = rb
        } else if let bb = node.absoluteBoundingBox {
            b = bb
        } else {
            return nil
        }
        let nodeOpacity = node.effectiveOpacity

        let x: Int
        let y: Int
        if let p = parentBounds {
            x = Int((b.x - p.x).rounded())
            // y-flip: Figma top-left origin → Kivy bottom-left origin
            y = Int((p.height - (b.y - p.y) - b.height).rounded())
        } else {
            x = Int(b.x.rounded())
            y = Int(b.y.rounded())
        }
        let w = Int(b.width.rounded())
        let h = Int(b.height.rounded())

        let finalAlpha = color.alpha * paintOpacity * nodeOpacity
        return CanvasShapeIR(
            kind: kind,
            x: x, y: y, width: w, height: h,
            r: color.r, g: color.g, b: color.b, a: finalAlpha,
            cornerRadii: cornerRadii
        )
    }

    // MARK: - Single text → IR

    private static func textToIR(_ node: FigmaNode, parentBounds: FigmaBounds?) -> CanvasTextIR? {
        guard let text = node.characters, !text.isEmpty else { return nil }
        // absoluteRenderBounds tightly wraps the actual rendered glyphs; fall back to
        // absoluteBoundingBox if renderBounds is absent.
        guard let b = node.absoluteRenderBounds ?? node.absoluteBoundingBox else { return nil }

        let x: Int
        let y: Int
        if let p = parentBounds {
            x = Int((b.x - p.x).rounded())
            y = Int((p.height - (b.y - p.y) - b.height).rounded())
        } else {
            x = Int(b.x.rounded())
            y = Int(b.y.rounded())
        }
        let w = Int(b.width.rounded())
        let h = Int(b.height.rounded())

        // Font size: prefer Plugin API direct field, fall back to style, default 14
        let rawSize = node.fontSize ?? node.style?.fontSize ?? 14
        let fontSize = max(1, Int(rawSize.rounded()))

        // Bold / italic from fontName.style string (Plugin API) or FigmaTypeStyle
        let styleStr = (node.fontName?.style ?? node.style?.fontStyle ?? "").lowercased()
        let bold   = styleStr.contains("bold")
        let italic = styleStr.contains("italic") || styleStr.contains("oblique")

        // Font family
        let fontFamily = node.fontName?.family ?? node.style?.fontFamily ?? ""

        // Halign mapping from Figma → Kivy
        let halignRaw = node.textAlignHorizontal ?? node.style?.textAlignHorizontal ?? "LEFT"
        let halign: String
        switch halignRaw.uppercased() {
        case "CENTER":    halign = "center"
        case "RIGHT":     halign = "right"
        case "JUSTIFIED": halign = "justify"
        default:          halign = "left"
        }

        // Color from fills; default opaque white
        let nodeOpacity = node.effectiveOpacity
        let r, g, b2, a: Double
        if let (color, paintOpacity) = solidColorAndOpacity(from: node.fills) {
            r  = color.r
            g  = color.g
            b2 = color.b
            a  = color.alpha * paintOpacity * nodeOpacity
        } else {
            r = 1; g = 1; b2 = 1; a = nodeOpacity
        }

        return CanvasTextIR(
            x: x, y: y, width: w, height: h,
            r: r, g: g, b: b2, a: a,
            text: text,
            fontSize: fontSize,
            bold: bold,
            italic: italic,
            halign: halign,
            fontFamily: fontFamily
        )
    }

    /// Returns per-corner radii [tl, tr, br, bl] if the node has any non-zero corner,
    /// otherwise `nil`.
    private static func cornerRadii(for node: FigmaNode) -> [Double]? {
        let radii: [Double]
        if let perCorner = node.rectangleCornerRadii, perCorner.count == 4 {
            radii = perCorner
        } else if let uniform = node.cornerRadius, uniform > 0 {
            radii = [uniform, uniform, uniform, uniform]
        } else {
            return nil
        }
        return radii.contains(where: { $0 > 0 }) ? radii : nil
    }

    // MARK: - Helpers

    private static func solidColorAndOpacity(from fills: [FigmaPaint]?) -> (FigmaColor, Double)? {
        guard let paint = fills?.first(where: { $0.type == .solid && $0.visible != false }),
              let color = paint.color else { return nil }
        return (color, paint.effectiveOpacity)
    }

    private static func imageRefAndOpacity(from fills: [FigmaPaint]?) -> (String, Double)? {
        guard let paint = fills?.first(where: { $0.type == .image && $0.visible != false }),
              let ref = paint.imageRef else { return nil }
        return (ref, paint.effectiveOpacity)
    }

    // MARK: - Single image → IR

    private static func imageToIR(_ node: FigmaNode, parentBounds: FigmaBounds?) -> CanvasImageIR? {
        guard let (ref, paintOpacity) = imageRefAndOpacity(from: node.fills),
              let b = node.absoluteBoundingBox else { return nil }
        let nodeOpacity = node.effectiveOpacity
        let x: Int
        let y: Int
        if let p = parentBounds {
            x = Int((b.x - p.x).rounded())
            y = Int((p.height - (b.y - p.y) - b.height).rounded())
        } else {
            x = Int(b.x.rounded())
            y = Int(b.y.rounded())
        }
        return CanvasImageIR(
            x: x, y: y,
            width:  Int(b.width.rounded()),
            height: Int(b.height.rounded()),
            imageRef: ref,
            opacity: paintOpacity * nodeOpacity
        )
    }

    static func sanitiseName(_ name: String) -> String {
        let words = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let camel = words
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
        return camel.isEmpty ? "FigmaWidget" : camel
    }
}

