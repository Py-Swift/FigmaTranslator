import Foundation
import KivyCanvasDesigner

// MARK: - Widget IR data types

/// The Kivy layout class a WidgetNode maps to.
public enum WidgetKind: Sendable {
    /// `Widget` — free/absolute positioning (no auto-layout).
    case widget
    /// `BoxLayout(orientation: 'horizontal' | 'vertical')`.
    case boxLayout(orientation: String, spacing: Double, padding: [Double])
    /// `GridLayout(cols: N)`.
    case gridLayout(cols: Int, rowSpacing: Double, colSpacing: Double)
    /// Inline `Label(text: ..., font_size: N)` — never emitted as a standalone class.
    case label(text: String, fontSize: Int)
}

/// A single node in the widget tree IR.
public struct WidgetNode: Sendable {
    /// Sanitised Python class name (used when this node is emitted as a class).
    public let className: String
    public let kind: WidgetKind
    /// Recursive widget children (labels are included here).
    public let children: [WidgetNode]
    /// Canvas instruction layers extracted from `<canvas>` / `<canvas.before>` / `<canvas.after>` sentinel groups.
    public let canvasLayers: [CanvasLayerIR]
    public let frameWidth: Int
    public let frameHeight: Int

    public init(
        className: String,
        kind: WidgetKind,
        children: [WidgetNode] = [],
        canvasLayers: [CanvasLayerIR] = [],
        frameWidth: Int = 0,
        frameHeight: Int = 0
    ) {
        self.className    = className
        self.kind         = kind
        self.children     = children
        self.canvasLayers = canvasLayers
        self.frameWidth   = frameWidth
        self.frameHeight  = frameHeight
    }
}

/// Top-level IR produced by `WidgetInstructionMapper` — one per Figma frame/component.
public struct WidgetFrameIR: Sendable {
    public let className: String
    public let width: Int
    public let height: Int
    public let root: WidgetNode

    public init(className: String, width: Int, height: Int, root: WidgetNode) {
        self.className = className
        self.width     = width
        self.height    = height
        self.root      = root
    }
}
