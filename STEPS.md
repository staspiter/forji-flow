# The steps.json vocabulary

The single source of truth for declarative UI scenarios. A scenario is a JSON
file of steps a generic player interprets against the really-running app — a
new flow is a new file, never new test code. The same vocabulary drives every
platform player in this repo (native via `Sources/ScenarioKit`, browser via
`js/`), so a scenario reads the same everywhere.

## Shape

One file per scenario, named `<scenario>.steps.json`:

```json
{
  "scenario": "signin",
  "steps": [
    { "do": "launch", "state": "signedOut" },
    { "do": "type",   "id": "signin.nickname", "text": "demo" },
    { "do": "tap",    "label": "Continue" },
    { "do": "waitFor","contains": "Welcome", "shot": "01-welcome", "poster": true }
  ]
}
```

- `scenario` must match the filename.
- `steps` is an ordered list; each step is `{"do": "<verb>", ...fields}`.
- `launch` comes before any core interaction verb (backend-setup `app:` steps
  may precede it).
- A failed step fails the whole scenario — a half-driven flow yields a
  meaningless shot.

## Selectors

Interaction verbs take **exactly one** of:

| key | matches |
|---|---|
| `id` | the element's stable automation identifier |
| `label` | visible label, exact (case-insensitive) |
| `contains` | visible label, substring |
| `placeholderPrefix` | a text field by placeholder prefix |

## Core verbs

| verb | fields | meaning |
|---|---|---|
| `launch` | `env` (object), `args` (array), app sugar | start (or relaunch) the app in a hermetic state. `env`/`args` apply verbatim; sugar keys (`state`, `autologin`, `photos`, `stack`, …) are interpreted by the suite's launch hook |
| `tap` | selector | tap the target |
| `longPress` | selector | press ~1s |
| `type` | selector, `text` | focus and type, focus-verify retried |
| `waitFor` | selector, `timeout` (ms, optional) | assert the target appears |
| `waitGone` | selector, `timeout` (ms, optional) | assert the target disappears |
| `assertEnabled` / `assertDisabled` | selector | assert the target's enabled state |
| `drag` | `fromId`, `toId` | press-drag between two identified elements |
| `dragReorder` | `from`, `to` | drag one list-reorder handle onto another (0-based index or label substring) |
| `scrollTo` | selector, `swipes` (default 6) | scroll until the target exists |
| `shot` | `as` | standalone screenshot |

## Shots

- `"shot": "NN-label"` on any step captures a screenshot **after** that step
  succeeds; `{"do": "shot", "as": "NN-label"}` captures standalone.
- Labels are `NN-label` (e.g. `01-lobby`) and unique per scenario — shots file
  in order as `shots/<scenario>-NN-label.png`.
- Exactly **one** shot per suite carries `"poster": true` — it is also written as
  `shots/main.png`, the image the suite's node card shows.

## App-specific verbs: the `app:` namespace

Core verbs are fixed. Anything app-specific — a game move, a bot action, a
backend assertion — is a registered verb invoked as:

```json
{ "do": "app:enterRoll", "diceString": "230000" }
```

The suite registers `enterRoll` with its player and reads its own fields from
the step. The prefix keeps portability visible in the JSON and lets the lint
validate core verbs strictly while passing `app:*` through. **A missing core
capability is a change to this repo, not a local fork of the player.**

## Hermetic launches

Scenarios must be deterministic and self-contained: `launch` selects a known
app state (stubbed backend, seeded fixtures, demo mode) via sugar keys the
suite's launch hook interprets. Never depend on leftover state from a previous
scenario.

## Lint

`node lint/lint-steps.mjs <suite-dir>` is the offline gate every suite exposes
as its `test` process: schema, verbs, selectors, shot labels, poster count. No
device, no browser, no dependencies.
