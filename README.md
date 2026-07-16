# forji-uitests

The shared declarative UI-testing tool behind the `std/test-ui` forji contract
(https://forji.ai/std/test-ui/): scenarios are **data** (`*.steps.json`, see
[STEPS.md](STEPS.md)), a generic player drives the really-running app, and
screenshots land in `shots/` with `shots/main.png` as the node-card hero.

One vocabulary, one player per platform — projects register their app-specific
`app:` verbs instead of forking the engine.

## What's here

| path | what |
|---|---|
| `Sources/ScenarioKit/` | Swift package — the native (XCUITest) player |
| `js/` | the browser player (Playwright library API) |
| `lint/lint-steps.mjs` | zero-dependency offline lint — every suite's `test` gate |
| `STEPS.md` | the canonical steps.json vocabulary |

## Consuming — native iOS

Add the local package to the UI-test target (xcodegen `project.yml`):

```yaml
packages:
  ScenarioKit:
    path: ../path/to/forji-uitests
targets:
  MyAppUITests:
    dependencies:
      - package: ScenarioKit
```

One thin test case per suite:

```swift
import ScenarioKit
import XCTest

final class UITests: XCTestCase {
    func testScenario() throws {
        let player = ScenarioPlayer()
        player.configureLaunch = { app, step in
            if let state = step.string("state") { app.launchArguments += ["-uitest-state", state] }
        }
        player.register("enterRoll") { app, step, ctx in /* app move */ }
        try player.run(in: self)
    }
}
```

The runner delivers the scenario via `TEST_RUNNER_APP_SCENARIO` /
`TEST_RUNNER_APP_STEPS_JSON` and the output dir via
`TEST_RUNNER_UITEST_SHOTS_DIR`; with nothing delivered the test `XCTSkip`s, so a
plain `xcodebuild test` stays a compile-only gate. Hooks for app divergence:
`configureLaunch`, `afterLaunch`, `afterType`, `beforeShot`, `resolveElement`,
`captureSource` (`.screen` for landscape-locked windows).

Raw (non-xcodegen) projects add an `XCLocalSwiftPackageReference` to the
project and the `ScenarioKit` product to the UI-test target.

## Consuming — web

```sh
FORJI_UITESTS=/path/to/forji-uitests
node "$FORJI_UITESTS/js/run.mjs" --suite . [scenario...]
```

The suite provides an `app.mjs` (launch/auth/backend setup, `app:` verbs,
optional selector override and pre-shot freeze); playwright comes from the
consuming project (any `node_modules` on `NODE_PATH`).

## The gate

```sh
node lint/lint-steps.mjs <suite-dir>    # every suite's offline `test` process
node lint/self-test.mjs                 # this repo's own verify
```

## Versioning

Consume by local path while everything lives on one machine; switch the package
`path:` to a `url:` + tag when this repo gets a published home.
