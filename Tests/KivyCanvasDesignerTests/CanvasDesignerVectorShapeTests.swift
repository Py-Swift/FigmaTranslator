import XCTest
import KivyCanvasDesigner

final class CanvasDesignerVectorShapeTests: XCTestCase {

    func testRectangleLikeVectorUsesNativeRectangleInstruction() throws {
        let json = #"""
        [
          {
            "name": "Test:<RelativeLayout>",
            "type": "FRAME",
            "absoluteBoundingBox": { "x": 0, "y": 0, "width": 400, "height": 300 },
            "children": [
              {
                "name": "<canvas>",
                "type": "GROUP",
                "children": [
                  {
                    "id": "70:194",
                    "name": "Rectangle 2",
                    "type": "VECTOR",
                    "absoluteBoundingBox": { "x": 10, "y": 20, "width": 100, "height": 50 },
                    "fills": [
                      {
                        "type": "SOLID",
                        "visible": true,
                        "opacity": 1,
                        "color": { "r": 1, "g": 0, "b": 0 }
                      }
                    ],
                    "fillGeometry": [
                      {
                        "windingRule": "NONZERO",
                        "path": "M 0 0 L 100 0 L 100 50 L 0 50 L 0 0 Z"
                      }
                    ]
                  }
                ]
              }
            ]
          }
        ]
        """#

        let python = try CanvasDesigner.generate(json: json)

        XCTAssertTrue(python.contains("Rectangle(pos=(10, 230), size=(100, 50))"))
        XCTAssertFalse(python.contains("Svg(10, 230, 100, 50"))
    }

    func testNonRectangularVectorStillFallsBackToSvg() throws {
        let json = #"""
        [
          {
            "name": "Test:<RelativeLayout>",
            "type": "FRAME",
            "absoluteBoundingBox": { "x": 0, "y": 0, "width": 400, "height": 300 },
            "children": [
              {
                "name": "<canvas>",
                "type": "GROUP",
                "children": [
                  {
                    "id": "70:195",
                    "name": "Triangle Vector",
                    "type": "VECTOR",
                    "absoluteBoundingBox": { "x": 10, "y": 20, "width": 100, "height": 100 },
                    "fills": [
                      {
                        "type": "SOLID",
                        "visible": true,
                        "opacity": 1,
                        "color": { "r": 0, "g": 1, "b": 0 }
                      }
                    ],
                    "fillGeometry": [
                      {
                        "windingRule": "NONZERO",
                        "path": "M 50 0 L 100 100 L 0 100 Z"
                      }
                    ]
                  }
                ]
              }
            ]
          }
        ]
        """#

        let python = try CanvasDesigner.generate(json: json)

        XCTAssertTrue(python.contains("Svg(10, 180, 100, 100, SVG_70_195)"))
    }
}