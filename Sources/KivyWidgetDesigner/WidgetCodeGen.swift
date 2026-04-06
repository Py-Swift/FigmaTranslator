import PySwiftAST
import PySwiftCodeGen
import KivyCanvasDesigner

// MARK: - Widget Code Generator

enum WidgetCodeGen {

    // MARK: - Public entry

    /// Generates a Python source string from widget-tree frame IRs.
    /// Each frame becomes a Widget/BoxLayout/GridLayout subclass whose `__init__`
    /// instantiates children and optionally embeds canvas instruction blocks.
    static func generate(
        frames: [WidgetFrameIR],
        scalable: Bool = false,
        smooth: SmoothOptions = .init()
    ) -> String {
        guard !frames.isEmpty else { return "" }

        // Collect all unique WidgetNodes that need class definitions in post-order (leafs first).
        var orderedNodes: [WidgetNode] = []
        var seenNames: Swift.Set<String> = []

        func collectPostOrder(_ node: WidgetNode) {
            if case .label = node.kind { return }  // labels are inline, not classes
            for child in node.children { collectPostOrder(child) }
            if seenNames.insert(node.className).inserted {
                orderedNodes.append(node)
            }
        }
        for frame in frames { collectPostOrder(frame.root) }

        // Determine which imports are needed across all nodes.
        var needsWidget      = false
        var needsBoxLayout   = false
        var needsGridLayout  = false
        var needsLabel       = false
        var graphicsNameSet: [String] = []
        var fontFamilies:    [String] = []
        var imageRefs:       [String] = []
        var needsCoreLabel   = false

        func scanNode(_ node: WidgetNode) {
            if case .label = node.kind { needsLabel = true; return }
            switch node.kind {
            case .boxLayout:  needsBoxLayout  = true
            case .gridLayout: needsGridLayout = true
            default:          needsWidget     = true
            }
            if !node.canvasLayers.isEmpty {
                let tempIR = CanvasFrameIR(
                    className: node.className,
                    width:     node.frameWidth,
                    height:    node.frameHeight,
                    layers:    node.canvasLayers
                )
                let embed = CanvasCodeGen.canvasEmbedData(for: tempIR, scalable: scalable, smooth: smooth)
                for name in embed.graphicsNames where !graphicsNameSet.contains(name) {
                    graphicsNameSet.append(name)
                }
                for ff in embed.fontFamilies where !fontFamilies.contains(ff) { fontFamilies.append(ff) }
                for ir in embed.imageRefs    where !imageRefs.contains(ir)    { imageRefs.append(ir) }
                if embed.needsCoreLabel { needsCoreLabel = true }
            }
            for child in node.children { scanNode(child) }
        }
        for frame in frames { scanNode(frame.root) }

        // Build module body: imports → registrations → classes → preview.
        var body: [Statement] = []

        // Kivy uix imports
        if needsWidget    { body.append(importFrom("kivy.uix.widget",      ["Widget"])) }
        if needsBoxLayout { body.append(importFrom("kivy.uix.boxlayout",   ["BoxLayout"])) }
        if needsGridLayout { body.append(importFrom("kivy.uix.gridlayout", ["GridLayout"])) }
        if needsLabel     { body.append(importFrom("kivy.uix.label",       ["Label"])) }

        // Graphics imports (only if any node has canvas layers)
        if !graphicsNameSet.isEmpty {
            body.append(importFrom("kivy.graphics", graphicsNameSet))
        }
        if needsCoreLabel {
            body.append(.importFrom(ImportFrom(
                module: "kivy.core.text",
                names:  [Alias(name: "Label", asName: "CoreLabel")],
                level:  0
            )))
        }

        // Font + image registration (delegated to existing CanvasCodeGen helpers via a temp generate call)
        if !fontFamilies.isEmpty || !imageRefs.isEmpty {
            // Generate a minimal CanvasCodeGen module just for registration statements,
            // extract them by generating and stripping class definitions.
            // Simplest: re-use CanvasCodeGen.generate with empty holders to trigger registration.
            // Instead, build registration inline using the same patterns CanvasCodeGen uses.
            // (font/image reg statements are module-level — we include them here)
            body.append(contentsOf: fontRegistrationStmts(fontFamilies))
            body.append(contentsOf: imageRegistrationStmts(imageRefs))
        }

        // Class definitions (post-order so dependencies come before dependents)
        for node in orderedNodes {
            body.append(.blank())
            body.append(.blank())
            body.append(classFor(node, scalable: scalable, smooth: smooth))
        }

        // preview = RootClass()
        if let lastName = orderedNodes.last?.className {
            body.append(.blank())
            body.append(.assign(Assign(
                targets: [.name(Name(id: "preview", ctx: .store))],
                value: call(name: lastName, args: [], kws: []),
                typeComment: nil
            )))
        }

        return generatePythonCode(from: .module(body))
    }

    // MARK: - Class definition

    private static func classFor(
        _ node: WidgetNode,
        scalable: Bool,
        smooth: SmoothOptions
    ) -> Statement {
        let base: String
        switch node.kind {
        case .boxLayout:  base = "BoxLayout"
        case .gridLayout: base = "GridLayout"
        default:          base = "Widget"
        }

        var bodyStmts: [Statement] = [initFor(node, scalable: scalable, smooth: smooth)]

        // Add _update_canvas if canvas layers are present
        if !node.canvasLayers.isEmpty {
            let tempIR = CanvasFrameIR(
                className: node.className,
                width:     node.frameWidth,
                height:    node.frameHeight,
                layers:    node.canvasLayers
            )
            let embed = CanvasCodeGen.canvasEmbedData(for: tempIR, scalable: scalable, smooth: smooth)
            if let updateMethod = embed.updateMethod {
                bodyStmts.append(.blank())
                bodyStmts.append(updateMethod)
            }
        }

        return .classDef(ClassDef(
            name:  node.className,
            bases: [nameExpr(base)],
            body:  bodyStmts
        ))
    }

    // MARK: - __init__ method

    private static func initFor(
        _ node: WidgetNode,
        scalable: Bool,
        smooth: SmoothOptions
    ) -> Statement {
        var stmts: [Statement] = []

        // super().__init__(**kwargs)
        stmts.append(superInit())

        // Layout-specific setup
        switch node.kind {
        case .boxLayout(let orientation, let spacing, let padding):
            stmts.append(assign("self.orientation", strConst(orientation)))
            if spacing > 0 { stmts.append(assign("self.spacing", floatConst(spacing))) }
            if !padding.isEmpty {
                let padExpr = Expression.list(List(elts: padding.map { floatConst($0) }))
                stmts.append(.assign(Assign(
                    targets: [attr(nameExpr("self"), "padding")],
                    value: padExpr,
                    typeComment: nil
                )))
            }
        case .gridLayout(let cols, let rowSpacing, let colSpacing):
            stmts.append(assign("self.cols", intConst(cols)))
            if rowSpacing > 0 || colSpacing > 0 {
                let sExpr: Expression = rowSpacing == colSpacing
                    ? floatConst(rowSpacing)
                    : .list(List(elts: [floatConst(colSpacing), floatConst(rowSpacing)]))
                stmts.append(.assign(Assign(
                    targets: [attr(nameExpr("self"), "spacing")],
                    value: sExpr,
                    typeComment: nil
                )))
            }
        default: break
        }

        // Canvas instructions
        if !node.canvasLayers.isEmpty {
            let tempIR = CanvasFrameIR(
                className: node.className,
                width:     node.frameWidth,
                height:    node.frameHeight,
                layers:    node.canvasLayers
            )
            let embed = CanvasCodeGen.canvasEmbedData(for: tempIR, scalable: scalable, smooth: smooth)
            if !embed.initStmts.isEmpty {
                stmts.append(.blank())
                stmts.append(contentsOf: embed.initStmts)
            }
        }

        // Children
        if !node.children.isEmpty { stmts.append(.blank()) }
        for (i, child) in node.children.enumerated() {
            if case .label(let text, let fontSize) = child.kind {
                let localName = "lbl_\(i)"
                let kws = [
                    Keyword(arg: "text",      value: strConst(text)),
                    Keyword(arg: "font_size", value: intConst(fontSize)),
                ]
                stmts.append(.assign(Assign(
                    targets: [.name(Name(id: localName, ctx: .store))],
                    value: call(name: "Label", args: [], kws: kws),
                    typeComment: nil
                )))
                stmts.append(exprStmt(call(
                    fun: attr(nameExpr("self"), "add_widget"),
                    args: [nameExpr(localName)], kws: []
                )))
            } else {
                let localName = "\(child.className.prefix(1).lowercased())\(child.className.dropFirst())_\(i)"
                stmts.append(.assign(Assign(
                    targets: [.name(Name(id: localName, ctx: .store))],
                    value: call(name: child.className, args: [], kws: []),
                    typeComment: nil
                )))
                stmts.append(exprStmt(call(
                    fun: attr(nameExpr("self"), "add_widget"),
                    args: [nameExpr(localName)], kws: []
                )))
            }
        }

        return .functionDef(FunctionDef(
            name: "__init__",
            args: Arguments(args: [Arg(arg: "self")], kwarg: Arg(arg: "kwargs")),
            body: stmts
        ))
    }

    // MARK: - Font/image registration (mirrors CanvasCodeGen logic)

    private static func fontRegistrationStmts(_ families: [String]) -> [Statement] {
        guard !families.isEmpty else { return [] }
        var stmts: [Statement] = [.blank()]
        stmts.append(.importFrom(ImportFrom(
            module: "kivy.core.text",
            names:  [Alias(name: "LabelBase", asName: nil)],
            level:  0
        )))
        for family in families {
            let constName = family.uppercased().replacingOccurrences(of: " ", with: "_")
            stmts.append(.assign(Assign(
                targets: [.name(Name(id: constName, ctx: .store))],
                value: strConst(family),
                typeComment: nil
            )))
        }
        return stmts
    }

    private static func imageRegistrationStmts(_ refs: [String]) -> [Statement] {
        guard !refs.isEmpty else { return [] }
        // Emit a blank + a comment marker; actual download logic is identical to CanvasCodeGen.
        // We generate a minimal dummy CanvasFrameIR to reuse CanvasCodeGen.generate(), then
        // extract only the registration lines from the output string up to the first `class` keyword.
        // This avoids duplicating the urllib / os / tempfile logic here.
        // For now: emit the constant assignments only (no download — app.py handles that).
        var stmts: [Statement] = [.blank()]
        for hash in refs {
            let constName  = "IMG_" + String(hash.prefix(16)).uppercased()
            let fileName   = String(hash.prefix(16)) + ".png"
            // IMG_xxx = "/tmp/images/xxxxxxxxxxxxxxxx.png"
            stmts.append(.assign(Assign(
                targets: [.name(Name(id: constName, ctx: .store))],
                value: strConst("/tmp/images/\(fileName)"),
                typeComment: nil
            )))
        }
        return stmts
    }

    // MARK: - AST helpers

    private static func importFrom(_ module: String, _ names: [String]) -> Statement {
        .importFrom(ImportFrom(
            module: module,
            names:  names.map { Alias(name: $0, asName: nil) },
            level:  0
        ))
    }

    private static func nameExpr(_ id: String) -> Expression {
        .name(Name(id: id))
    }

    private static func attr(_ value: Expression, _ a: String) -> Expression {
        .attribute(Attribute(value: value, attr: a, ctx: .load))
    }

    private static func call(name: String, args: [Expression], kws: [Keyword]) -> Expression {
        .call(Call(fun: nameExpr(name), args: args, keywords: kws))
    }

    private static func call(fun: Expression, args: [Expression], kws: [Keyword]) -> Expression {
        .call(Call(fun: fun, args: args, keywords: kws))
    }

    private static func exprStmt(_ expr: Expression) -> Statement {
        .expr(Expr(value: expr))
    }

    private static func assign(_ target: String, _ value: Expression) -> Statement {
        // target like "self.orientation" → split on first dot
        let parts = target.split(separator: ".", maxSplits: 1)
        let targetExpr: Expression = parts.count == 2
            ? attr(nameExpr(String(parts[0])), String(parts[1]))
            : .name(Name(id: target, ctx: .store))
        return .assign(Assign(
            targets: [targetExpr],
            value: value,
            typeComment: nil
        ))
    }

    private static func superInit() -> Statement {
        exprStmt(.call(Call(
            fun: .attribute(Attribute(
                value: .call(Call(fun: nameExpr("super"), args: [], keywords: [])),
                attr: "__init__",
                ctx: .load
            )),
            args: [],
            keywords: [Keyword(arg: nil, value: nameExpr("kwargs"))]
        )))
    }

    private static func intConst(_ v: Int) -> Expression {
        .constant(Constant(value: .int(v)))
    }

    private static func floatConst(_ v: Double) -> Expression {
        .constant(Constant(value: .float(v)))
    }

    private static func strConst(_ v: String) -> Expression {
        .constant(Constant(value: .string(v)))
    }

    // Placeholder for assign — not actually used above since we use the inline style
    private static func nameConst(_ id: String) -> Expression { nameExpr(id) }
}
