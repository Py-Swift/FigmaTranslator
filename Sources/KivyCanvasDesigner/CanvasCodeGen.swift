import PySwiftAST
import PySwiftCodeGen

// MARK: - Public embed data

/// Data returned by `CanvasCodeGen.canvasEmbedData()` for use by `KivyWidgetDesigner`.
public struct CanvasEmbedData {
    /// Canvas `__init__` statements to splice into a Widget subclass (no `super().__init__` call).
    public let initStmts: [Statement]
    /// A `_update_canvas(self, *args)` method if any instructions are size-dependent.
    public let updateMethod: Statement?
    /// `kivy.graphics` names required (e.g. `["Color", "Rectangle"]`).
    public let graphicsNames: [String]
    /// Font family names referenced by text instructions.
    public let fontFamilies: [String]
    /// Image-hash refs referenced by image instructions.
    public let imageRefs: [String]
    /// Whether a `CoreLabel` import is needed.
    public let needsCoreLabel: Bool
}

// MARK: - Code Generator

public enum CanvasCodeGen {

    private struct GeneratedRef {
        enum Kind {
            case shape(CanvasShapeIR)
            case group(CanvasGroupIR)
            case text(CanvasTextIR, lblAttrName: String)
        }
        let attrName: String
        let kind: Kind
    }

    // MARK: - Public entry

    /// Generates a Python source string for all frames in a single module.
    static func generate(frames: [CanvasFrameIR], scalable: Bool = false, smooth: SmoothOptions = .init()) -> String {
        guard !frames.isEmpty else { return "" }

        // Determine which graphics classes are needed (recurse into groups).
        var needsRectangle        = false
        var needsRoundedRectangle = false
        var needsEllipse          = false
        var needsTriangle         = false
        var needsGroups           = false
        var needsText             = false
        var fontFamilies: [String] = []   // ordered, deduplicated in insertion order
        var imageRefs:    [String] = []   // ordered, deduplicated image hashes
        var svgNodeIds: [String] = []   // ordered, deduplicated SVG node IDs
        func scanItems(_ items: [CanvasItem]) {
            for item in items {
                switch item {
                case .shape(let s):
                    switch s.kind {
                    case .rectangle:        needsRectangle        = true
                    case .roundedRectangle: needsRoundedRectangle = true
                    case .ellipse:          needsEllipse          = true
                    case .triangle:         needsTriangle         = true
                    }
                case .group(let g):
                    needsGroups = true
                    scanItems(g.items)
                case .text(let txt):
                    needsText      = true
                    needsRectangle = true
                    if !txt.fontFamily.isEmpty && !fontFamilies.contains(txt.fontFamily) {
                        fontFamilies.append(txt.fontFamily)
                    }
                case .image(let img):
                    needsRectangle = true
                    if !imageRefs.contains(img.imageRef) {
                        imageRefs.append(img.imageRef)
                    }
                case .svg(let svg):
                    if !svgNodeIds.contains(svg.nodeId) {
                        svgNodeIds.append(svg.nodeId)
                    }
                }
            }
        }
        for frame in frames {
            for layer in frame.layers { scanItems(layer.items) }
        }

        var graphicsNames = ["Color"]
        if needsRectangle        { graphicsNames.append(smooth.rectangle        ? "SmoothRectangle"        : "Rectangle") }
        if needsRoundedRectangle { graphicsNames.append(smooth.roundedRectangle ? "SmoothRoundedRectangle" : "RoundedRectangle") }
        if needsEllipse          { graphicsNames.append(smooth.ellipse          ? "SmoothEllipse"          : "Ellipse") }
        if needsTriangle         { graphicsNames.append(smooth.triangle         ? "SmoothTriangle"         : "Triangle") }
        if needsGroups           { graphicsNames.append("InstructionGroup") }

        // Imports
        let importWidget = Statement.importFrom(ImportFrom(
            module: "kivy.uix.widget",
            names: [Alias(name: "Widget", asName: nil)],
            level: 0
        ))
        let importGraphics = Statement.importFrom(ImportFrom(
            module: "kivy.graphics",
            names: graphicsNames.map { Alias(name: $0, asName: nil) },
            level: 0
        ))
        let importCoreLabel = Statement.importFrom(ImportFrom(
            module: "kivy.core.text",
            names: [Alias(name: "Label", asName: "CoreLabel")],
            level: 0
        ))

        // Collect all InstructionGroup subclasses in post-order (leafs emitted first).
        let groups = allGroupsPostOrder(frames: frames)

        // Assemble module body: imports → font/image/svg registration → group classes → frame Widget classes.
        var body: [Statement] = needsText ? [importWidget, importGraphics, importCoreLabel]
                                          : [importWidget, importGraphics]
        let needsDownload = !fontFamilies.isEmpty || !imageRefs.isEmpty || !svgNodeIds.isEmpty
        if needsDownload {
            body.append(contentsOf: downloadImports())
        }
        if !fontFamilies.isEmpty {
            body.append(contentsOf: fontRegistrationStmts(families: fontFamilies))
        }
        if !imageRefs.isEmpty {
            body.append(contentsOf: imageRegistrationStmts(refs: imageRefs))
        }
        if !svgNodeIds.isEmpty {
            body.append(contentsOf: svgRegistrationStmts(ids: svgNodeIds))
            body.append(contentsOf: svgClassStmts())
        }
        for group in groups {
            body.append(.blank())
            body.append(.blank())
            body.append(groupClassDef(group, scalable: scalable, smooth: smooth))
        }
        for frame in frames {
            body.append(.blank())
            body.append(.blank())
            body.append(classDefFor(frame, scalable: scalable, smooth: smooth))
        }

        if let lastName = frames.last?.className {
            body.append(.blank())
            body.append(.assign(Assign(
                targets: [.name(Name(id: "preview", ctx: .store))],
                value: callExpr(fun: nameExpr(lastName), args: [], keywords: []),
                typeComment: nil
            )))
        }

        return generatePythonCode(from: .module(body))
    }

    // MARK: - Class definition

    private static func classDefFor(_ frame: CanvasFrameIR, scalable: Bool, smooth: SmoothOptions) -> Statement {
        var refs: [GeneratedRef] = []
        let initFunc = initFuncFor(frame, scalable: scalable, smooth: smooth, refs: &refs)
        var body: [Statement] = [initFunc]
        if !refs.isEmpty {
            body.append(.blank())
            body.append(updateCanvasFuncFor(frame: frame, refs: refs, scalable: scalable))
        }
        // Generate update_text_N(self, new_text) for each text item
        for ref in refs {
            if case .text(_, let lblName) = ref.kind {
                body.append(.blank())
                body.append(updateTextFuncFor(rectAttrName: ref.attrName, lblAttrName: lblName))
            }
        }
        return .classDef(ClassDef(
            name: frame.className,
            bases: [nameExpr("Widget")],
            body: body
        ))
    }

    private static func initFuncFor(_ frame: CanvasFrameIR, scalable: Bool, smooth: SmoothOptions, refs: inout [GeneratedRef]) -> Statement {
        .functionDef(FunctionDef(
            name: "__init__",
            args: Arguments(
                args: [Arg(arg: "self")],
                kwarg: Arg(arg: "kwargs")
            ),
            body: initBodyFor(frame, scalable: scalable, smooth: smooth, refs: &refs)
        ))
    }

    // MARK: - __init__ body (Widget)

    private static func initBodyFor(_ frame: CanvasFrameIR, scalable: Bool, smooth: SmoothOptions, refs: inout [GeneratedRef]) -> [Statement] {
        // super().__init__(**kwargs)
        let superCall = exprStmt(
            callExpr(
                fun: attrExpr(
                    callExpr(fun: nameExpr("super"), args: [], keywords: []),
                    "__init__"
                ),
                args: [],
                keywords: [Keyword(arg: nil, value: nameExpr("kwargs"))]
            )
        )

        let activeLayers = frame.layers.filter { !$0.items.isEmpty }
        guard !activeLayers.isEmpty else { return [superCall] }

        var stmts: [Statement] = [superCall]

        // In scalable mode: unpack x,y,w,h once from self, then use those locals.
        let xExpr:      Expression?
        let yExpr:      Expression?
        let widthExpr:  Expression?
        let heightExpr: Expression?
        if scalable {
            let localsAssign = Statement.assign(Assign(
                targets: [.tuple(Tuple(elts: [
                    .name(Name(id: "x", ctx: .store)),
                    .name(Name(id: "y", ctx: .store)),
                    .name(Name(id: "w", ctx: .store)),
                    .name(Name(id: "h", ctx: .store)),
                ]))],
                value: .tuple(Tuple(elts: [
                    attrExpr(nameExpr("self"), "x"),
                    attrExpr(nameExpr("self"), "y"),
                    attrExpr(nameExpr("self"), "width"),
                    attrExpr(nameExpr("self"), "height"),
                ])),
                typeComment: nil
            ))
            stmts.append(localsAssign)
            xExpr      = nameExpr("x")
            yExpr      = nameExpr("y")
            widthExpr  = nameExpr("w")
            heightExpr = nameExpr("h")
        } else {
            xExpr      = nil
            yExpr      = nil
            widthExpr  = nil
            heightExpr = nil
        }

        var counter = 0

        for (i, layer) in activeLayers.enumerated() {
            if i > 0 { stmts.append(.blank()) }

            // cb = self.canvas.before / after / (main)
            let cbExpr: Expression
            switch layer.target {
            case .before: cbExpr = attrExpr(attrExpr(nameExpr("self"), "canvas"), "before")
            case .after:  cbExpr = attrExpr(attrExpr(nameExpr("self"), "canvas"), "after")
            case .main:   cbExpr = attrExpr(nameExpr("self"), "canvas")
            }
            stmts.append(.assign(Assign(
                targets: [.name(Name(id: "cb", ctx: .store))],
                value: cbExpr,
                typeComment: nil
            )))

            stmts.append(contentsOf: cbAddItemStmts(
                layer.items,
                scalable: scalable,
                smooth: smooth,
                frameWidth: frame.width,
                frameHeight: frame.height,
                xExpr: xExpr,
                yExpr: yExpr,
                widthExpr: widthExpr,
                heightExpr: heightExpr,
                refs: &refs,
                counter: &counter
            ))
        }

        if !refs.isEmpty {
            stmts.append(.blank())
            stmts.append(exprStmt(callExpr(
                fun: attrExpr(nameExpr("self"), "bind"),
                args: [],
                keywords: [
                    Keyword(arg: "pos",  value: attrExpr(nameExpr("self"), "_update_canvas")),
                    Keyword(arg: "size", value: attrExpr(nameExpr("self"), "_update_canvas"))
                ]
            )))
            stmts.append(exprStmt(callExpr(
                fun: attrExpr(nameExpr("self"), "_update_canvas"),
                args: [],
                keywords: []
            )))
        }

        return stmts
    }

    // MARK: - InstructionGroup class definition

    private static func groupClassDef(_ group: CanvasGroupIR, scalable: Bool, smooth: SmoothOptions) -> Statement {
        let superCall = exprStmt(
            callExpr(
                fun: attrExpr(
                    callExpr(fun: nameExpr("super"), args: [], keywords: []),
                    "__init__"
                ),
                args: [],
                keywords: []
            )
        )

        let initArgs: Arguments
        let xExpr:      Expression?
        let yExpr:      Expression?
        let widthExpr:  Expression?
        let heightExpr: Expression?
        if scalable {
            initArgs   = Arguments(args: [Arg(arg: "self"), Arg(arg: "x"), Arg(arg: "y"), Arg(arg: "w"), Arg(arg: "h")], kwarg: nil)
            xExpr      = nameExpr("x")
            yExpr      = nameExpr("y")
            widthExpr  = nameExpr("w")
            heightExpr = nameExpr("h")
        } else {
            initArgs   = Arguments(args: [Arg(arg: "self")], kwarg: nil)
            xExpr      = nil
            yExpr      = nil
            widthExpr  = nil
            heightExpr = nil
        }

        var counter = 0
        var refs: [GeneratedRef] = []
        var body: [Statement] = [superCall]
        body.append(contentsOf: addItemStmts(
            group.items,
            scalable: scalable,
            smooth: smooth,
            frameWidth:  group.frameWidth,
            frameHeight: group.frameHeight,
            xExpr:      xExpr,
            yExpr:      yExpr,
            widthExpr:  widthExpr,
            heightExpr: heightExpr,
            refs: &refs,
            counter: &counter
        ))
        let initFunc = Statement.functionDef(FunctionDef(
            name: "__init__",
            args: initArgs,
            body: body
        ))
        var classBody: [Statement] = [initFunc]
        if scalable && !refs.isEmpty {
            classBody.append(.blank())
            classBody.append(updateFuncForGroup(group: group, refs: refs))
        }
        return .classDef(ClassDef(
            name: group.className,
            bases: [nameExpr("InstructionGroup")],
            body: classBody
        ))
    }

    // MARK: - Post-order group collection

    private static func allGroupsPostOrder(frames: [CanvasFrameIR]) -> [CanvasGroupIR] {
        var result: [CanvasGroupIR] = []
        var seen: Swift.Set<String> = []
        func walk(_ items: [CanvasItem]) {
            for item in items {
                if case .group(let g) = item {
                    walk(g.items)
                    if seen.insert(g.className).inserted {
                        result.append(g)
                    }
                }
            }
        }
        for frame in frames {
            for layer in frame.layers { walk(layer.items) }
        }
        return result
    }

    // MARK: - Item statements

    /// For Widget canvas layers: assign `self.xxx_N = Instruction(...)` then `cb.add(self.xxx_N)`.
    private static func cbAddItemStmts(
        _ items: [CanvasItem],
        scalable: Bool,
        smooth: SmoothOptions,
        frameWidth: Int,
        frameHeight: Int,
        xExpr: Expression?,
        yExpr: Expression?,
        widthExpr: Expression?,
        heightExpr: Expression?,
        refs: inout [GeneratedRef],
        counter: inout Int
    ) -> [Statement] {
        var stmts: [Statement] = []
        var lastR = Double.nan, lastG = Double.nan, lastB = Double.nan, lastA = Double.nan

        for item in items {
            switch item {
            case .shape(let shape):
                if shape.r != lastR || shape.g != lastG || shape.b != lastB || shape.a != lastA {
                    let rgba = Expression.tuple(Tuple(elts: [
                        floatConst(shape.r), floatConst(shape.g),
                        floatConst(shape.b), floatConst(shape.a)
                    ]))
                    let attrName = "color_\(counter)"
                    counter += 1
                    let ref = attrExpr(nameExpr("self"), attrName)
                    stmts.append(.assign(Assign(
                        targets: [ref],
                        value: callExpr(fun: nameExpr("Color"), args: [], keywords: [Keyword(arg: "rgba", value: rgba)]),
                        typeComment: nil
                    )))
                    stmts.append(cbAdd(ref))
                    lastR = shape.r; lastG = shape.g; lastB = shape.b; lastA = shape.a
                }
                let shapeName: String
                switch shape.kind {
                case .rectangle:        shapeName = smooth.rectangle        ? "SmoothRectangle"        : "Rectangle"
                case .roundedRectangle: shapeName = smooth.roundedRectangle ? "SmoothRoundedRectangle" : "RoundedRectangle"
                case .ellipse:          shapeName = smooth.ellipse          ? "SmoothEllipse"          : "Ellipse"
                case .triangle:         shapeName = smooth.triangle         ? "SmoothTriangle"         : "Triangle"
                }
                let attrPrefix: String
                switch shape.kind {
                case .rectangle, .roundedRectangle: attrPrefix = "rect_"
                case .ellipse:                      attrPrefix = "ellipse_"
                case .triangle:                     attrPrefix = "tri_"
                }
                let attrName = attrPrefix + "\(counter)"
                counter += 1
                let ref = attrExpr(nameExpr("self"), attrName)
                let shapeKws: [Keyword]
                if shape.kind == .triangle {
                    let pts = triPoints(shape, scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight, xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr)
                    shapeKws = [Keyword(arg: "points", value: pts)]
                } else if shape.kind == .roundedRectangle, let radii = shape.cornerRadii {
                    let (pos, size) = posSize(shape, scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight, xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr)
                    shapeKws = [Keyword(arg: "pos", value: pos), Keyword(arg: "size", value: size), Keyword(arg: "radius", value: radiusExpr(radii))]
                } else {
                    let (pos, size) = posSize(shape, scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight, xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr)
                    shapeKws = [Keyword(arg: "pos", value: pos), Keyword(arg: "size", value: size)]
                }
                stmts.append(.assign(Assign(
                    targets: [ref],
                    value: callExpr(fun: nameExpr(shapeName), args: [], keywords: shapeKws),
                    typeComment: nil
                )))
                stmts.append(cbAdd(ref))
                refs.append(GeneratedRef(attrName: attrName, kind: .shape(shape)))
            case .group(let group):
                lastR = Double.nan
                var groupArgs: [Expression] = []
                if scalable, let xe = xExpr, let ye = yExpr, let we = widthExpr, let he = heightExpr {
                    groupArgs = [xe, ye, we, he]
                }
                let attrName = "\(group.className.prefix(1).lowercased())\(group.className.dropFirst())_\(counter)"
                counter += 1
                let ref = attrExpr(nameExpr("self"), attrName)
                stmts.append(.assign(Assign(
                    targets: [ref],
                    value: callExpr(fun: nameExpr(group.className), args: groupArgs, keywords: []),
                    typeComment: nil
                )))
                stmts.append(cbAdd(ref))
                refs.append(GeneratedRef(attrName: attrName, kind: .group(group)))
            case .text(let txt):
                // Color instruction (reset tracking — text uses its own color)
                let rgba = Expression.tuple(Tuple(elts: [
                    floatConst(txt.r), floatConst(txt.g),
                    floatConst(txt.b), floatConst(txt.a)
                ]))
                let colorName = "color_\(counter)"
                counter += 1
                let colorRef = attrExpr(nameExpr("self"), colorName)
                stmts.append(.assign(Assign(
                    targets: [colorRef],
                    value: callExpr(fun: nameExpr("Color"), args: [], keywords: [Keyword(arg: "rgba", value: rgba)]),
                    typeComment: nil
                )))
                stmts.append(cbAdd(colorRef))
                lastR = txt.r; lastG = txt.g; lastB = txt.b; lastA = txt.a

                // CoreLabel — build once then refresh to get texture
                let localLbl = "_lbl_\(counter)"
                var lblKws: [Keyword] = [
                    Keyword(arg: "text",      value: strConst(txt.text)),
                    Keyword(arg: "font_size", value: intConst(txt.fontSize))
                ]
                if txt.bold   { lblKws.append(Keyword(arg: "bold",   value: boolConst(true))) }
                if txt.italic { lblKws.append(Keyword(arg: "italic", value: boolConst(true))) }
                if txt.halign != "left" { lblKws.append(Keyword(arg: "halign", value: strConst(txt.halign))) }
                if !txt.fontFamily.isEmpty { lblKws.append(Keyword(arg: "font_name", value: nameExpr(CanvasCodeGen.fontConstName(txt.fontFamily)))) }
                // lbl = CoreLabel(...)
                stmts.append(.assign(Assign(
                    targets: [.name(Name(id: localLbl, ctx: .store))],
                    value: callExpr(fun: nameExpr("CoreLabel"), args: [], keywords: lblKws),
                    typeComment: nil
                )))
                stmts.append(exprStmt(callExpr(fun: attrExpr(nameExpr(localLbl), "refresh"), args: [], keywords: [])))
                // Store label on self for later updates
                stmts.append(.assign(Assign(
                    targets: [attrExpr(nameExpr("self"), localLbl)],
                    value: .name(Name(id: localLbl, ctx: .load)),
                    typeComment: nil
                )))

                // Rectangle with CoreLabel texture
                let attrName = "text_\(counter)_rect"
                counter += 1
                let (pos, _) = posSize(
                    CanvasShapeIR(kind: .rectangle, x: txt.x, y: txt.y, width: txt.width, height: txt.height,
                                  r: txt.r, g: txt.g, b: txt.b, a: txt.a, cornerRadii: nil),
                    scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight,
                    xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr
                )
                let texRef  = attrExpr(nameExpr(localLbl), "texture")
                let texSize  = attrExpr(attrExpr(nameExpr(localLbl), "texture"), "size")
                let ref = attrExpr(nameExpr("self"), attrName)
                stmts.append(.assign(Assign(
                    targets: [ref],
                    value: callExpr(fun: nameExpr("Rectangle"), args: [], keywords: [
                        Keyword(arg: "texture", value: texRef),
                        Keyword(arg: "pos",     value: pos),
                        Keyword(arg: "size",    value: texSize)
                    ]),
                    typeComment: nil
                )))
                stmts.append(cbAdd(ref))
                refs.append(GeneratedRef(attrName: attrName, kind: .text(txt, lblAttrName: localLbl)))
            case .image(let img):
                let rgba = Expression.tuple(Tuple(elts: [
                    floatConst(1.0), floatConst(1.0), floatConst(1.0), floatConst(img.opacity)
                ]))
                let colorName = "color_\(counter)"
                counter += 1
                let colorRef = attrExpr(nameExpr("self"), colorName)
                stmts.append(.assign(Assign(
                    targets: [colorRef],
                    value: callExpr(fun: nameExpr("Color"), args: [], keywords: [Keyword(arg: "rgba", value: rgba)]),
                    typeComment: nil
                )))
                stmts.append(cbAdd(colorRef))
                lastR = 1.0; lastG = 1.0; lastB = 1.0; lastA = img.opacity

                let attrName = "img_rect_\(counter)"
                counter += 1
                let (pos, size) = posSize(
                    CanvasShapeIR(kind: .rectangle, x: img.x, y: img.y, width: img.width, height: img.height,
                                  r: 1, g: 1, b: 1, a: img.opacity, cornerRadii: nil),
                    scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight,
                    xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr
                )
                let imgConstName = CanvasCodeGen.imageConstName(img.imageRef)
                let imgRef = attrExpr(nameExpr("self"), attrName)
                stmts.append(.assign(Assign(
                    targets: [imgRef],
                    value: callExpr(fun: nameExpr("Rectangle"), args: [], keywords: [
                        Keyword(arg: "source", value: nameExpr(imgConstName)),
                        Keyword(arg: "pos",    value: pos),
                        Keyword(arg: "size",   value: size)
                    ]),
                    typeComment: nil
                )))
                stmts.append(cbAdd(imgRef))
                refs.append(GeneratedRef(attrName: attrName, kind: .shape(
                    CanvasShapeIR(kind: .rectangle, x: img.x, y: img.y, width: img.width, height: img.height,
                                  r: 1, g: 1, b: 1, a: img.opacity, cornerRadii: nil)
                )))
            case .svg(let svg):
                let rgba = Expression.tuple(Tuple(elts: [
                    floatConst(1.0), floatConst(1.0), floatConst(1.0), floatConst(svg.opacity)
                ]))
                let colorName = "color_\(counter)"
                counter += 1
                let colorRef = attrExpr(nameExpr("self"), colorName)
                stmts.append(.assign(Assign(
                    targets: [colorRef],
                    value: callExpr(fun: nameExpr("Color"), args: [], keywords: [Keyword(arg: "rgba", value: rgba)]),
                    typeComment: nil
                )))
                stmts.append(cbAdd(colorRef))
                lastR = 1.0; lastG = 1.0; lastB = 1.0; lastA = svg.opacity

                let svgAttrName = "svg_\(counter)"
                counter += 1
                let svgRef = attrExpr(nameExpr("self"), svgAttrName)
                let svgConstName = CanvasCodeGen.svgConstName(svg.nodeId)
                stmts.append(.assign(Assign(
                    targets: [svgRef],
                    value: callExpr(fun: nameExpr("Svg"), args: [
                        intConst(svg.x), intConst(svg.y),
                        intConst(svg.width), intConst(svg.height),
                        nameExpr(svgConstName)
                    ], keywords: []),
                    typeComment: nil
                )))
                stmts.append(cbAdd(svgRef))
            }
        }
        return stmts
    }

    /// For InstructionGroup: assign `self.xxx_N = Instruction(...)` then `self.add(self.xxx_N)`.
    private static func addItemStmts(
        _ items: [CanvasItem],
        scalable: Bool = false,
        smooth: SmoothOptions = .init(),
        frameWidth: Int = 0,
        frameHeight: Int = 0,
        xExpr: Expression? = nil,
        yExpr: Expression? = nil,
        widthExpr: Expression? = nil,
        heightExpr: Expression? = nil,
        refs: inout [GeneratedRef],
        counter: inout Int
    ) -> [Statement] {
        var stmts: [Statement] = []
        var lastR = Double.nan, lastG = Double.nan, lastB = Double.nan, lastA = Double.nan

        for item in items {
            switch item {
            case .shape(let shape):
                if shape.r != lastR || shape.g != lastG || shape.b != lastB || shape.a != lastA {
                    let rgba = Expression.tuple(Tuple(elts: [
                        floatConst(shape.r), floatConst(shape.g),
                        floatConst(shape.b), floatConst(shape.a)
                    ]))
                    let attrName = "color_\(counter)"
                    counter += 1
                    let ref = attrExpr(nameExpr("self"), attrName)
                    stmts.append(.assign(Assign(
                        targets: [ref],
                        value: callExpr(fun: nameExpr("Color"), args: [], keywords: [Keyword(arg: "rgba", value: rgba)]),
                        typeComment: nil
                    )))
                    stmts.append(selfAdd(ref))
                    lastR = shape.r; lastG = shape.g; lastB = shape.b; lastA = shape.a
                }
                let shapeName: String
                switch shape.kind {
                case .rectangle:        shapeName = smooth.rectangle        ? "SmoothRectangle"        : "Rectangle"
                case .roundedRectangle: shapeName = smooth.roundedRectangle ? "SmoothRoundedRectangle" : "RoundedRectangle"
                case .ellipse:          shapeName = smooth.ellipse          ? "SmoothEllipse"          : "Ellipse"
                case .triangle:         shapeName = smooth.triangle         ? "SmoothTriangle"         : "Triangle"
                }
                let attrPrefix: String
                switch shape.kind {
                case .rectangle, .roundedRectangle: attrPrefix = "rect_"
                case .ellipse:                      attrPrefix = "ellipse_"
                case .triangle:                     attrPrefix = "tri_"
                }
                let attrName = attrPrefix + "\(counter)"
                counter += 1
                let ref = attrExpr(nameExpr("self"), attrName)
                let shapeKws: [Keyword]
                if shape.kind == .triangle {
                    let pts = triPoints(shape, scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight, xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr)
                    shapeKws = [Keyword(arg: "points", value: pts)]
                } else if shape.kind == .roundedRectangle, let radii = shape.cornerRadii {
                    let (pos, size) = posSize(shape, scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight, xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr)
                    shapeKws = [Keyword(arg: "pos", value: pos), Keyword(arg: "size", value: size), Keyword(arg: "radius", value: radiusExpr(radii))]
                } else {
                    let (pos, size) = posSize(shape, scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight, xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr)
                    shapeKws = [Keyword(arg: "pos", value: pos), Keyword(arg: "size", value: size)]
                }
                stmts.append(.assign(Assign(
                    targets: [ref],
                    value: callExpr(fun: nameExpr(shapeName), args: [], keywords: shapeKws),
                    typeComment: nil
                )))
                stmts.append(selfAdd(ref))
                refs.append(GeneratedRef(attrName: attrName, kind: .shape(shape)))
            case .group(let group):
                lastR = Double.nan
                var groupArgs: [Expression] = []
                if scalable, let xe = xExpr, let ye = yExpr, let we = widthExpr, let he = heightExpr {
                    groupArgs = [xe, ye, we, he]
                }
                let attrName = "\(group.className.prefix(1).lowercased())\(group.className.dropFirst())_\(counter)"
                counter += 1
                let ref = attrExpr(nameExpr("self"), attrName)
                stmts.append(.assign(Assign(
                    targets: [ref],
                    value: callExpr(fun: nameExpr(group.className), args: groupArgs, keywords: []),
                    typeComment: nil
                )))
                stmts.append(selfAdd(ref))
                refs.append(GeneratedRef(attrName: attrName, kind: .group(group)))
            case .text(let txt):
                let rgba = Expression.tuple(Tuple(elts: [
                    floatConst(txt.r), floatConst(txt.g),
                    floatConst(txt.b), floatConst(txt.a)
                ]))
                let colorName = "color_\(counter)"
                counter += 1
                let colorRef = attrExpr(nameExpr("self"), colorName)
                stmts.append(.assign(Assign(
                    targets: [colorRef],
                    value: callExpr(fun: nameExpr("Color"), args: [], keywords: [Keyword(arg: "rgba", value: rgba)]),
                    typeComment: nil
                )))
                stmts.append(selfAdd(colorRef))
                lastR = txt.r; lastG = txt.g; lastB = txt.b; lastA = txt.a

                let localLbl = "_lbl_\(counter)"
                var lblKws: [Keyword] = [
                    Keyword(arg: "text",      value: strConst(txt.text)),
                    Keyword(arg: "font_size", value: intConst(txt.fontSize))
                ]
                if txt.bold   { lblKws.append(Keyword(arg: "bold",   value: boolConst(true))) }
                if txt.italic { lblKws.append(Keyword(arg: "italic", value: boolConst(true))) }
                if txt.halign != "left" { lblKws.append(Keyword(arg: "halign", value: strConst(txt.halign))) }
                if !txt.fontFamily.isEmpty { lblKws.append(Keyword(arg: "font_name", value: nameExpr(CanvasCodeGen.fontConstName(txt.fontFamily)))) }
                stmts.append(.assign(Assign(
                    targets: [.name(Name(id: localLbl, ctx: .store))],
                    value: callExpr(fun: nameExpr("CoreLabel"), args: [], keywords: lblKws),
                    typeComment: nil
                )))
                stmts.append(exprStmt(callExpr(fun: attrExpr(nameExpr(localLbl), "refresh"), args: [], keywords: [])))
                // Store label on self for later updates
                stmts.append(.assign(Assign(
                    targets: [attrExpr(nameExpr("self"), localLbl)],
                    value: .name(Name(id: localLbl, ctx: .load)),
                    typeComment: nil
                )))

                let attrName = "text_\(counter)_rect"
                counter += 1
                let (pos, _) = posSize(
                    CanvasShapeIR(kind: .rectangle, x: txt.x, y: txt.y, width: txt.width, height: txt.height,
                                  r: txt.r, g: txt.g, b: txt.b, a: txt.a, cornerRadii: nil),
                    scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight,
                    xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr
                )
                let texRef  = attrExpr(nameExpr(localLbl), "texture")
                let texSize  = attrExpr(attrExpr(nameExpr(localLbl), "texture"), "size")
                let ref = attrExpr(nameExpr("self"), attrName)
                stmts.append(.assign(Assign(
                    targets: [ref],
                    value: callExpr(fun: nameExpr("Rectangle"), args: [], keywords: [
                        Keyword(arg: "texture", value: texRef),
                        Keyword(arg: "pos",     value: pos),
                        Keyword(arg: "size",    value: texSize)
                    ]),
                    typeComment: nil
                )))
                stmts.append(selfAdd(ref))
                refs.append(GeneratedRef(attrName: attrName, kind: .text(txt, lblAttrName: localLbl)))
            case .image(let img):
                let rgba = Expression.tuple(Tuple(elts: [
                    floatConst(1.0), floatConst(1.0), floatConst(1.0), floatConst(img.opacity)
                ]))
                let colorName = "color_\(counter)"
                counter += 1
                let colorRef = attrExpr(nameExpr("self"), colorName)
                stmts.append(.assign(Assign(
                    targets: [colorRef],
                    value: callExpr(fun: nameExpr("Color"), args: [], keywords: [Keyword(arg: "rgba", value: rgba)]),
                    typeComment: nil
                )))
                stmts.append(selfAdd(colorRef))
                lastR = 1.0; lastG = 1.0; lastB = 1.0; lastA = img.opacity

                let attrName = "img_rect_\(counter)"
                counter += 1
                let (pos, size) = posSize(
                    CanvasShapeIR(kind: .rectangle, x: img.x, y: img.y, width: img.width, height: img.height,
                                  r: 1, g: 1, b: 1, a: img.opacity, cornerRadii: nil),
                    scalable: scalable, frameWidth: frameWidth, frameHeight: frameHeight,
                    xe: xExpr, ye: yExpr, we: widthExpr, he: heightExpr
                )
                let imgConstName = CanvasCodeGen.imageConstName(img.imageRef)
                let imgRef = attrExpr(nameExpr("self"), attrName)
                stmts.append(.assign(Assign(
                    targets: [imgRef],
                    value: callExpr(fun: nameExpr("Rectangle"), args: [], keywords: [
                        Keyword(arg: "source", value: nameExpr(imgConstName)),
                        Keyword(arg: "pos",    value: pos),
                        Keyword(arg: "size",   value: size)
                    ]),
                    typeComment: nil
                )))
                stmts.append(selfAdd(imgRef))
                refs.append(GeneratedRef(attrName: attrName, kind: .shape(
                    CanvasShapeIR(kind: .rectangle, x: img.x, y: img.y, width: img.width, height: img.height,
                                  r: 1, g: 1, b: 1, a: img.opacity, cornerRadii: nil)
                )))
            case .svg(let svg):
                let rgba = Expression.tuple(Tuple(elts: [
                    floatConst(1.0), floatConst(1.0), floatConst(1.0), floatConst(svg.opacity)
                ]))
                let colorName = "color_\(counter)"
                counter += 1
                let colorRef = attrExpr(nameExpr("self"), colorName)
                stmts.append(.assign(Assign(
                    targets: [colorRef],
                    value: callExpr(fun: nameExpr("Color"), args: [], keywords: [Keyword(arg: "rgba", value: rgba)]),
                    typeComment: nil
                )))
                stmts.append(selfAdd(colorRef))
                lastR = 1.0; lastG = 1.0; lastB = 1.0; lastA = svg.opacity

                let svgAttrName = "svg_\(counter)"
                counter += 1
                let svgRef = attrExpr(nameExpr("self"), svgAttrName)
                let svgConstName = CanvasCodeGen.svgConstName(svg.nodeId)
                stmts.append(.assign(Assign(
                    targets: [svgRef],
                    value: callExpr(fun: nameExpr("Svg"), args: [
                        intConst(svg.x), intConst(svg.y),
                        intConst(svg.width), intConst(svg.height),
                        nameExpr(svgConstName)
                    ], keywords: []),
                    typeComment: nil
                )))
                stmts.append(selfAdd(svgRef))
            }
        }
        return stmts
    }

    private static func selfAdd(_ ref: Expression) -> Statement {
        exprStmt(callExpr(
            fun: attrExpr(nameExpr("self"), "add"),
            args: [ref],
            keywords: []
        ))
    }

    private static func cbAdd(_ ref: Expression) -> Statement {
        exprStmt(callExpr(
            fun: attrExpr(nameExpr("cb"), "add"),
            args: [ref],
            keywords: []
        ))
    }

    private static func posSize(
        _ shape: CanvasShapeIR,
        scalable: Bool, frameWidth: Int, frameHeight: Int,
        xe: Expression?, ye: Expression?, we: Expression?, he: Expression?
    ) -> (Expression, Expression) {
        if scalable, let xe, let ye, let we, let he, frameWidth > 0, frameHeight > 0 {
            // pos = (x + w * pct_x,  y + h * pct_y)
            // size = (w * pct_w,  h * pct_h)
            let px = Expression.binOp(BinOp(left: xe, op: .add, right: scaledCoord(shape.x,      frameWidth,  we)))
            let py = Expression.binOp(BinOp(left: ye, op: .add, right: scaledCoord(shape.y,      frameHeight, he)))
            let sw = scaledCoord(shape.width,  frameWidth,  we)
            let sh = scaledCoord(shape.height, frameHeight, he)
            return (.tuple(Tuple(elts: [px, py])), .tuple(Tuple(elts: [sw, sh])))
        } else {
            return (
                .tuple(Tuple(elts: [intConst(shape.x), intConst(shape.y)])),
                .tuple(Tuple(elts: [intConst(shape.width), intConst(shape.height)]))
            )
        }
    }

    /// Returns a `points` list expression for a flat-bottom isoceles triangle derived from
    /// the shape's bounding box: bottom-left, bottom-right, top-center.
    private static func triPoints(
        _ shape: CanvasShapeIR,
        scalable: Bool, frameWidth: Int, frameHeight: Int,
        xe: Expression?, ye: Expression?, we: Expression?, he: Expression?
    ) -> Expression {
        if scalable, let xe, let ye, let we, let he, frameWidth > 0, frameHeight > 0 {
            let x0 = Expression.binOp(BinOp(left: xe, op: .add, right: scaledCoord(shape.x,                        frameWidth,  we)))
            let x1 = Expression.binOp(BinOp(left: xe, op: .add, right: scaledCoord(shape.x + shape.width,          frameWidth,  we)))
            let x2 = Expression.binOp(BinOp(left: xe, op: .add, right: scaledCoord(shape.x + shape.width / 2,      frameWidth,  we)))
            let y0 = Expression.binOp(BinOp(left: ye, op: .add, right: scaledCoord(shape.y,                        frameHeight, he)))
            let y1 = Expression.binOp(BinOp(left: ye, op: .add, right: scaledCoord(shape.y + shape.height,         frameHeight, he)))
            return .list(List(elts: [x0, y0, x1, y0, x2, y1]))
        } else {
            let x0 = shape.x
            let x1 = shape.x + shape.width
            let x2 = shape.x + shape.width / 2
            let y0 = shape.y
            let y1 = shape.y + shape.height
            return .list(List(elts: [
                intConst(x0), intConst(y0),
                intConst(x1), intConst(y0),
                intConst(x2), intConst(y1)
            ]))
        }
    }


    private static func nameExpr(_ id: String) -> Expression {
        .name(Name(id: id))
    }

    private static func attrExpr(_ value: Expression, _ attr: String) -> Expression {
        .attribute(Attribute(value: value, attr: attr, ctx: .load))
    }

    private static func callExpr(
        fun: Expression, args: [Expression], keywords: [Keyword]
    ) -> Expression {
        .call(Call(fun: fun, args: args, keywords: keywords))
    }

    private static func exprStmt(_ expr: Expression) -> Statement {
        .expr(Expr(value: expr))
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

    private static func boolConst(_ v: Bool) -> Expression {
        .constant(Constant(value: .bool(v)))
    }

    /// Returns `dimExpr * pct` where pct = value/frameDim, up to 8 significant decimal places
    /// but trailing zeros are stripped automatically by Swift's String(Double) formatting.
    private static func scaledCoord(_ value: Int, _ frameDim: Int, _ dimExpr: Expression) -> Expression {
        let pct = (Double(value) / Double(max(frameDim, 1)) * 1e8).rounded() / 1e8
        return .binOp(BinOp(left: dimExpr, op: .mult, right: floatConst(pct)))
    }

    private static func radiusExpr(_ radii: [Double]) -> Expression {
        let allSame = radii.dropFirst().allSatisfy { $0 == radii[0] }
        if allSame {
            return .list(List(elts: [floatConst(radii[0])]))
        } else {
            return .list(List(elts: radii.map { floatConst($0) }))
        }
    }

    // MARK: - Update helpers

    private static func updateStmts(
        refs: [GeneratedRef],
        scalable: Bool,
        frameWidth: Int,
        frameHeight: Int,
        xExpr: Expression?,
        yExpr: Expression?,
        widthExpr: Expression?,
        heightExpr: Expression?
    ) -> [Statement] {
        var stmts: [Statement] = []
        for ref in refs {
            switch ref.kind {
            case .shape(let shape):
                if shape.kind == .triangle {
                    let pts: Expression
                    if scalable, let xe = xExpr, let ye = yExpr, let we = widthExpr, let he = heightExpr,
                       frameWidth > 0, frameHeight > 0 {
                        pts = triPoints(shape, scalable: true, frameWidth: frameWidth, frameHeight: frameHeight, xe: xe, ye: ye, we: we, he: he)
                    } else if let xe = xExpr, let ye = yExpr {
                        let x0 = Expression.binOp(BinOp(left: xe, op: .add, right: intConst(shape.x)))
                        let x1 = Expression.binOp(BinOp(left: xe, op: .add, right: intConst(shape.x + shape.width)))
                        let x2 = Expression.binOp(BinOp(left: xe, op: .add, right: intConst(shape.x + shape.width / 2)))
                        let y0 = Expression.binOp(BinOp(left: ye, op: .add, right: intConst(shape.y)))
                        let y1 = Expression.binOp(BinOp(left: ye, op: .add, right: intConst(shape.y + shape.height)))
                        pts = .list(List(elts: [x0, y0, x1, y0, x2, y1]))
                    } else {
                        pts = triPoints(shape, scalable: false, frameWidth: frameWidth, frameHeight: frameHeight, xe: nil, ye: nil, we: nil, he: nil)
                    }
                    stmts.append(.assign(Assign(
                        targets: [attrExpr(attrExpr(nameExpr("self"), ref.attrName), "points")],
                        value: pts,
                        typeComment: nil
                    )))
                } else {
                    if scalable, let xe = xExpr, let ye = yExpr, let we = widthExpr, let he = heightExpr,
                       frameWidth > 0, frameHeight > 0 {
                        let (pos, size) = posSize(shape, scalable: true, frameWidth: frameWidth, frameHeight: frameHeight, xe: xe, ye: ye, we: we, he: he)
                        stmts.append(.assign(Assign(
                            targets: [attrExpr(attrExpr(nameExpr("self"), ref.attrName), "pos")],
                            value: pos, typeComment: nil
                        )))
                        stmts.append(.assign(Assign(
                            targets: [attrExpr(attrExpr(nameExpr("self"), ref.attrName), "size")],
                            value: size, typeComment: nil
                        )))
                    } else if let xe = xExpr, let ye = yExpr {
                        let pos = Expression.tuple(Tuple(elts: [
                            .binOp(BinOp(left: xe, op: .add, right: intConst(shape.x))),
                            .binOp(BinOp(left: ye, op: .add, right: intConst(shape.y)))
                        ]))
                        stmts.append(.assign(Assign(
                            targets: [attrExpr(attrExpr(nameExpr("self"), ref.attrName), "pos")],
                            value: pos, typeComment: nil
                        )))
                    }
                }
            case .group:
                if scalable, let xe = xExpr, let ye = yExpr, let we = widthExpr, let he = heightExpr {
                    stmts.append(exprStmt(callExpr(
                        fun: attrExpr(attrExpr(nameExpr("self"), ref.attrName), "update"),
                        args: [xe, ye, we, he],
                        keywords: []
                    )))
                }
            case .text(let txt, _):
                // Only update pos — size stays as texture_size (determined by font).
                let pos: Expression
                if scalable, let xe = xExpr, let ye = yExpr, let we = widthExpr, let he = heightExpr,
                   frameWidth > 0, frameHeight > 0 {
                    let (scaledPos, _) = posSize(
                        CanvasShapeIR(kind: .rectangle, x: txt.x, y: txt.y, width: txt.width, height: txt.height,
                                      r: txt.r, g: txt.g, b: txt.b, a: txt.a, cornerRadii: nil),
                        scalable: true, frameWidth: frameWidth, frameHeight: frameHeight,
                        xe: xe, ye: ye, we: we, he: he
                    )
                    pos = scaledPos
                } else if let xe = xExpr, let ye = yExpr {
                    pos = .tuple(Tuple(elts: [
                        .binOp(BinOp(left: xe, op: .add, right: intConst(txt.x))),
                        .binOp(BinOp(left: ye, op: .add, right: intConst(txt.y)))
                    ]))
                } else {
                    break
                }
                stmts.append(.assign(Assign(
                    targets: [attrExpr(attrExpr(nameExpr("self"), ref.attrName), "pos")],
                    value: pos,
                    typeComment: nil
                )))
            }
        }
        return stmts
    }

    /// Converts a font family name to a Python module-level constant name.
    /// e.g. "Comic Sans MS" → "COMIC_SANS_MS"
    private static func fontConstName(_ family: String) -> String {
        family.uppercased().replacingOccurrences(of: " ", with: "_")
    }

    /// Converts an image hash to a Python module-level constant name.
    /// Uses the first 16 hex characters to keep identifiers readable.
    /// e.g. "72963454773dc84b7bd498d055424636a99d576c" → "IMG_72963454773DC84B"
    static func imageConstName(_ hash: String) -> String {
        let prefix = String(hash.prefix(16)).uppercased()
        return "IMG_\(prefix)"
    }

    /// Shared download-utility imports emitted once when any of font/image/svg registration is needed.
    private static func downloadImports() -> [Statement] {
        let importUrllib   = Statement.importStmt(Import(names: [Alias(name: "urllib.request", asName: "_urllib_request")]))
        let importOs       = Statement.importStmt(Import(names: [Alias(name: "os",              asName: "_os")]))
        let importTempfile = Statement.importStmt(Import(names: [Alias(name: "tempfile",        asName: "_tempfile")]))
        return [.blank(), importUrllib, importOs, importTempfile]
    }

    /// Emits module-level statements that download each image from FIGMA_SERVER_URL
    /// into a temp file and bind a constant to its path, e.g.:
    ///   IMG_72963454773DC84B = _os.path.join(_tempfile.gettempdir(), "images", "72963454773dc84b.png")
    ///   if not _os.path.exists(IMG_72963454773DC84B):
    ///       _urllib_request.urlretrieve(_os.environ["FIGMA_SERVER_URL"] + "/image/HASH", IMG_72963454773DC84B)
    private static func imageRegistrationStmts(refs: [String]) -> [Statement] {
        // _os.makedirs(_os.path.join(_tempfile.gettempdir(), "images"), exist_ok=True)
        let fontsDirExpr = callExpr(
            fun: attrExpr(attrExpr(nameExpr("_os"), "path"), "join"),
            args: [
                callExpr(fun: attrExpr(nameExpr("_tempfile"), "gettempdir"), args: [], keywords: []),
                strConst("images")
            ],
            keywords: []
        )
        let makedirs = exprStmt(callExpr(
            fun: attrExpr(nameExpr("_os"), "makedirs"),
            args: [fontsDirExpr],
            keywords: [Keyword(arg: "exist_ok", value: boolConst(true))]
        ))

        var stmts: [Statement] = [.blank(), makedirs]

        for ref in refs {
            let constName    = imageConstName(ref)
            let fileBasename = String(ref.prefix(16)) + ".png"

            // IMG_xxx = _os.path.join(_tempfile.gettempdir(), "images", "xxxxxxxxxxxxxxxx.png")
            let constAssign = Statement.assign(Assign(
                targets: [.name(Name(id: constName, ctx: .store))],
                value: callExpr(
                    fun: attrExpr(attrExpr(nameExpr("_os"), "path"), "join"),
                    args: [
                        callExpr(fun: attrExpr(nameExpr("_tempfile"), "gettempdir"), args: [], keywords: []),
                        strConst("images"),
                        strConst(fileBasename)
                    ],
                    keywords: []
                ),
                typeComment: nil
            ))

            // _os.environ["FIGMA_SERVER_URL"] + "/image/HASH"
            let serverUrl = Expression.subscriptExpr(Subscript(
                value: attrExpr(nameExpr("_os"), "environ"),
                slice: strConst("FIGMA_SERVER_URL")
            ))
            let downloadUrl = Expression.binOp(BinOp(
                left: serverUrl, op: .add, right: strConst("/image/\(ref)")
            ))

            let urlretrieve = exprStmt(callExpr(
                fun: attrExpr(nameExpr("_urllib_request"), "urlretrieve"),
                args: [downloadUrl, nameExpr(constName)],
                keywords: []
            ))

            let ifNotExists = Statement.ifStmt(If(
                test: Expression.unaryOp(UnaryOp(op: .not, operand: callExpr(
                    fun: attrExpr(attrExpr(nameExpr("_os"), "path"), "exists"),
                    args: [nameExpr(constName)], keywords: []
                ))),
                body: [urlretrieve],
                orElse: []
            ))

            stmts.append(.blank())
            stmts.append(constAssign)
            stmts.append(ifNotExists)
        }
        return stmts
    }

    // MARK: - Public SVG extraction

    /// Returns all SVG node IDs and their built SVG XML strings from a set of frames.
    /// Call this before `generate()` in the route handler to pre-populate the SVG store.
    public static func extractSvgs(frames: [CanvasFrameIR]) -> [(nodeId: String, svgContent: String)] {
        var results: [(nodeId: String, svgContent: String)] = []
        func scan(_ items: [CanvasItem]) {
            for item in items {
                switch item {
                case .svg(let svg) where !results.contains(where: { $0.nodeId == svg.nodeId }):
                    results.append((svg.nodeId, svg.svgContent))
                case .group(let g): scan(g.items)
                default: break
                }
            }
        }
        for frame in frames { for layer in frame.layers { scan(layer.items) } }
        return results
    }

    // MARK: - SVG constants helpers

    /// Converts a Figma node ID to a Python module-level constant name.
    /// e.g. "0:123" → "SVG_0_123"
    static func svgConstName(_ svgId: String) -> String {
        let safe = svgId
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "SVG_\(safe.uppercased())"
    }

    /// Percent-encodes a Figma node ID for use in a URL path (e.g. "0:123" → "0%3A123").
    private static func svgIdUrlPath(_ svgId: String) -> String {
        svgId.replacingOccurrences(of: ":", with: "%3A")
    }

    /// Emits module-level statements that fetch each SVG from FIGMA_SERVER_URL
    /// into a temp file and bind a constant to its path, e.g.:
    ///   SVG_0_123 = _os.path.join(_tempfile.gettempdir(), "svgs", "svg_0_123.svg")
    ///   if not _os.path.exists(SVG_0_123):
    ///       _urllib_request.urlretrieve(_os.environ["FIGMA_SERVER_URL"] + "/svg/0%3A123", SVG_0_123)
    private static func svgRegistrationStmts(ids: [String]) -> [Statement] {
        // _os.makedirs(_os.path.join(_tempfile.gettempdir(), "svgs"), exist_ok=True)
        let svgsDirExpr = callExpr(
            fun: attrExpr(attrExpr(nameExpr("_os"), "path"), "join"),
            args: [
                callExpr(fun: attrExpr(nameExpr("_tempfile"), "gettempdir"), args: [], keywords: []),
                strConst("svgs")
            ],
            keywords: []
        )
        let makedirs = exprStmt(callExpr(
            fun: attrExpr(nameExpr("_os"), "makedirs"),
            args: [svgsDirExpr],
            keywords: [Keyword(arg: "exist_ok", value: boolConst(true))]
        ))

        var stmts: [Statement] = [.blank(), makedirs]

        for nodeId in ids {
            let constName    = svgConstName(nodeId)
            let fileBasename = constName.lowercased() + ".svg"
            let idEncoded    = svgIdUrlPath(nodeId)

            // SVG_0_123 = _os.path.join(_tempfile.gettempdir(), "svgs", "svg_0_123.svg")
            let constAssign = Statement.assign(Assign(
                targets: [.name(Name(id: constName, ctx: .store))],
                value: callExpr(
                    fun: attrExpr(attrExpr(nameExpr("_os"), "path"), "join"),
                    args: [
                        callExpr(fun: attrExpr(nameExpr("_tempfile"), "gettempdir"), args: [], keywords: []),
                        strConst("svgs"),
                        strConst(fileBasename)
                    ],
                    keywords: []
                ),
                typeComment: nil
            ))

            // _os.environ["FIGMA_SERVER_URL"] + "/svg/0%3A123"
            let serverUrl = Expression.subscriptExpr(Subscript(
                value: attrExpr(nameExpr("_os"), "environ"),
                slice: strConst("FIGMA_SERVER_URL")
            ))
            let downloadUrl = Expression.binOp(BinOp(
                left: serverUrl, op: .add, right: strConst("/svg/\(idEncoded)")
            ))

            let urlretrieve = exprStmt(callExpr(
                fun: attrExpr(nameExpr("_urllib_request"), "urlretrieve"),
                args: [downloadUrl, nameExpr(constName)],
                keywords: []
            ))

            let ifNotExists = Statement.ifStmt(If(
                test: Expression.unaryOp(UnaryOp(op: .not, operand: callExpr(
                    fun: attrExpr(attrExpr(nameExpr("_os"), "path"), "exists"),
                    args: [nameExpr(constName)], keywords: []
                ))),
                body: [urlretrieve],
                orElse: []
            ))

            stmts.append(.blank())
            stmts.append(constAssign)
            stmts.append(ifNotExists)
        }
        return stmts
    }

    /// Emits a single import of `Svg` from `figma_kivy_previewer.svg_instructions`.
    private static func svgClassStmts() -> [Statement] {
        let importSvg = Statement.importFrom(ImportFrom(
            module: "svg_instructions",
            names: [Alias(name: "Svg", asName: nil)],
            level: 1
        ))
        return [.blank(), importSvg]
    }

    /// Emits module-level statements that download each font from FIGMA_SERVER_URL
    /// into a temp file and bind a constant to its path, e.g.:
    ///   COMIC_SANS_MS = _os.path.join(_tempfile.gettempdir(), "fonts", "Comic_Sans_MS.ttf")
    ///   if not _os.path.exists(COMIC_SANS_MS):
    ///       _urllib_request.urlretrieve(_os.environ["FIGMA_SERVER_URL"] + "/font/Comic%20Sans%20MS", COMIC_SANS_MS)
    private static func fontRegistrationStmts(families: [String]) -> [Statement] {
        // _os.makedirs(_os.path.join(_tempfile.gettempdir(), "fonts"), exist_ok=True)
        let fontsDirExpr = callExpr(
            fun: attrExpr(attrExpr(nameExpr("_os"), "path"), "join"),
            args: [
                callExpr(fun: attrExpr(nameExpr("_tempfile"), "gettempdir"), args: [], keywords: []),
                strConst("fonts")
            ],
            keywords: []
        )
        let makedirs = exprStmt(callExpr(
            fun: attrExpr(nameExpr("_os"), "makedirs"),
            args: [fontsDirExpr],
            keywords: [Keyword(arg: "exist_ok", value: boolConst(true))]
        ))

        var stmts: [Statement] = [.blank(), makedirs]

        for family in families {
            let constName    = fontConstName(family)
            let fileBasename = family.replacingOccurrences(of: " ", with: "_") + ".ttf"
            let familyEncoded = family.replacingOccurrences(of: " ", with: "%20")

            // COMIC_SANS_MS = _os.path.join(_tempfile.gettempdir(), "fonts", "Comic_Sans_MS.ttf")
            let constAssign = Statement.assign(Assign(
                targets: [.name(Name(id: constName, ctx: .store))],
                value: callExpr(
                    fun: attrExpr(attrExpr(nameExpr("_os"), "path"), "join"),
                    args: [
                        callExpr(fun: attrExpr(nameExpr("_tempfile"), "gettempdir"), args: [], keywords: []),
                        strConst("fonts"),
                        strConst(fileBasename)
                    ],
                    keywords: []
                ),
                typeComment: nil
            ))

            // _os.environ["FIGMA_SERVER_URL"] + "/font/Comic%20Sans%20MS"
            let serverUrl = Expression.subscriptExpr(Subscript(
                value: attrExpr(nameExpr("_os"), "environ"),
                slice: strConst("FIGMA_SERVER_URL")
            ))
            let downloadUrl = Expression.binOp(BinOp(
                left: serverUrl, op: .add, right: strConst("/font/\(familyEncoded)")
            ))

            // _urllib_request.urlretrieve(url, COMIC_SANS_MS)
            let urlretrieve = exprStmt(callExpr(
                fun: attrExpr(nameExpr("_urllib_request"), "urlretrieve"),
                args: [downloadUrl, nameExpr(constName)],
                keywords: []
            ))

            // if not _os.path.exists(COMIC_SANS_MS): _urllib_request.urlretrieve(...)
            let ifNotExists = Statement.ifStmt(If(
                test: Expression.unaryOp(UnaryOp(op: .not, operand: callExpr(
                    fun: attrExpr(attrExpr(nameExpr("_os"), "path"), "exists"),
                    args: [nameExpr(constName)], keywords: []
                ))),
                body: [urlretrieve],
                orElse: []
            ))

            stmts.append(.blank())
            stmts.append(constAssign)
            stmts.append(ifNotExists)
        }
        return stmts
    }

    /// Generates `update_text_N(self, new_text)` that refreshes the CoreLabel and updates the Rectangle.
    private static func updateTextFuncFor(rectAttrName: String, lblAttrName: String) -> Statement {
        // Method name: "text_4_rect" -> "update_text_4"
        let methodName = "update_" + rectAttrName.replacingOccurrences(of: "_rect", with: "")
        let labelVar = nameExpr("label")
        let newTextVar = nameExpr("new_text")
        let selfLbl = attrExpr(nameExpr("self"), lblAttrName)
        let selfRect = attrExpr(nameExpr("self"), rectAttrName)
        let body: [Statement] = [
            // label = self._lbl_N
            .assign(Assign(targets: [labelVar], value: selfLbl, typeComment: nil)),
            // label.text = new_text
            .assign(Assign(targets: [attrExpr(labelVar, "text")], value: newTextVar, typeComment: nil)),
            // label.refresh()
            exprStmt(callExpr(fun: attrExpr(labelVar, "refresh"), args: [], keywords: [])),
            // self.text_N_rect.texture = label.texture
            .assign(Assign(
                targets: [attrExpr(selfRect, "texture")],
                value: attrExpr(labelVar, "texture"),
                typeComment: nil
            )),
            // self.text_N_rect.size = label.texture.size
            .assign(Assign(
                targets: [attrExpr(selfRect, "size")],
                value: attrExpr(attrExpr(labelVar, "texture"), "size"),
                typeComment: nil
            )),
        ]
        return .functionDef(FunctionDef(
            name: methodName,
            args: Arguments(args: [Arg(arg: "self"), Arg(arg: "new_text")]),
            body: body
        ))
    }

    private static func updateCanvasFuncFor(frame: CanvasFrameIR, refs: [GeneratedRef], scalable: Bool) -> Statement {
        let xE = nameExpr("x"); let yE = nameExpr("y")
        let wE = nameExpr("w"); let hE = nameExpr("h")
        var body: [Statement] = []
        body.append(.assign(Assign(
            targets: [.tuple(Tuple(elts: [
                .name(Name(id: "x", ctx: .store)), .name(Name(id: "y", ctx: .store)),
                .name(Name(id: "w", ctx: .store)), .name(Name(id: "h", ctx: .store))
            ]))],
            value: .tuple(Tuple(elts: [
                attrExpr(nameExpr("self"), "x"), attrExpr(nameExpr("self"), "y"),
                attrExpr(nameExpr("self"), "width"), attrExpr(nameExpr("self"), "height")
            ])),
            typeComment: nil
        )))
        body.append(contentsOf: updateStmts(
            refs: refs, scalable: scalable,
            frameWidth: frame.width, frameHeight: frame.height,
            xExpr: xE, yExpr: yE, widthExpr: wE, heightExpr: hE
        ))
        return .functionDef(FunctionDef(
            name: "_update_canvas",
            args: Arguments(args: [Arg(arg: "self")], vararg: Arg(arg: "args")),
            body: body
        ))
    }

    private static func updateFuncForGroup(group: CanvasGroupIR, refs: [GeneratedRef]) -> Statement {
        let xE = nameExpr("x"); let yE = nameExpr("y")
        let wE = nameExpr("w"); let hE = nameExpr("h")
        let body = updateStmts(
            refs: refs, scalable: true,
            frameWidth: group.frameWidth, frameHeight: group.frameHeight,
            xExpr: xE, yExpr: yE, widthExpr: wE, heightExpr: hE
        )
        return .functionDef(FunctionDef(
            name: "update",
            args: Arguments(args: [Arg(arg: "self"), Arg(arg: "x"), Arg(arg: "y"), Arg(arg: "w"), Arg(arg: "h")]),
            body: body
        ))
    }

    // MARK: - Public embed API (used by KivyWidgetDesigner)

    /// Returns canvas init statements + optional update method for embedding inside
    /// an externally-generated Widget subclass (e.g. BoxLayout).
    /// The `super().__init__` call is **not** included in `initStmts`.
    public static func canvasEmbedData(
        for frame: CanvasFrameIR,
        scalable: Bool = false,
        smooth: SmoothOptions = .init()
    ) -> CanvasEmbedData {
        var refs: [GeneratedRef] = []
        let allStmts = initBodyFor(frame, scalable: scalable, smooth: smooth, refs: &refs)
        let initStmts = Array(allStmts.dropFirst())   // drop super().__init__(**kwargs)
        let updateMethod: Statement? = refs.isEmpty ? nil
            : updateCanvasFuncFor(frame: frame, refs: refs, scalable: scalable)

        // Scan canvas layers for required graphics names.
        var needsR = false, needsRR = false, needsE = false, needsT = false
        var needsG = false, needsCoreLabel = false
        var fontFamilies: [String] = []
        var imageRefs:    [String] = []

        func scan(_ items: [CanvasItem]) {
            for item in items {
                switch item {
                case .shape(let s):
                    switch s.kind {
                    case .rectangle:        needsR  = true
                    case .roundedRectangle: needsRR = true
                    case .ellipse:          needsE  = true
                    case .triangle:         needsT  = true
                    }
                case .group(let g):
                    needsG = true
                    scan(g.items)
                case .text(let t):
                    needsCoreLabel = true
                    needsR         = true
                    if !t.fontFamily.isEmpty, !fontFamilies.contains(t.fontFamily) {
                        fontFamilies.append(t.fontFamily)
                    }
                case .image(let img):
                    needsR = true
                    if !imageRefs.contains(img.imageRef) { imageRefs.append(img.imageRef) }
                case .svg:
                    needsR = true  // Svg extends Rectangle; Rectangle import is needed
                }
            }
        }
        for layer in frame.layers { scan(layer.items) }

        var names = ["Color"]
        if needsR  { names.append(smooth.rectangle        ? "SmoothRectangle"        : "Rectangle") }
        if needsRR { names.append(smooth.roundedRectangle ? "SmoothRoundedRectangle" : "RoundedRectangle") }
        if needsE  { names.append(smooth.ellipse          ? "SmoothEllipse"          : "Ellipse") }
        if needsT  { names.append(smooth.triangle         ? "SmoothTriangle"         : "Triangle") }
        if needsG  { names.append("InstructionGroup") }

        return CanvasEmbedData(
            initStmts:     initStmts,
            updateMethod:  updateMethod,
            graphicsNames: names,
            fontFamilies:  fontFamilies,
            imageRefs:     imageRefs,
            needsCoreLabel: needsCoreLabel
        )
    }
}
