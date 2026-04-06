import Foundation
import FigmaApi
import KivyCanvasDesigner

/// Generates Kivy widget-tree Python source from Figma node trees.
///
/// Each top-level FRAME or COMPONENT becomes a `Widget` / `BoxLayout` / `GridLayout` subclass
/// whose `__init__` instantiates children and (optionally) populates `self.canvas.before/after`
/// with graphics instructions from `<canvas>` / `<canvas.before>` / `<canvas.after>` sentinels.
public enum WidgetDesigner {

    /// Convert a flat list of FigmaNodes to Python source code.
    public static func generate(
        nodes: [FigmaNode],
        scalable: Bool = false,
        smooth: SmoothOptions = .init()
    ) -> String {
        let frames = WidgetInstructionMapper.map(nodes: nodes)
        return WidgetCodeGen.generate(frames: frames, scalable: scalable, smooth: smooth)
    }

    /// Parse JSON, then generate Python source code.
    public static func generate(
        json: String,
        scalable: Bool = false,
        smooth: SmoothOptions = .init()
    ) throws -> String {
        let nodes = try JSONDecoder().decode([FigmaNode].self, from: Data(json.utf8))
        return generate(nodes: nodes, scalable: scalable, smooth: smooth)
    }
}
