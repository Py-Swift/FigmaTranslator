import Foundation
import FigmaApi

/// Generates Kivy canvas-instruction Python widgets from Figma node trees.
///
/// Each top-level FRAME or COMPONENT in the input becomes a `Widget` subclass
/// whose `__init__` populates `self.canvas.before` with Color + Rectangle/Ellipse
/// instructions — one class per shape-only frame, no per-shape Widget objects.
public enum CanvasDesigner {

    /// Convert a flat list of FigmaNodes to Python source code.
    public static func generate(nodes: [FigmaNode], scalable: Bool = false, smooth: SmoothOptions = .init()) -> String {
        let frames = CanvasInstructionMapper.map(nodes: nodes)
        return CanvasCodeGen.generate(frames: frames, scalable: scalable, smooth: smooth)
    }

    /// Generate Python source code from pre-mapped canvas frames.
    public static func generate(frames: [CanvasFrameIR], scalable: Bool = false, smooth: SmoothOptions = .init()) -> String {
        CanvasCodeGen.generate(frames: frames, scalable: scalable, smooth: smooth)
    }

    /// Parse JSON, then generate Python source code.
    public static func generate(json: String, scalable: Bool = false, smooth: SmoothOptions = .init()) throws -> String {
        let data = Data(json.utf8)
        let nodes = try JSONDecoder().decode([FigmaNode].self, from: data)
        return generate(nodes: nodes, scalable: scalable, smooth: smooth)
    }

    /// Map nodes to canvas IR without generating code — for use by `KivyWidgetDesigner`.
    public static func mapToIR(nodes: [FigmaNode]) -> [CanvasFrameIR] {
        CanvasInstructionMapper.map(nodes: nodes)
    }

    /// Returns all SVG IRs (nodeId + built SVG XML) found across a set of mapped frames.
    /// Route handlers call this to pre-populate the server's SVG store before generating code.
    public static func extractSvgs(frames: [CanvasFrameIR]) -> [(nodeId: String, svgContent: String)] {
        CanvasCodeGen.extractSvgs(frames: frames)
    }
}
