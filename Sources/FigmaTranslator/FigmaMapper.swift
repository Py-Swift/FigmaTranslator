import Foundation
@_exported import FigmaApi
import KvParser
import KivyWidgetRegistry

/// Maps a Figma node tree to a KvModule, then generates a .kv string.
///
/// ## Frame naming conventions
/// | Frame name              | Kivy output                        |
/// |-------------------------|------------------------------------|
/// | `BoxLayout`             | `BoxLayout:` (registry hit)        |
/// | `MyWidget`              | auto-detected (see below)          |
/// | `MyWidget:BoxLayout`    | `MyWidget:` (Python class)         |
/// | `MyWidget:<BoxLayout>`  | `<MyWidget@BoxLayout>:` kv rule    |
///
/// ## Node type mapping
/// | Figma type      | Kivy output                                        |
/// |-----------------|----------------------------------------------------|
/// | CANVAS / PAGE   | `Screen:`                                          |
/// | COMPONENT       | `<Name@Base>:` rule                                |
/// | FRAME / INSTANCE| layout auto-detected from `layoutMode`/`layoutGrids`:  |
/// |                 | horizontal → `BoxLayout` (orientation:'horizontal')    |
/// |                 | vertical   → `BoxLayout` (orientation:'vertical')      |
/// |                 | grid       → `GridLayout` (cols computed from grid)    |
/// |                 | free       → `FloatLayout`                             |
/// | GROUP           | canvas instructions bubbled up to parent           |
/// | TEXT            | `Label:`                                           |
/// | RECTANGLE/VECTOR| `Widget:` + canvas Rectangle                      |
/// | ELLIPSE         | `Widget:` + canvas Ellipse                         |
///
/// ## Coordinate system
/// Figma uses absolute canvas coordinates (top-left origin).
/// Kivy uses relative-to-parent coordinates (bottom-left origin).
///   kv_x = child.x - parent.x
///   kv_y = parent.height - (child.y - parent.y) - child.height
public enum FigmaMapper {

    // MARK: - Internal output type

    private enum NodeOutput {
        case widget(KvWidget)
        case canvasInstructions([KvCanvasInstruction])
    }

    // MARK: - Parsed frame name

    private enum ParsedName {
        /// Known Kivy widget name (registry hit) — emit inline: `BoxLayout:`
        case registryWidget(String)
        /// `Name:<Base>` — generate `<Name@Base>:` kv rule, emit `Name:` instance
        case kvClassDef(name: String, base: String)
        /// `Name:Base` — externally defined Python class, emit `Name:` directly (no rule)
        case pythonClass(String)
        /// Unknown plain name — fall back to `Widget:`
        case fallbackWidget
    }

    // MARK: - Public entry

    public static func convert(nodes: [FigmaNode]) -> String {
        let module = buildModule(from: nodes)
        return KvCodeGen.generate(from: module)
    }

    public static func convert(json: String) throws -> String {
        let data = Data(json.utf8)
        let nodes = try JSONDecoder().decode([FigmaNode].self, from: data)
        return convert(nodes: nodes)
    }

    // MARK: - Module assembly

    private static func buildModule(from nodes: [FigmaNode]) -> KvModule {
        var line = 1
        var rules: [KvRule] = []
        var rootWidgets: [KvWidget] = []

        // Components always become rules; remaining nodes become content widgets.
        var contentNodes: [FigmaNode] = []
        for node in nodes {
            if node.type == .component {
                rules.append(nodeToRule(node, extraRules: &rules, line: &line))
            } else {
                contentNodes.append(node)
            }
        }

        // When multiple content nodes are wrapped in a FloatLayout, each child
        // needs a pos relative to the collective bounding box of all root nodes.
        let floatParent: FigmaBounds? = contentNodes.count > 1
            ? unionBounds(contentNodes.compactMap(\.absoluteBoundingBox))
            : nil

        for node in contentNodes {
            switch processNode(node, parentBounds: floatParent, extraRules: &rules, line: &line) {
            case .widget(let w):
                rootWidgets.append(w)
            case .canvasInstructions(let instrs):
                // Top-level group with no parent — wrap canvas in a Widget
                let wrapper = KvWidget(
                    name: "Widget",
                    canvas: KvCanvas(instructions: instrs, line: line),
                    line: line
                )
                rootWidgets.append(wrapper)
            }
        }

        let root: KvWidget?
        switch rootWidgets.count {
        case 0:  root = nil
        case 1:  root = rootWidgets[0]
        default: root = KvWidget(name: "FloatLayout", children: rootWidgets, line: line)
        }

        return KvModule(rules: rules, root: root)
    }

    /// Returns the smallest FigmaBounds enclosing all given bounds, or nil when empty.
    private static func unionBounds(_ bounds: [FigmaBounds]) -> FigmaBounds? {
        guard !bounds.isEmpty else { return nil }
        let minX = bounds.map(\.x).min()!
        let minY = bounds.map(\.y).min()!
        let maxX = bounds.map { $0.x + $0.width }.max()!
        let maxY = bounds.map { $0.y + $0.height }.max()!
        return FigmaBounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - COMPONENT → rule

    private static func nodeToRule(
        _ node: FigmaNode,
        extraRules: inout [KvRule],
        line: inout Int
    ) -> KvRule {
        let parsed = parseName(node.name)

        // Auto-layout determines the base class (same logic as frameToWidget)
        var layoutProps: [KvProperty] = []
        let hasAutoLayout = node.layoutMode != nil && node.layoutMode != LayoutMode.none
        let autoBase: String? = hasAutoLayout
            ? autoLayoutWidget(node: node, props: &layoutProps, line: &line)
            : nil

        // Derive rule name and base
        let ruleName: String
        let base: String
        switch parsed {
        case .kvClassDef(let n, let b):
            ruleName = n
            base = autoBase ?? b          // auto-layout wins over explicit hint
        case .pythonClass(let n):
            ruleName = n
            base = autoBase ?? "Widget"
        case .registryWidget(let n):
            ruleName = n
            base = autoBase ?? n          // e.g. BoxLayout stays BoxLayout
        case .fallbackWidget:
            // Use the actual layer name rather than "FigmaWidget"
            let raw = sanitiseName(node.name)
            ruleName = raw.isEmpty ? "FigmaWidget" : raw
            base = autoBase ?? "Widget"
        }

        let sizeP = sizeProps(for: node.absoluteBoundingBox, relativeTo: nil,
                              sizingH: node.layoutSizingHorizontal,
                              sizingV: node.layoutSizingVertical,
                              line: &line)
        let children = collectWidgetChildren(
            node.children ?? [],
            parentBounds: node.absoluteBoundingBox,
            suppressPos: hasAutoLayout,
            extraRules: &extraRules,
            line: &line
        )
        line += 1
        return KvRule(
            selector: .dynamicClass(name: ruleName, bases: [base]),
            properties: sizeP + layoutProps,
            children: children,
            line: line
        )
    }

    // MARK: - Node processing

    private static func processNode(
        _ node: FigmaNode,
        parentBounds: FigmaBounds?,
        posRelative: Bool = false,
        suppressPos: Bool = false,
        extraRules: inout [KvRule],
        line: inout Int
    ) -> NodeOutput {
        line += 1
        let currentLine = line
        let posP = sizeProps(for: node.absoluteBoundingBox,
                             relativeTo: suppressPos ? nil : parentBounds,
                             sizingH: node.layoutSizingHorizontal,
                             sizingV: node.layoutSizingVertical,
                             inAutoLayout: suppressPos,
                             line: &line)

        switch node.type {

        case .canvas, .page:
            let children = collectWidgetChildren(
                node.children ?? [],
                parentBounds: node.absoluteBoundingBox,
                extraRules: &extraRules,
                line: &line
            )
            return .widget(KvWidget(
                name: "Screen",
                properties: posP,
                children: children,
                line: currentLine
            ))

        case .text:
            let textP = textProperties(node: node, line: &line)
            // Respect kv class name syntax on text nodes too.
            // "MyLabel:<Label>" → <MyLabel@Label>: rule + MyLabel: instance
            if case .kvClassDef(let name, let base) = parseName(node.name) {
                let sizeP = sizeProps(for: node.absoluteBoundingBox, relativeTo: nil, line: &line)
                line += 1
                let rule = KvRule(
                    selector: .dynamicClass(name: name, bases: [base]),
                    properties: sizeP + textP,
                    line: line
                )
                extraRules.append(rule)
                return .widget(KvWidget(name: name, properties: posP, line: currentLine))
            }
            return .widget(KvWidget(
                name: "Label",
                properties: posP + textP,
                line: currentLine
            ))

        case .rectangle, .vector, .polygon, .regularPolygon, .star, .line:
            // Standalone shape widget — canvas covers the bounding box
            // (polygon/star/line all fall back to a Rectangle proxy since
            // Kivy canvas has no direct polygon primitive)
            return .widget(KvWidget(
                name: "Widget",
                properties: posP,
                canvas: fillCanvas(node: node, line: &line, shape: "Rectangle"),
                line: currentLine
            ))

        case .ellipse:
            return .widget(KvWidget(
                name: "Widget",
                properties: posP,
                canvas: fillCanvas(node: node, line: &line, shape: "Ellipse"),
                line: currentLine
            ))

        case .group:
            return .canvasInstructions(groupToCanvasInstructions(node, parentBounds: parentBounds, posRelative: posRelative, line: &line))

        case .component:
            // Always generate a rule (nodeToRule now handles auto-layout for the base class)
            let rule = nodeToRule(node, extraRules: &extraRules, line: &line)
            extraRules.append(rule)
            return .widget(KvWidget(
                name: rule.selector.primaryName,
                properties: posP,
                line: currentLine
            ))

        default:
            // FRAME, INSTANCE, and anything else → apply naming convention
            return frameToWidget(
                node: node,
                posProps: posP,
                extraRules: &extraRules,
                currentLine: currentLine,
                line: &line
            )
        }
    }

    // MARK: - FRAME naming convention
    //
    // Two independent concerns:
    //   • Widget TYPE  → always from Figma's auto-layout when present; name-based otherwise.
    //   • Class NAME   → from the layer name colon-syntax (Name:Base or Name:<Base>).
    //
    // Naming cheat-sheet (colon syntax now only controls the Python class name):
    //   "BoxLayout"         (registry)  → BoxLayout:  (no auto-layout props unless present)
    //   "Frame 1"           (unknown)   → auto-detected from layoutMode / layoutWrap
    //   "MyList"            (unknown)   → same auto-detection
    //   "MyList:Widget"     (py class)  → MyList:  (external, children nested, no layout inference)
    //   "MyList:<Widget>"   (kv rule)   → <MyList@AutoBase>: rule, where AutoBase comes from
    //                                     auto-layout (or Widget if none)

    private static func frameToWidget(
        node: FigmaNode,
        posProps: [KvProperty],
        extraRules: inout [KvRule],
        currentLine: Int,
        line: inout Int
    ) -> NodeOutput {
        let parsed = parseName(node.name)

        // RelativeLayout coordinate space is already local — canvas pos needs no self.x/y offset.
        let isRelativeLayout: Bool
        switch parsed {
        case .kvClassDef(_, let base): isRelativeLayout = base == "RelativeLayout"
        case .registryWidget(let n):   isRelativeLayout = n == "RelativeLayout"
        default:                        isRelativeLayout = false
        }

        let (childWidgets, childCanvas) = collectChildren(
            node.children ?? [],
            parentBounds: node.absoluteBoundingBox,
            posRelative: isRelativeLayout,
            suppressPos: false,
            extraRules: &extraRules,
            line: &line
        )

        // When all children are canvas-only → put canvas directly on parent, children = [].
        // When mixed → wrap canvas in a child Widget, parent canvas = nil.
        func finalChildren() -> [KvWidget] {
            guard !childWidgets.isEmpty else { return [] }
            guard !childCanvas.isEmpty else { return childWidgets }
            var all = childWidgets
            line += 1
            all.append(KvWidget(
                name: "Widget",
                canvas: KvCanvas(instructions: childCanvas, line: line),
                line: line
            ))
            return all
        }

        func directCanvas() -> KvCanvas? {
            guard childWidgets.isEmpty && !childCanvas.isEmpty else { return nil }
            return KvCanvas(instructions: childCanvas, line: currentLine)
        }

        // ── .pythonClass: external Python class — never infer layout, just emit name ──
        if case .pythonClass(let name) = parsed {
            return .widget(KvWidget(
                name: name,
                properties: posProps,
                children: finalChildren(),
                line: currentLine
            ))
        }

        // ── Auto-layout present → it dictates the widget type ──────────────────────────
        let hasAutoLayout = node.layoutMode != nil && node.layoutMode != LayoutMode.none
        if hasAutoLayout {
            var layoutProps = posProps
            let autoBase = autoLayoutWidget(node: node, props: &layoutProps, line: &line)

            // Re-collect children with pos suppressed now that we know this is auto-layout
            let (alWidgets, alCanvas) = collectChildren(
                node.children ?? [],
                parentBounds: node.absoluteBoundingBox,
                posRelative: isRelativeLayout,
                suppressPos: true,
                extraRules: &extraRules,
                line: &line
            )
            func alFinalChildren() -> [KvWidget] {
                guard !alWidgets.isEmpty else { return [] }
                guard !alCanvas.isEmpty else { return alWidgets }
                var all = alWidgets
                line += 1
                all.append(KvWidget(name: "Widget", canvas: KvCanvas(instructions: alCanvas, line: line), line: line))
                return all
            }
            func alDirectCanvas() -> KvCanvas? {
                guard alWidgets.isEmpty && !alCanvas.isEmpty else { return nil }
                return KvCanvas(instructions: alCanvas, line: currentLine)
            }

            if case .kvClassDef(let name, _) = parsed {
                let sizeP = sizeProps(for: node.absoluteBoundingBox, relativeTo: nil, line: &line)
                line += 1
                let rule = KvRule(
                    selector: .dynamicClass(name: name, bases: [autoBase]),
                    properties: sizeP,
                    children: alFinalChildren(),
                    canvas: alDirectCanvas(),
                    line: line
                )
                extraRules.append(rule)
                return .widget(KvWidget(name: name, properties: layoutProps, line: currentLine))
            }

            return .widget(KvWidget(
                name: autoBase,
                properties: layoutProps,
                children: alFinalChildren(),
                canvas: alDirectCanvas(),
                line: currentLine
            ))
        }

        // ── No auto-layout → fall back to name-based detection ──────────────────────────
        switch parsed {

        case .registryWidget(let wName):
            return .widget(KvWidget(
                name: wName,
                properties: posProps,
                children: finalChildren(),
                canvas: directCanvas(),
                line: currentLine
            ))

        case .kvClassDef(let name, let base):
            let sizeP = sizeProps(for: node.absoluteBoundingBox, relativeTo: nil, line: &line)
            line += 1
            let rule = KvRule(
                selector: .dynamicClass(name: name, bases: [base]),
                properties: sizeP,
                children: finalChildren(),
                canvas: directCanvas(),
                line: line
            )
            extraRules.append(rule)
            return .widget(KvWidget(name: name, properties: posProps, line: currentLine))

        default:
            // Unknown plain name — collapse canvas-only into parent, mixed into child Widget.
            if let cv = directCanvas() {
                return .widget(KvWidget(
                    name: "Widget",
                    properties: posProps,
                    canvas: cv,
                    line: currentLine
                ))
            }
            return .widget(KvWidget(
                name: "Widget",
                properties: posProps,
                children: finalChildren(),
                line: currentLine
            ))
        }
    }

    // MARK: - Auto layout → widget name

    /// Derives the Kivy layout widget name from Figma's auto-layout / grid settings.
    /// Also appends any layout-specific properties (e.g. `orientation`) to `props`.
    private static func autoLayoutWidget(
        node: FigmaNode,
        props: inout [KvProperty],
        line: inout Int
    ) -> String {
        switch node.layoutMode {
        case .some(.grid):
            let cols = node.gridColumnCount ?? 2
            line += 1; props.append(prop("cols", "\(cols)", line: line))
            if let rows = node.gridRowCount {
                line += 1; props.append(prop("rows", "\(rows)", line: line))
            }
            appendSpacingAndPadding(
                hGap: node.gridColumnGap, vGap: node.gridRowGap,
                paddingLeft: node.paddingLeft, paddingTop: node.paddingTop,
                paddingRight: node.paddingRight, paddingBottom: node.paddingBottom,
                props: &props, line: &line
            )
            return "GridLayout"

        case .some(.horizontal):
            line += 1; props.append(prop("orientation", "'horizontal'", line: line))
            appendSpacingAndPadding(
                hGap: node.itemSpacing, vGap: nil,
                paddingLeft: node.paddingLeft, paddingTop: node.paddingTop,
                paddingRight: node.paddingRight, paddingBottom: node.paddingBottom,
                props: &props, line: &line
            )
            return "BoxLayout"

        case .some(.vertical):
            line += 1; props.append(prop("orientation", "'vertical'", line: line))
            appendSpacingAndPadding(
                hGap: nil, vGap: node.itemSpacing,
                paddingLeft: node.paddingLeft, paddingTop: node.paddingTop,
                paddingRight: node.paddingRight, paddingBottom: node.paddingBottom,
                props: &props, line: &line
            )
            return "BoxLayout"

        default:
            return "Widget"
        }
    }

    /// Appends `spacing` and `padding` properties when non-zero.
    /// `hGap`/`vGap` are used as column/row spacing respectively.
    private static func appendSpacingAndPadding(
        hGap: Double?, vGap: Double?,
        paddingLeft: Double?, paddingTop: Double?,
        paddingRight: Double?, paddingBottom: Double?,
        props: inout [KvProperty],
        line: inout Int
    ) {
        // spacing
        let h = hGap ?? 0, v = vGap ?? 0
        if h > 0 || v > 0 {
            let spacingVal = (h == v) ? "\(Int(h))" : "[\(Int(h)), \(Int(v))]"
            line += 1; props.append(prop("spacing", spacingVal, line: line))
        }
        // padding — emit only if any side is non-zero
        let pl = paddingLeft ?? 0, pt = paddingTop ?? 0
        let pr = paddingRight ?? 0, pb = paddingBottom ?? 0
        if pl > 0 || pt > 0 || pr > 0 || pb > 0 {
            let padVal: String
            if pl == pt && pt == pr && pr == pb {
                padVal = "\(Int(pl))"
            } else if pl == pr && pt == pb {
                padVal = "[\(Int(pl)), \(Int(pt))]"
            } else {
                padVal = "[\(Int(pl)), \(Int(pt)), \(Int(pr)), \(Int(pb))]"
            }
            line += 1; props.append(prop("padding", padVal, line: line))
        }
    }

    // MARK: - GROUP → canvas instructions

    private static func groupToCanvasInstructions(
        _ node: FigmaNode,
        parentBounds: FigmaBounds?,
        posRelative: Bool = false,
        line: inout Int
    ) -> [KvCanvasInstruction] {
        var instrs: [KvCanvasInstruction] = []
        for child in node.children ?? [] {
            switch child.type {
            case .rectangle, .vector, .polygon, .regularPolygon, .star, .line:
                if let canvas = fillCanvas(node: child, line: &line, shape: "Rectangle", parentBounds: parentBounds, posRelative: posRelative) {
                    instrs.append(contentsOf: canvas.instructions)
                }
            case .ellipse:
                if let canvas = fillCanvas(node: child, line: &line, shape: "Ellipse", parentBounds: parentBounds, posRelative: posRelative) {
                    instrs.append(contentsOf: canvas.instructions)
                }
            case .group:
                instrs.append(contentsOf: groupToCanvasInstructions(child, parentBounds: parentBounds, posRelative: posRelative, line: &line))
            default:
                break
            }
        }
        return instrs
    }

    // MARK: - Name parser

    /// Parses a raw Figma layer name into a `ParsedName` case.
    ///
    /// - `"MyWidget:<BoxLayout>"` → `.kvClassDef(name:"MyWidget", base:"BoxLayout")`
    /// - `"MyWidget:BoxLayout"`   → `.pythonClass("MyWidget")`
    /// - `"BoxLayout"` (registry) → `.registryWidget("BoxLayout")`
    /// - `"SomeUnknown"`          → `.fallbackWidget`
    private static func parseName(_ raw: String) -> ParsedName {
        // Check for "Name:<Base>" — kv class rule
        if let kvRange = raw.range(of: ":<") {
            let namePart = sanitiseName(String(raw[raw.startIndex..<kvRange.lowerBound]))
            let baseRaw = raw[kvRange.upperBound...]
            let basePart = sanitiseName(String(baseRaw.hasSuffix(">") ? baseRaw.dropLast() : baseRaw))
            if !namePart.isEmpty && !basePart.isEmpty {
                return .kvClassDef(name: namePart, base: basePart)
            }
        }

        // Check for "Name:Base" (no angle brackets) — Python class
        if let colonIdx = raw.firstIndex(of: ":") {
            let namePart = sanitiseName(String(raw[raw.startIndex..<colonIdx]))
            if !namePart.isEmpty {
                return .pythonClass(namePart)
            }
        }

        // Plain name — check registry
        let clean = sanitiseName(raw)
        if KivyWidgetRegistry.widgetExists(clean) {
            return .registryWidget(clean)
        }

        return .fallbackWidget
    }

    private static func ruleNameAndBases(
        for parsed: ParsedName,
        defaultBase: String
    ) -> (String, [String]) {
        switch parsed {
        case .kvClassDef(let n, let b): return (n, [b])
        case .pythonClass(let n):       return (n, [defaultBase])
        case .registryWidget(let n):    return (n, [defaultBase])
        case .fallbackWidget:           return ("FigmaWidget", [defaultBase])
        }
    }

    // MARK: - Child collection

    /// Converts child nodes, separating widget output from canvas instructions.
    /// If ALL children produce only canvas instructions, returns nil (caller collapses into parent canvas).
    private static func collectWidgetChildren(
        _ children: [FigmaNode],
        parentBounds: FigmaBounds?,
        suppressPos: Bool = false,
        extraRules: inout [KvRule],
        line: inout Int
    ) -> [KvWidget] {
        var widgets: [KvWidget] = []
        var pendingInstrs: [KvCanvasInstruction] = []

        for child in children {
            switch processNode(child, parentBounds: parentBounds,
                               suppressPos: suppressPos,
                               extraRules: &extraRules, line: &line) {
            case .widget(let w):
                widgets.append(w)
            case .canvasInstructions(let instrs):
                pendingInstrs.append(contentsOf: instrs)
            }
        }

        // Only wrap in a child Widget if there are also real widget siblings.
        // If it's canvas-only, caller will attach to parent's canvas directly.
        if !pendingInstrs.isEmpty {
            line += 1
            widgets.append(KvWidget(
                name: "Widget",
                canvas: KvCanvas(instructions: pendingInstrs, line: line),
                line: line
            ))
        }

        return widgets
    }

    /// Like collectWidgetChildren but returns canvas instructions when all children are shapes/groups.
    /// Returns (widgets, canvasInstructions) — caller merges canvas into parent when widgets is empty.
    private static func collectChildren(
        _ children: [FigmaNode],
        parentBounds: FigmaBounds?,
        posRelative: Bool = false,
        suppressPos: Bool = false,
        extraRules: inout [KvRule],
        line: inout Int
    ) -> (widgets: [KvWidget], canvas: [KvCanvasInstruction]) {
        var widgets: [KvWidget] = []
        var instrs: [KvCanvasInstruction] = []

        for child in children {
            switch processNode(child, parentBounds: parentBounds,
                               posRelative: posRelative,
                               suppressPos: suppressPos,
                               extraRules: &extraRules, line: &line) {
            case .widget(let w):
                widgets.append(w)
            case .canvasInstructions(let i):
                instrs.append(contentsOf: i)
            }
        }
        return (widgets, instrs)
    }

    // MARK: - Property helpers

    /// size_hint + size + pos properties from Figma bounds.
    /// `sizingH`/`sizingV` are Figma's layoutSizingHorizontal/Vertical:
    ///   - nil / "FIXED" / "HUG" → size_hint_# = None + explicit dimension
    ///   - "FILL"                → axis fills parent, omit size_hint_# and explicit dimension
    private static func sizeProps(
        for bounds: FigmaBounds?,
        relativeTo parent: FigmaBounds?,
        sizingH: LayoutSizing? = nil,
        sizingV: LayoutSizing? = nil,
        inAutoLayout: Bool = false,
        line: inout Int
    ) -> [KvProperty] {
        guard let b = bounds else { return [] }
        var props: [KvProperty] = []
        line += 1

        let fillH = sizingH == .fill
        let fillV = sizingV == .fill

        if fillH && fillV {
            // Both axes fill — leave size_hint at default (1, 1), no explicit size
        } else if fillH {
            // Only vertical is fixed
            props.append(prop("size_hint_y", "None", line: line))
            line += 1
            props.append(prop("height", "\(Int(b.height.rounded()))", line: line))
        } else if fillV {
            // Only horizontal is fixed
            props.append(prop("size_hint_x", "None", line: line))
            line += 1
            props.append(prop("width", "\(Int(b.width.rounded()))", line: line))
        } else if !inAutoLayout {
            // Both axes fixed — disable stretching, emit explicit size
            // Skipped for auto-layout children: the layout manages sizing
            props.append(prop("size_hint", "None, None", line: line))
            let w = Int(b.width.rounded())
            let h = Int(b.height.rounded())
            line += 1
            props.append(prop("size", "\(w), \(h)", line: line))
        }

        if let p = parent {
            let relX = Int((b.x - p.x).rounded())
            // Flip y: Figma top-left → Kivy bottom-left
            let relY = Int((p.height - (b.y - p.y) - b.height).rounded())
            line += 1
            props.append(prop("pos", "\(relX), \(relY)", line: line))
        }

        return props
    }

    /// Label-specific: text, font_size, bold, italic, font_name, halign, valign, color
    private static func textProperties(node: FigmaNode, line: inout Int) -> [KvProperty] {
        var props: [KvProperty] = []
        let text = (node.characters ?? "").replacingOccurrences(of: "'", with: "\\'")
        line += 1
        props.append(prop("text", "'\(text)'", line: line))

        if let fs = node.fontSize {
            line += 1
            props.append(prop("font_size", "'\(Int(fs.rounded()))sp'", line: line))
        }

        // fontName.family → font_name
        // fontName.style → bold / italic  (e.g. "Bold", "Bold Italic", "Italic")
        if let fontName = node.fontName {
            if !fontName.family.isEmpty {
                line += 1
                props.append(prop("font_name", "'\(fontName.family)'", line: line))
            }
            let styleLC = fontName.style.lowercased()
            if styleLC.contains("bold") {
                line += 1
                props.append(prop("bold", "True", line: line))
            }
            if styleLC.contains("italic") {
                line += 1
                props.append(prop("italic", "True", line: line))
            }
        }

        if let halign = node.textAlignHorizontal {
            let kvHalign: String?
            switch halign {
            case "LEFT":      kvHalign = "'left'"
            case "RIGHT":     kvHalign = "'right'"
            case "CENTER":    kvHalign = "'center'"
            case "JUSTIFIED": kvHalign = "'justify'"
            default:          kvHalign = nil
            }
            if let v = kvHalign {
                line += 1
                props.append(prop("halign", v, line: line))
            }
        }

        if let valign = node.textAlignVertical {
            let kvValign: String?
            switch valign {
            case "TOP":    kvValign = "'top'"
            case "CENTER": kvValign = "'middle'"
            case "BOTTOM": kvValign = "'bottom'"
            default:       kvValign = nil
            }
            if let v = kvValign {
                line += 1
                props.append(prop("valign", v, line: line))
            }
        }

        if let color = solidColor(from: node.fills) {
            line += 1
            props.append(prop("color", rgbaString(color), line: line))
        }

        return props
    }

    /// Canvas with Color + Rectangle or Ellipse for filled shapes
    private static func fillCanvas(
        node: FigmaNode,
        line: inout Int,
        shape: String,
        parentBounds: FigmaBounds? = nil,
        posRelative: Bool = false
    ) -> KvCanvas? {
        guard let color = solidColor(from: node.fills) else { return nil }
        line += 1
        let colorInstr = KvCanvasInstruction(
            instructionType: "Color",
            properties: [prop("rgba", rgbaString(color), line: line)],
            line: line
        )
        line += 1
        let posVal: String
        let sizeVal: String
        if let b = node.absoluteBoundingBox, let p = parentBounds {
            let relX = Int((b.x - p.x).rounded())
            let relY = Int((p.height - (b.y - p.y) - b.height).rounded())
            let w = Int(b.width.rounded())
            let h = Int(b.height.rounded())
            // RelativeLayout: coordinates are already local, no self.x/y offset needed
            posVal  = posRelative ? "\(relX), \(relY)" : "self.x + \(relX), self.y + \(relY)"
            sizeVal = "\(w), \(h)"
        } else {
            posVal  = "self.pos"
            sizeVal = "self.size"
        }
        let shapeInstr = KvCanvasInstruction(
            instructionType: shape,
            properties: [
                prop("pos", posVal, line: line),
                prop("size", sizeVal, line: line + 1),
            ],
            line: line
        )
        line += 1
        return KvCanvas(instructions: [colorInstr, shapeInstr], line: line)
    }

    // MARK: - Utilities

    private static func prop(_ name: String, _ value: String, line: Int) -> KvProperty {
        KvProperty(name: name, value: value, line: line)
    }

    private static func solidColor(from fills: [FigmaPaint]?) -> FigmaColor? {
        fills?.first(where: { $0.type == .solid })?.color
    }

    private static func rgbaString(_ c: FigmaColor) -> String {
        String(format: "%.3f, %.3f, %.3f, %.3f", c.r, c.g, c.b, c.alpha)
    }

    /// Sanitise a Figma layer name into a valid Kivy class identifier:
    /// strip spaces and special chars, capitalise words.
    private static func sanitiseName(_ name: String) -> String {
        let words = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let camel = words
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
        return camel.isEmpty ? "FigmaWidget" : camel
    }
}
