import Foundation

// MARK: - Smooth options

/// Controls which shape kinds use their anti-aliased Kivy variants.
public struct SmoothOptions: Sendable {
    /// `Rectangle` → `SmoothRectangle` when `true` (default: `false`).
    public var rectangle: Bool
    /// `RoundedRectangle` → `SmoothRoundedRectangle` when `true` (default: `true`).
    public var roundedRectangle: Bool
    /// `Ellipse` → `SmoothEllipse` when `true` (default: `true`).
    public var ellipse: Bool
    /// `Triangle` → `SmoothTriangle` when `true` (default: `true`).
    public var triangle: Bool
    /// `Line` → `SmoothLine` when `true` (default: `true`).
    public var line: Bool

    public init(rectangle: Bool = false, roundedRectangle: Bool = true, ellipse: Bool = true, triangle: Bool = true, line: Bool = true) {
        self.rectangle        = rectangle
        self.roundedRectangle = roundedRectangle
        self.ellipse          = ellipse
        self.triangle         = triangle
        self.line             = line
    }
}

// MARK: - Shape IR

public enum CanvasShapeKind {
    case rectangle
    case roundedRectangle
    case ellipse
    case triangle
}

public struct CanvasShapeIR {
    public let kind: CanvasShapeKind
    /// Position relative to the parent frame, y-flipped to Kivy's bottom-left origin.
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    // RGBA fill (0.0 – 1.0)
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double
    /// Per-corner radii [top-left, top-right, bottom-right, bottom-left] in pixels.
    /// Non-nil only when `kind == .roundedRectangle`.
    public let cornerRadii: [Double]?
}

// MARK: - Canvas target

/// Which Kivy canvas layer the shapes belong to.
public enum CanvasTarget {
    case before   // self.canvas.before  (default)
    case after    // self.canvas.after
}

// MARK: - Text IR

/// Intermediate representation of a Figma TEXT node rendered via CoreLabel onto the canvas.
public struct CanvasTextIR {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// RGBA fill (0.0 – 1.0).
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double
    /// Raw text content.
    public let text: String
    /// Font size in integer points.
    public let fontSize: Int
    public let bold: Bool
    public let italic: Bool
    /// Kivy halign string: "left", "center", "right", "justify"
    public let halign: String
    /// Font family name (e.g. "Roboto"). Empty string means use Kivy default.
    public let fontFamily: String
}

// MARK: - Image IR

/// Intermediate representation of a Figma RECTANGLE node with an IMAGE fill.
public struct CanvasImageIR {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// The image hash from Figma (used to fetch from FIGMA_SERVER_URL/image/:hash).
    public let imageRef: String
    /// Node-level opacity * paint opacity.
    public let opacity: Double
}

// MARK: - SVG IR

/// Intermediate representation of a Figma VECTOR node as an SVG.
public struct CanvasSvgIR {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// Figma node ID — used only to derive the Python constant name (e.g. "0:123" → SVG_0_123).
    public let nodeId: String
    /// Full SVG XML string, constructed from the node's `vectorPaths` and `fills`.
    public let svgContent: String
    /// Node-level opacity.
    public let opacity: Double
}

// MARK: - Item tree (shapes + nested groups)

/// A canvas renderable: either a leaf shape, a nested InstructionGroup, a text label, an image, or an SVG vector.
public indirect enum CanvasItem {
    case shape(CanvasShapeIR)
    case group(CanvasGroupIR)
    case text(CanvasTextIR)
    case image(CanvasImageIR)
    case svg(CanvasSvgIR)
}

/// A named Kivy `InstructionGroup` emitted as its own Python class.
public struct CanvasGroupIR {
    public let className: String
    public let items: [CanvasItem]
    /// Dimensions of the top-level frame this group belongs to.
    /// Used in scalable mode to compute positional percentages.
    public let frameWidth: Int
    public let frameHeight: Int
}

/// One named canvas layer with its items.
public struct CanvasLayerIR {
    public let target: CanvasTarget
    public let items: [CanvasItem]
}

// MARK: - Frame IR

/// Intermediate representation of one Figma frame / component as a canvas-instruction widget.
public struct CanvasFrameIR {
    /// PascalCase Python class name (sanitised from the Figma layer name).
    public let className: String
    public let width: Int
    public let height: Int
    /// One entry per `<canvas.before>` / `<canvas.after>` / `<canvas>` layer found.
    public let layers: [CanvasLayerIR]

    public init(className: String, width: Int, height: Int, layers: [CanvasLayerIR]) {
        self.className = className
        self.width     = width
        self.height    = height
        self.layers    = layers
    }
}
