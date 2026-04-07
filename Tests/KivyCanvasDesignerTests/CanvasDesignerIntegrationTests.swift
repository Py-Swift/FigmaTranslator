import XCTest
import KivyCanvasDesigner

final class CanvasDesignerIntegrationTests: XCTestCase {

    /// Regression test: test_design_0.json is a real Figma export that was causing
    /// a server-side parse error. This test ensures the canvas-mode generator can
    /// fully parse and translate it without throwing.
    func testDesign0ParsesAndGeneratesWithoutError() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "test_design_0", withExtension: "json"),
            "test_design_0.json resource not found in test bundle"
        )
        let json = try String(contentsOf: url, encoding: .utf8)
        let python = try CanvasDesigner.generate(json: json)
        XCTAssertFalse(python.isEmpty, "Expected non-empty Python output from test_design_0.json")
    }
}
