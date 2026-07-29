import Foundation

/// The parsed `steps.json` for one scenario — the shared schema every suite is
/// written against (canonical doc: STEPS.md at the repo root).
///
/// A scenario is a declarative list of steps a generic player interprets and
/// drives the app with — no per-scenario test code. A new flow is a JSON file:
///
/// ```json
/// {
///   "scenario": "signin",
///   "steps": [
///     { "do": "launch", "state": "signedOut" },
///     { "do": "type",   "id": "signin.nickname", "text": "demo" },
///     { "do": "tap",    "id": "signin.continue" },
///     { "do": "waitFor","label": "Welcome", "shot": "01-welcome", "poster": true }
///   ]
/// }
/// ```
///
/// A `shot: "NN-label"` on any step (or a standalone `{ "do": "shot", "as": … }`)
/// captures a screenshot after that step; `"poster": true` additionally copies it
/// to `shots/main.png` — the node-card image.
///
/// Core actions live in `ScenarioPlayer`; app-specific moves use the `app:`
/// namespace (`{ "do": "app:enterRoll", … }`) and are registered by the suite's
/// thin test case — extra fields for those verbs are read via `Step.raw` and the
/// typed accessors (`string(_:)`, `bool(_:)`, …).
public struct ScenarioPlan {
    public let scenario: String?
    public let steps: [Step]

    /// Reads the scenario delivered by the runner: `TEST_RUNNER_APP_SCENARIO` /
    /// `TEST_RUNNER_APP_STEPS_JSON` (xcodebuild forwards each `TEST_RUNNER_<VAR>`
    /// into the test process with the prefix stripped). Returns nil when absent —
    /// the caller should `XCTSkip` so a plain `xcodebuild test` stays a
    /// compile-only gate.
    public static func fromEnvironment() throws -> (plan: ScenarioPlan, scenario: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let stepsJSON = env["APP_STEPS_JSON"], let scenarioEnv = env["APP_SCENARIO"] else {
            return nil
        }
        let plan = try parse(stepsJSON)
        return (plan, plan.scenario ?? scenarioEnv)
    }

    /// Parse a `steps.json` string. Accepts the object form
    /// (`{ "scenario": …, "steps": [ … ] }`) or a bare top-level array of steps.
    public static func parse(_ json: String) throws -> ScenarioPlan {
        guard let data = json.data(using: .utf8) else {
            throw StepError.parse("steps JSON was not valid UTF-8")
        }
        let top: Any
        do {
            top = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw StepError.parse("steps JSON did not parse: \(error.localizedDescription)")
        }

        var scenario: String?
        let rawSteps: [Any]
        if let obj = top as? [String: Any] {
            scenario = obj["scenario"] as? String
            guard let arr = obj["steps"] as? [Any] else {
                throw StepError.parse("steps JSON object is missing a `steps` array")
            }
            rawSteps = arr
        } else if let arr = top as? [Any] {
            rawSteps = arr
        } else {
            throw StepError.parse("steps JSON must be an object with `steps` or a bare array")
        }

        let steps = try rawSteps.enumerated().map { i, raw -> Step in
            guard let dict = raw as? [String: Any] else {
                throw StepError.parse("step \(i + 1) is not a JSON object")
            }
            return try Step(dict: dict, ordinal: i + 1)
        }
        return ScenarioPlan(scenario: scenario, steps: steps)
    }
}

/// One step from a scenario's `steps.json`. The common fields are typed; the
/// full JSON object stays available in `raw` so app verbs can read their own
/// fields without the core schema growing per app.
public struct Step {
    public let action: String
    /// Selector — a step uses at most one of these.
    public let id: String?
    public let label: String?
    public let contains: String?
    public let placeholderPrefix: String?
    /// For `type`: the text to type.
    public let text: String?
    /// The screenshot label this step carries, if any: `shot` (inline) or `as`
    /// (on a standalone `{ "do": "shot" }`). `NN-label` so shots file ordered.
    public let shotLabel: String?
    /// This step's shot is the suite poster — also written as `shots/main.png`.
    public let poster: Bool
    /// 1-based position in the scenario, for failure messages.
    public let ordinal: Int
    /// The full JSON object — app verbs and launch hooks read extra fields here.
    public let raw: [String: Any]

    public init(dict: [String: Any], ordinal: Int) throws {
        guard let action = dict["do"] as? String, !action.isEmpty else {
            throw StepError.parse("step \(ordinal) is missing a `do` action")
        }
        self.action = action
        self.id = dict["id"] as? String
        self.label = dict["label"] as? String
        self.contains = dict["contains"] as? String
        self.placeholderPrefix = dict["placeholderPrefix"] as? String
        self.text = dict["text"] as? String
        self.shotLabel = (dict["shot"] as? String) ?? (dict["as"] as? String)
        self.poster = dict["poster"] as? Bool ?? false
        self.ordinal = ordinal
        self.raw = dict
    }

    // MARK: Typed accessors over `raw` for app verbs / launch sugar.

    public func string(_ key: String) -> String? { raw[key] as? String }
    public func bool(_ key: String, default def: Bool = false) -> Bool { raw[key] as? Bool ?? def }
    public func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue }
    public func double(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }
    public func object(_ key: String) -> [String: Any]? { raw[key] as? [String: Any] }
    public func stringArray(_ key: String) -> [String]? { raw[key] as? [String] }
}

/// A step-vocabulary error — surfaces with a clear message so a scenario author
/// sees exactly what their `steps.json` got wrong.
public enum StepError: Error, CustomStringConvertible {
    case parse(String)
    case unknownAction(String, ordinal: Int)
    case missingField(String, String, ordinal: Int)
    case missingSelector(String, ordinal: Int)

    public var description: String {
        switch self {
        case .parse(let m): return m
        case .unknownAction(let a, let i):
            return "unknown step action `\(a)` (step \(i)) — core verbs are fixed; app moves use `app:<name>` registered by the suite"
        case .missingField(let a, let f, let i): return "step `\(a)` requires a `\(f)` field (step \(i))"
        case .missingSelector(let a, let i):
            return "step `\(a)` needs a target (`id`, `label`, `contains`, or `placeholderPrefix`) (step \(i))"
        }
    }
}
