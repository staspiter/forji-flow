import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif

/// The shared screenshot pipeline: grab pixels, bake orientation, attach to the
/// result bundle, and write PNGs into the suite's `shots/` dir.
enum ScenarioCapture {

    /// Attach `<scenario>/<label>` to the result bundle (`.keepAlways`) and, when
    /// `UITEST_SHOTS_DIR` is set, write `<scenario>-<label>.png` there — plus
    /// `main.png` when this is the suite's hero shot.
    static func capture(app: XCUIApplication?, source: ScenarioPlayer.CaptureSource,
                        scenario: String, label: String, hero: Bool, testCase: XCTestCase) {
        let screenshot: XCUIScreenshot
        switch source {
        case .app: screenshot = app?.screenshot() ?? XCUIScreen.main.screenshot()
        case .screen: screenshot = XCUIScreen.main.screenshot()
        }

        let png = renderedPNG(screenshot)

        let attachment: XCTAttachment
        #if canImport(UIKit)
        attachment = XCTAttachment(image: rendered(screenshot.image))
        #else
        attachment = XCTAttachment(screenshot: screenshot)
        #endif
        attachment.name = "\(scenario)/\(label)"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)

        guard let dir = ProcessInfo.processInfo.environment["UITEST_SHOTS_DIR"], let png else { return }
        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try? png.write(to: dirURL.appendingPathComponent("\(scenario)-\(label).png"))
        if hero {
            try? png.write(to: dirURL.appendingPathComponent("main.png"))
        }
    }

    #if canImport(UIKit)
    /// Re-render through a fresh renderer: XCTest expresses a rotated screen as
    /// UIImage ORIENTATION metadata, which `pngData()` ignores (writing sideways
    /// pixels) — drawing bakes the orientation into pixels. A no-op for ordinary
    /// portrait shots.
    private static func rendered(_ raw: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = raw.scale
        return UIGraphicsImageRenderer(size: raw.size, format: format).image { _ in
            raw.draw(in: CGRect(origin: .zero, size: raw.size))
        }
    }

    private static func renderedPNG(_ screenshot: XCUIScreenshot) -> Data? {
        rendered(screenshot.image).pngData()
    }
    #else
    private static func renderedPNG(_ screenshot: XCUIScreenshot) -> Data? {
        screenshot.pngRepresentation
    }
    #endif
}
