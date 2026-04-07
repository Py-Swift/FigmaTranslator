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
        var usedNames: [String: Int] = [:]
        for node in nodes {
            switch node.type {
            case .canvas, .page:
                for child in node.children ?? [] {
                    if let ir = frameToIR(child, usedNames: &usedNames) { result.append(ir) }
                }
            default:
                if let ir = frameToIR(node, usedNames: &usedNames) { result.append(ir) }
            }
        }
        return result
    }

    // MARK: - Frame → IR

    private static func frameToIR(_ node: FigmaNode, usedNames: inout [String: Int]) -> CanvasFrameIR? {
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
        let layers = canvasLayersFor(node, parentBounds: b, usedNames: &usedNames)
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
        parentBounds: FigmaBounds?,
        usedNames: inout [String: Int]
    ) -> [CanvasLayerIR] {
        // Case 1: the node itself is a canvas sentinel (user locked/sent it directly).
        if let target = canvasTarget(for: node.name) {
            let items = collectItems(node.children ?? [], parentBounds: parentBounds, usedNames: &usedNames)
            return [CanvasLayerIR(target: target, items: items)]
        }

        // Case 2: look for named canvas children — only items inside those groups count.
        // The <canvas>/<canvas.before>/<canvas.after> labels are required; no sentinel = no canvas.
        var namedLayers: [CanvasLayerIR] = []
        for child in node.children ?? [] {
            guard let target = canvasTarget(for: child.name) else { continue }
            let items = collectItems(child.children ?? [], parentBounds: parentBounds, usedNames: &usedNames)
            namedLayers.append(CanvasLayerIR(target: target, items: items))
        }
        return namedLayers
    }

    // MARK: - Item collection (recursive)

    private static func collectItems(
        _ children: [FigmaNode],
        parentBounds: FigmaBounds?,
        usedNames: inout [String: Int]
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
                if child.type == .vector {
                    if let ir = nativeVectorShapeToIR(child, parentBounds: parentBounds) {
                        items.append(.shape(ir))
                        continue
                    }
                    if let ir = svgToIR(child, parentBounds: parentBounds) {
                        items.append(.svg(ir))
                        continue
                    }
                    // No geometry data available (JSON_REST_V1 omits fillGeometry) — skip.
                    continue
                }
                let radii = cornerRadii(for: child)
                let kind: CanvasShapeKind = radii != nil ? .roundedRectangle : .rectangle
                if let ir = shapeToIR(child, kind: kind, cornerRadii: radii, parentBounds: parentBounds) {
                    items.append(.shape(ir))
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
                    items.append(contentsOf: collectItems(child.children ?? [], parentBounds: parentBounds, usedNames: &usedNames))
                } else {
                    // Named Figma GROUP → InstructionGroup subclass.
                    let baseName = sanitiseName(child.name)
                    let count = usedNames[baseName, default: 0]
                    usedNames[baseName] = count + 1
                    let className = count == 0 ? baseName : "\(baseName)_\(count + 1)"
                    let groupItems = collectItems(child.children ?? [], parentBounds: parentBounds, usedNames: &usedNames)
                    if !groupItems.isEmpty {
                        items.append(.group(CanvasGroupIR(
                            className: className,
                            items: groupItems,
                            frameWidth:  Int((parentBounds?.width  ?? 0).rounded()),
                            frameHeight: Int((parentBounds?.height ?? 0).rounded())
                        )))
                    }
                }
            case .frame, .instance, .component:
                // Per spec: any frame/component inside a <canvas> group is a new class container.
                // Treat the same as a named group — emit an InstructionGroup subclass.
                let baseName = sanitiseName(child.name)
                let count = usedNames[baseName, default: 0]
                usedNames[baseName] = count + 1
                let className = count == 0 ? baseName : "\(baseName)_\(count + 1)"
                let containerItems = collectItems(child.children ?? [], parentBounds: parentBounds, usedNames: &usedNames)
                if !containerItems.isEmpty {
                    items.append(.group(CanvasGroupIR(
                        className: className,
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
        guard let paths = node.fillGeometry, !paths.isEmpty,
              let b = node.absoluteBoundingBox else { return nil }

        let w = Int(b.width.rounded())
        let h = Int(b.height.rounded())

        // Derive node-level fill colour for fallback.
        func rgbaStr(_ color: FigmaColor, _ paintOpacity: Double) -> String {
            let r  = Int((color.r * 255).rounded())
            let g  = Int((color.g * 255).rounded())
            let bv = Int((color.b * 255).rounded())
            let a  = String(format: "%.3f", color.alpha * paintOpacity * node.effectiveOpacity)
            return "rgba(\(r),\(g),\(bv),\(a))"
        }
        let nodeFillStr: String
        var strokeStr = "none"
        var strokeWidth = 0.0
        if let (color, paintOpacity) = solidColorAndOpacity(from: node.fills) {
            nodeFillStr = rgbaStr(color, paintOpacity)
        } else if let (color, paintOpacity) = solidColorAndOpacity(from: node.strokes) {
            nodeFillStr = rgbaStr(color, paintOpacity)
        } else {
            nodeFillStr = "#000000"
        }
        if let (sColor, sOpacity) = solidColorAndOpacity(from: node.strokes) {
            strokeStr = rgbaStr(sColor, sOpacity)
            strokeWidth = node.strokeWeight ?? 1.0
        }

        // Build <path> elements using REST fillGeometry paths.
        var pathXml = ""
        for vp in paths {
            let rule = (vp.windingRule == "EVENODD") ? "evenodd" : "nonzero"
            var attrs = "fill=\"\(nodeFillStr)\" fill-rule=\"\(rule)\""
            if strokeStr != "none" { attrs += " stroke=\"\(strokeStr)\" stroke-width=\"\(strokeWidth)\"" }
            pathXml += "<path \(attrs) d=\"\(vp.path)\"/>"
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

    private static func nativeVectorShapeToIR(_ node: FigmaNode, parentBounds: FigmaBounds?) -> CanvasShapeIR? {
        guard node.type == .vector,
              !hasVisibleStroke(node),
              let path = node.fillGeometry?.first,
              node.fillGeometry?.count == 1,
              let bounds = node.absoluteBoundingBox else { return nil }

        if isAxisAlignedRectanglePath(path.path, width: bounds.width, height: bounds.height) {
            let radii = cornerRadii(for: node)
            let kind: CanvasShapeKind = radii != nil ? .roundedRectangle : .rectangle
            return shapeToIR(node, kind: kind, cornerRadii: radii, parentBounds: parentBounds)
        }

        if isSimpleEllipsePath(path.path, width: bounds.width, height: bounds.height) {
            return shapeToIR(node, kind: .ellipse, cornerRadii: nil, parentBounds: parentBounds)
        }

        return nil
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

        // Font size from style, default 14
        let rawSize = node.style?.fontSize ?? 14
        let fontSize = max(1, Int(rawSize.rounded()))

        // Bold / italic from FigmaTypeStyle
        let styleStr = (node.style?.fontStyle ?? "").lowercased()
        let bold   = styleStr.contains("bold") || node.style?.italic == true
        let italic = styleStr.contains("italic") || styleStr.contains("oblique") || node.style?.italic == true

        // Font family
        let fontFamily = node.style?.fontFamily ?? ""

        // Halign mapping from Figma → Kivy
        let halignRaw = node.style?.textAlignHorizontal ?? "LEFT"
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

    private static func hasVisibleStroke(_ node: FigmaNode) -> Bool {
        guard (node.strokeWeight ?? 0) > 0 else { return false }
        return node.strokes?.contains(where: { $0.visible != false }) ?? false
    }

    private static func isAxisAlignedRectanglePath(_ data: String, width: Double, height: Double) -> Bool {
        let commands = svgPathCommands(data)
        guard !commands.isEmpty else { return false }

        var points: [(Double, Double)] = []
        for command in commands {
            switch command.name {
            case "M", "L":
                guard command.values.count == 2 else { return false }
                points.append((command.values[0], command.values[1]))
            case "Z":
                guard command.values.isEmpty else { return false }
            default:
                return false
            }
        }

        guard points.count >= 4 else { return false }
        if let first = points.first, let last = points.last, approxEqual(first.0, last.0, tolerance: rectangleTolerance(width: width, height: height)), approxEqual(first.1, last.1, tolerance: rectangleTolerance(width: width, height: height)) {
            points.removeLast()
        }
        guard points.count == 4 else { return false }

        let tolerance = rectangleTolerance(width: width, height: height)
        let corners = [(0.0, 0.0), (width, 0.0), (width, height), (0.0, height)]
        var matched = Array(repeating: false, count: corners.count)

        for point in points {
            guard let cornerIndex = corners.indices.first(where: { !matched[$0] && pointMatches(point, corners[$0], tolerance: tolerance) }) else {
                return false
            }
            matched[cornerIndex] = true
        }

        for index in points.indices {
            let next = points[(index + 1) % points.count]
            let current = points[index]
            let sameX = approxEqual(current.0, next.0, tolerance: tolerance)
            let sameY = approxEqual(current.1, next.1, tolerance: tolerance)
            if sameX == sameY { return false }
        }
        return true
    }

    private static func isSimpleEllipsePath(_ data: String, width: Double, height: Double) -> Bool {
        let commands = svgPathCommands(data)
        guard commands.count == 6,
              commands.first?.name == "M",
              commands.dropFirst().dropLast().allSatisfy({ $0.name == "C" && $0.values.count == 6 }),
              commands.last?.name == "Z" else { return false }

        let tolerance = rectangleTolerance(width: width, height: height)
        var endpoints: [(Double, Double)] = []

        if let move = commands.first?.values, move.count == 2 {
            endpoints.append((move[0], move[1]))
        } else {
            return false
        }

        for command in commands.dropFirst().dropLast() {
            endpoints.append((command.values[4], command.values[5]))
        }

        if let first = endpoints.first, let last = endpoints.last, pointMatches(first, last, tolerance: tolerance) {
            endpoints.removeLast()
        }

        guard endpoints.count == 4 else { return false }

        let cardinalPoints = [
            (0.0, height / 2),
            (width / 2, 0.0),
            (width, height / 2),
            (width / 2, height)
        ]
        var matched = Array(repeating: false, count: cardinalPoints.count)

        for point in endpoints {
            guard let pointIndex = cardinalPoints.indices.first(where: { !matched[$0] && pointMatches(point, cardinalPoints[$0], tolerance: tolerance) }) else {
                return false
            }
            matched[pointIndex] = true
        }
        return true
    }

    private static func svgPathCommands(_ data: String) -> [(name: String, values: [Double])] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?"#) else {
            return []
        }

        let nsData = data as NSString
        let rawTokens = regex.matches(in: data, range: NSRange(location: 0, length: nsData.length)).map {
            nsData.substring(with: $0.range)
        }

        var commands: [(name: String, values: [Double])] = []
        var index = 0
        while index < rawTokens.count {
            let token = rawTokens[index]
            guard token.count == 1, let scalar = token.unicodeScalars.first, CharacterSet.letters.contains(scalar) else {
                return []
            }

            let name = token.uppercased()
            guard let arity = svgCommandArity(name) else { return [] }
            index += 1

            if arity == 0 {
                commands.append((name, []))
                continue
            }

            var values: [Double] = []
            while index < rawTokens.count {
                let next = rawTokens[index]
                if next.count == 1, let scalar = next.unicodeScalars.first, CharacterSet.letters.contains(scalar) {
                    break
                }
                guard let value = Double(next) else { return [] }
                values.append(value)
                index += 1
            }

            guard values.count == arity else { return [] }
            commands.append((name, values))
        }

        return commands
    }

    private static func svgCommandArity(_ name: String) -> Int? {
        switch name {
        case "M", "L": return 2
        case "C": return 6
        case "Z": return 0
        default: return nil
        }
    }

    private static func rectangleTolerance(width: Double, height: Double) -> Double {
        max(0.5, max(width, height) * 0.002)
    }

    private static func pointMatches(_ lhs: (Double, Double), _ rhs: (Double, Double), tolerance: Double) -> Bool {
        approxEqual(lhs.0, rhs.0, tolerance: tolerance) && approxEqual(lhs.1, rhs.1, tolerance: tolerance)
    }

    private static func approxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Bool {
        abs(lhs - rhs) <= tolerance
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

