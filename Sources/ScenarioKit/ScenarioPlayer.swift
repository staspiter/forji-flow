import Foundation
import XCTest

/// The shared generic scenario engine. A suite's UI-test bundle owns one thin
/// `XCTestCase` that builds a player, registers its `app:` verbs and launch
/// sugar, and calls `run(in:)`:
///
/// ```swift
/// final class UITests: XCTestCase {
///     func testScenario() throws {
///         let player = ScenarioPlayer()
///         player.configureLaunch = { app, step in
///             if let state = step.string("state") { app.launchArguments += ["-uitest-state", state] }
///         }
///         player.register("myMove") { app, step, ctx in … }   // {"do": "app:myMove"}
///         try player.run(in: self)
///     }
/// }
/// ```
///
/// The active scenario is delivered at run time via `TEST_RUNNER_APP_STEPS_JSON`
/// / `TEST_RUNNER_APP_SCENARIO`. With no scenario delivered — e.g. a plain
/// `xcodebuild test` compile gate — `run(in:)` throws `XCTSkip`, so the bundle
/// always compiles and the gate always passes.
///
/// `continueAfterFailure = false` — a half-driven flow yields a meaningless shot.
///
/// ### Core verbs
/// - `launch` — start the app. Core applies `env` (object) and `args` (array)
///   verbatim, then the suite's `configureLaunch` interprets its own sugar keys
///   (`state`, `autologin`, `photos`, …), then the app launches (`afterLaunch`
///   runs post-launch, e.g. to pin orientation). A later `launch` in the same
///   scenario relaunches (recovery/persistence legs).
/// - `tap`, `longPress` — hit the target.
/// - `type` — focus the target and type `text`, with a focus-verify retry
///   (a just-tapped field can drop characters). `afterType` runs after.
/// - `waitFor` / `waitGone` — assert the target appears / disappears.
/// - `assertEnabled` / `assertDisabled` — assert the target's enabled state.
/// - `drag` — press-drag between two identified elements (`fromId` → `toId`),
///   coordinate-based so a just-animated cell doesn't fail hittability.
/// - `dragReorder` — press-drag one list-reorder handle onto another
///   (`from`/`to`: 0-based index or label substring).
/// - `scrollTo` — swipe up until the target exists (`swipes` caps, default 6).
/// - `shot` — standalone screenshot (`as` is the label).
/// - `app:<name>` — dispatched to the suite's registered verb.
public final class ScenarioPlayer {

    public typealias Verb = (XCUIApplication, Step, ScenarioContext) throws -> Void

    /// How the pixels are grabbed. `.app` (default) shoots the app under test;
    /// `.screen` shoots the whole screen — needed when a landscape-locked window
    /// makes `app.screenshot()` mis-crop. Either way the image is re-rendered so
    /// orientation is baked into pixels (a no-op for ordinary portrait shots).
    public enum CaptureSource { case app, screen }

    public var timeout: TimeInterval = 25
    public var captureSource: CaptureSource = .app
    /// Interpret the suite's launch sugar into env/args. Runs BEFORE app.launch().
    public var configureLaunch: ((XCUIApplication, Step) -> Void)?
    /// Runs right after app.launch() (orientation pinning, foreground waits, …).
    public var afterLaunch: ((XCUIApplication, Step) -> Void)?
    /// Runs after a `type` lands (e.g. dismiss a return-key-less keyboard).
    public var afterType: ((XCUIApplication, Step) -> Void)?
    /// Runs just before every capture (freeze volatile UI).
    public var beforeShot: ((XCUIApplication, Step) -> Void)?
    /// Optional selector override; return nil to fall back to the default
    /// id → placeholderPrefix → contains → label resolution.
    public var resolveElement: ((XCUIApplication, Step) -> XCUIElement?)?

    private var verbs: [String: Verb] = [:]

    public init() {}

    /// Register an app-specific verb; steps invoke it as `{"do": "app:<name>"}`.
    public func register(_ name: String, _ verb: @escaping Verb) {
        verbs[name] = verb
    }

    /// Interpret the delivered scenario inside the given test case.
    public func run(in testCase: XCTestCase) throws {
        testCase.continueAfterFailure = false
        guard let (plan, scenario) = try ScenarioPlan.fromEnvironment() else {
            throw XCTSkip("No APP_STEPS_JSON / APP_SCENARIO in environment — compile-only gate")
        }
        let ctx = ScenarioContext(testCase: testCase, player: self, scenario: scenario)
        for step in plan.steps {
            try perform(step, ctx: ctx)
            if let label = step.shotLabel {
                ctx.capture(label, hero: step.hero, step: step)
            }
        }
    }

    // MARK: - Dispatch

    private func perform(_ step: Step, ctx: ScenarioContext) throws {
        let i = step.ordinal

        if step.action.hasPrefix("app:") {
            let name = String(step.action.dropFirst(4))
            guard let verb = verbs[name] else {
                XCTFail("unregistered app verb `\(step.action)` (step \(i))")
                throw StepError.unknownAction(step.action, ordinal: i)
            }
            try verb(try ctx.requireApp(step), step, ctx)
            return
        }

        switch step.action {
        case "launch":
            let app = XCUIApplication()
            if let env = step.object("env") {
                for (k, v) in env { app.launchEnvironment[k] = "\(v)" }
            }
            if let args = step.stringArray("args") {
                app.launchArguments += args
            }
            configureLaunch?(app, step)
            app.launch()
            afterLaunch?(app, step)
            ctx.app = app

        case "tap":
            let el = try ctx.require(step, what: "tap target")
            el.tap()

        case "longPress":
            let el = try ctx.require(step, what: "longPress target")
            el.press(forDuration: 1.0)

        case "type":
            guard let text = step.text else {
                XCTFail("type: missing text (step \(i))")
                throw StepError.missingField("type", "text", ordinal: i)
            }
            let el = try ctx.require(step, what: "type target")
            // Tap then type, with retry: a just-tapped field may lack focus when
            // typeText fires and silently drop characters.
            el.tap()
            for attempt in 0..<5 {
                el.typeText(text)
                let value = el.value as? String ?? ""
                if value == text { break }
                if attempt < 4 {
                    el.tap(); el.tap(); el.tap() // select all
                    el.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + text.count))
                }
            }
            afterType?(try ctx.requireApp(step), step)

        case "waitFor":
            let el = try ctx.resolved(step, what: "waitFor target")
            XCTAssertTrue(el.waitForExistence(timeout: stepTimeout(step)),
                          "waitFor: not found (step \(i)): \(describe(step))")

        case "waitGone":
            let el = try ctx.resolved(step, what: "waitGone target")
            let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: el)
            XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: stepTimeout(step)), .completed,
                           "waitGone: still present (step \(i)): \(describe(step))")

        case "assertEnabled", "assertDisabled":
            // Resolve the BUTTON, not any wrapper: a disabled button reports
            // isEnabled correctly, but an enclosing "Any" element can still read
            // enabled.
            let app = try ctx.requireApp(step)
            let el = step.id.map { app.buttons[$0] } ?? ctx.element(for: step)
            guard let target = el else {
                XCTFail("assert target has no selector (step \(i))")
                throw StepError.missingSelector(step.action, ordinal: i)
            }
            XCTAssertTrue(target.waitForExistence(timeout: timeout), "assert: target not found (step \(i))")
            let want = step.action == "assertEnabled"
            XCTAssertEqual(target.isEnabled, want,
                           "\(step.action): expected enabled=\(want) (step \(i)): \(describe(step))")

        case "drag":
            // {"do":"drag","fromId":…,"toId":…} — press-and-drag between two
            // identified elements. Coordinate-based: element-based press demands
            // hittability, which a just-animated cell can transiently lack.
            let app = try ctx.requireApp(step)
            guard let fromId = step.string("fromId"), let toId = step.string("toId") else {
                XCTFail("drag: needs `fromId` and `toId` (step \(i))")
                throw StepError.missingField("drag", "fromId/toId", ordinal: i)
            }
            let from = app.descendants(matching: .any).matching(identifier: fromId).firstMatch
            let to = app.descendants(matching: .any).matching(identifier: toId).firstMatch
            XCTAssertTrue(from.waitForExistence(timeout: timeout), "drag: source not found (step \(i))")
            XCTAssertTrue(to.waitForExistence(timeout: timeout), "drag: destination not found (step \(i))")
            let center = CGVector(dx: 0.5, dy: 0.5)
            from.coordinate(withNormalizedOffset: center)
                .press(forDuration: 1.2, thenDragTo: to.coordinate(withNormalizedOffset: center))

        case "dragReorder":
            // Press-drag one reorder handle onto another. `from`/`to` index the
            // list of "Reorder …" grabbers (0-based) when numeric, else match a
            // handle whose label contains the string. The grabbers only exist
            // while the List is in edit mode with a live ForEach — the tripwire
            // for the ways a list's reorder support goes silently dead.
            let app = try ctx.requireApp(step)
            guard let from = step.string("from"), let to = step.string("to") else {
                XCTFail("dragReorder: needs `from` and `to` (step \(i))")
                throw StepError.missingField("dragReorder", "from/to", ordinal: i)
            }
            let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Reorder'"))
            XCTAssertTrue(handles.firstMatch.waitForExistence(timeout: timeout),
                          "dragReorder: no reorder handles — is the list in edit mode? (step \(i))")
            reorderHandle(handles, from).press(forDuration: 0.6, thenDragTo: reorderHandle(handles, to))

        case "scrollTo":
            // Swipe up until the target materializes — a lazy list only renders
            // the cells it is showing, so a below-the-fold element genuinely does
            // not exist until scrolled into view.
            let app = try ctx.requireApp(step)
            let el = try ctx.resolved(step, what: "scrollTo target")
            let swipes = step.int("swipes") ?? 6
            for _ in 0..<swipes {
                if el.exists { break }
                app.swipeUp()
            }
            XCTAssertTrue(el.waitForExistence(timeout: 3),
                          "scrollTo: never found after \(swipes) swipes (step \(i)): \(describe(step))")

        case "shot":
            break // captured by the shared post-step hook

        default:
            XCTFail("Unknown step action `\(step.action)` (step \(i))")
            throw StepError.unknownAction(step.action, ordinal: i)
        }
    }

    /// A step's own `timeout` (milliseconds, matching the JS player) overrides
    /// the player default for its wait.
    private func stepTimeout(_ step: Step) -> TimeInterval {
        if let ms = step.int("timeout") { return TimeInterval(ms) / 1000 }
        return timeout
    }

    private func reorderHandle(_ handles: XCUIElementQuery, _ ref: String) -> XCUIElement {
        if let idx = Int(ref) { return handles.element(boundBy: idx) }
        return handles.matching(NSPredicate(format: "label CONTAINS[c] %@", ref)).firstMatch
    }

    private func describe(_ step: Step) -> String {
        "id=\(step.id ?? "") label=\(step.label ?? "") contains=\(step.contains ?? "")"
    }
}

/// Everything an app verb needs: the shared selector resolution, assertion-backed
/// element requirement, and the capture pipeline.
public final class ScenarioContext {
    public let scenario: String
    public unowned let testCase: XCTestCase
    /// The app under test — set by `launch`, replaced by a relaunch.
    public internal(set) var app: XCUIApplication?

    private unowned let player: ScenarioPlayer
    public var timeout: TimeInterval { player.timeout }

    init(testCase: XCTestCase, player: ScenarioPlayer, scenario: String) {
        self.testCase = testCase
        self.player = player
        self.scenario = scenario
    }

    /// Shared selector resolution across any element type (so a multiline text
    /// field that surfaces as a text view still matches by id). Order:
    /// suite override → id → placeholderPrefix → contains → label (`text` as the
    /// label fallback for selector-less waits).
    public func element(for step: Step) -> XCUIElement? {
        guard let app else { return nil }
        if let custom = player.resolveElement?(app, step) { return custom }
        if let id = step.id {
            return app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        if let prefix = step.placeholderPrefix {
            return app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH[c] %@", prefix)).firstMatch
        }
        if let contains = step.contains {
            return app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
        }
        if let label = step.label ?? step.text {
            return app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
        }
        return nil
    }

    /// Resolve or fail the test with a missing-selector message.
    public func resolved(_ step: Step, what: String) throws -> XCUIElement {
        guard let el = element(for: step) else {
            XCTFail("\(what) has no selector (id/label/contains/placeholderPrefix) at step \(step.ordinal)")
            throw StepError.missingSelector(step.action, ordinal: step.ordinal)
        }
        return el
    }

    /// Resolve AND assert existence — the standard precondition for interaction.
    public func require(_ step: Step, what: String) throws -> XCUIElement {
        let el = try resolved(step, what: what)
        XCTAssertTrue(el.waitForExistence(timeout: timeout), "\(what) not found (step \(step.ordinal))")
        return el
    }

    func requireApp(_ step: Step) throws -> XCUIApplication {
        guard let app else {
            XCTFail("step \(step.ordinal) (`\(step.action)`) before any `launch`")
            throw StepError.parse("step \(step.ordinal): no app launched")
        }
        return app
    }

    /// Capture a screenshot: attach to the result bundle and, when
    /// `UITEST_SHOTS_DIR` is set (via `TEST_RUNNER_UITEST_SHOTS_DIR`), write it
    /// as `<scenario>-<label>.png` there; a hero shot also lands as `main.png`.
    public func capture(_ label: String, hero: Bool = false, step: Step? = nil) {
        if let app, let step { player.beforeShot?(app, step) }
        ScenarioCapture.capture(app: app, source: player.captureSource,
                                scenario: scenario, label: label, hero: hero, testCase: testCase)
    }
}
