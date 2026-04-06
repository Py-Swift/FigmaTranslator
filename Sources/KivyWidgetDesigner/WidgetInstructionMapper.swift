import Foundation
import FigmaApi
import KivyCanvasDesigner

// MARK: - Mapper

enum WidgetInstructionMapper {

    // MARK: - Public entry

    /// Maps a flat list of Figma nodes to widget-tree frame IRs.
    /// Each top-level FRAME, COMPONENT, or INSTANCE becomes one `WidgetFrameIR`.
    /// A CANVAS/PAGE node is unwrapped one level so its children are processed.
    static func map(nodes: [FigmaNode]) -> [WidgetFrameIR] {
        var result: [WidgetFrameIR] = []
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

    private static func frameToIR(_ node: FigmaNode) -> WidgetFrameIR? {
        switch node.type {
        case .frame, .component, .instance: break
        default: return nil
        }
        let b = node.absoluteBoundingBox
        let w = Int((b?.width  ?? 0).rounded())
        let h = Int((b?.height ?? 0).rounded())
        let root = nodeToWidgetNode(node, parentBounds: b)
        return WidgetFrameIR(className: sanitise(node.name), width: w, height: h, root: root)
    }

    // MARK: - Node → WidgetNode (recursive)

    private static func nodeToWidgetNode(_ node: FigmaNode, parentBounds: FigmaBounds?) -> WidgetNode {
        let b = node.absoluteBoundingBox
        let w = Int((b?.width  ?? 0).rounded())
        let h = Int((b?.height ?? 0).rounded())

        // Extract canvas layers via CanvasDesigner — only sentinel-scoped content comes back.
        let canvasFrames = CanvasDesigner.mapToIR(nodes: [node])
        let canvasLayers = canvasFrames.first?.layers ?? []

        // Non-sentinel children form the widget tree children.
        let rawChildren = (node.children ?? []).filter { $0.isVisible && !isCanvasSentinel($0.name) }

        let children: [WidgetNode] = rawChildren.compactMap { child in
            switch child.type {
            case .text:
                let text      = child.characters ?? ""
                let fontSize  = Int((child.style?.fontSize ?? 14).rounded())
                return WidgetNode(
                    className: sanitise(child.name),
                    kind: .label(text: text, fontSize: fontSize)
                )
            case .frame, .component, .instance:
                return nodeToWidgetNode(child, parentBounds: b)
            case .group where !isCanvasSentinel(child.name):
                return nodeToWidgetNode(child, parentBounds: b)
            default:
                return nil
            }
        }

        return WidgetNode(
            className: sanitise(node.name),
            kind: layoutKind(for: node),
            children: children,
            canvasLayers: canvasLayers,
            frameWidth: w,
            frameHeight: h
        )
    }

    // MARK: - Layout kind

    private static func layoutKind(for node: FigmaNode) -> WidgetKind {
        switch node.layoutMode {
        case .some(.grid):
            return .gridLayout(
                cols: node.gridColumnCount ?? 2,
                rowSpacing: node.gridRowGap ?? 0,
                colSpacing: node.gridColumnGap ?? 0
            )
        case .some(.horizontal):
            return .boxLayout(
                orientation: "horizontal",
                spacing: node.itemSpacing ?? 0,
                padding: paddingArray(node)
            )
        case .some(.vertical):
            return .boxLayout(
                orientation: "vertical",
                spacing: node.itemSpacing ?? 0,
                padding: paddingArray(node)
            )
        default:
            return .widget
        }
    }

    private static func paddingArray(_ node: FigmaNode) -> [Double] {
        let l = node.paddingLeft   ?? 0
        let t = node.paddingTop    ?? 0
        let r = node.paddingRight  ?? 0
        let b = node.paddingBottom ?? 0
        guard l != 0 || t != 0 || r != 0 || b != 0 else { return [] }
        return [l, t, r, b]
    }

    // MARK: - Canvas sentinel detection

    static func isCanvasSentinel(_ name: String) -> Bool {
        switch name.lowercased() {
        case "<canvas>", "<canvas.before>", "<canvas.after>", "</canvas>", "<canvas.main>":
            return true
        default:
            return false
        }
    }

    // MARK: - Name sanitisation

    static func sanitise(_ name: String) -> String {
        let base = name.isEmpty ? "Widget" : name
        var chars: [Character] = []
        for scalar in base.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39)
            chars.append(ok ? Character(scalar) : "_")
        }
        var ident = String(chars)
        // Collapse consecutive underscores, strip leading/trailing
        while ident.contains("__") { ident = ident.replacingOccurrences(of: "__", with: "_") }
        ident = ident.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if ident.isEmpty { ident = "Widget" }
        if ident.first?.isNumber ?? false { ident = "_" + ident }
        // Capitalise first letter for PascalCase class names
        return ident.prefix(1).uppercased() + ident.dropFirst()
    }
}
