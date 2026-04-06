


# Phase 1 - Seperation between how FigmaNode is used in Widget and Canvas.

Figma2Kv/Sources/KivyCanvasDesigner

primary job would now only to process all that is inside
* <canvas>
* <canvas.before>
* <canvas.after>

now we would need Figma2Kv/Sources/KivyWidgetDesigner

here our original rules for when we did kv lang, should apply and use orientation ect for detecting if Frame or Component needs to be Widget/BoxLayout/Grid

# Phase 2 - combine Figma page with associated python .py file

MyPage<filename.py>
MyPage<relative-path/filename.py>

which also brings us to next step of FigmaVaporServer
that where we execute it, will also be our working folder
and it now needs to see if pyproject.toml is present

we can later use pyproject.toml to define some keys/values for allowing more information
that server can utilize and consider its way of behaving..

# Phase 3 - Utilize more Datamodel usage / thinking for updating Widget/Canvas inside

by using the EventDispatcher class, we can input different datamodels and make the canvas update part work more smooth and easy to update..

some experiments with SwiftyKvLang and PySwiftAst have already been done here

https://github.com/Py-Swift/PySwiftKitDemoPlugin/blob/master/Sources/PyDataModels/KivyModelGenerator.swift
https://github.com/Py-Swift/PySwiftKitDemoPlugin/blob/master/Sources/PyDataModels/PyDataModelGenerator.swift
https://github.com/Py-Swift/PySwiftKitDemoPlugin/blob/master/Sources/PySwiftTypeConverter/PythonTypeConverter.swift

ofc we wont be needing to use kv part for this, should more work like the Figma json export does the kv part and combines with the matching python file, and merges the PySwiftAst together before creating the output..
