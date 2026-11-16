# OrbitBar: agent instructions

A macOS menu bar app (SwiftUI + AppKit, Swift package, macOS 14+) for the tasks of an
[Orbit](https://github.com/coollabsio/orbit) instance. The user-facing overview is in `README.md`.

## Build, test, install

```sh
swift build                       # debug build
swift test                        # unit tests (Tests/OrbitBarTests)
scripts/build-app.sh              # release build → build/OrbitBar.app (universal, signed with your Apple Development identity, else ad-hoc)
scripts/build-app.sh --install    # also replaces /Applications/OrbitBar.app and LAUNCHES it
scripts/release.sh                # build + build/OrbitBar <version>.dmg (Developer ID signing and notarization are env-driven, see README)
```

Run `swift test` after every change. A task is done when the debug build has no errors and the tests pass.

## The person's machine: do not take focus

The person uses this Mac while you work, often with a full-screen app or video.

- To install without launching: `scripts/build-app.sh && rm -rf "/Applications/OrbitBar.app" && cp -R "build/OrbitBar.app" /Applications/`.
- Check views offscreen first: `ORBITBAR_SNAPSHOT=<dir> .build/debug/OrbitBar` writes a PNG of each screen with demo
  data and quits, without taking focus. AppKit controls (pickers, text fields) come out as blank boxes, so it shows
  layout only. When you need a real screenshot, ask, then use `screencapture -x -R<x,y,w,h>` on the panel's area
  only, and quit the app as soon as it is captured.
- Do not sign in to the person's Orbit server or write to it. Use demo mode.

Debug-only switches (in `Support/Demo.swift`, compiled out of release builds):
`ORBITBAR_DEMO=1` (sample data, no server), `ORBITBAR_OPEN=1` (open the panel at launch),
`ORBITBAR_SCREEN=editor|new|help|account|picker`, `ORBITBAR_SNAPSHOT=<dir>`.

## Layout

| Path | What |
|---|---|
| `OrbitBarApp.swift` | Entry point, `AppDelegate` (global hotkeys, hidden Edit menu), `PanelController` (status item, `NSPopover`, key-down monitor) |
| `AppModel.swift` | All state and actions (`@Observable`, `@MainActor`): session, data, filters, task page drafts, saving |
| `KeyboardRouter.swift` | Every in-panel shortcut (`AppModel.handleKey`) and the shortcut lists the Help screen shows |
| `API/OrbitClient.swift`, `API/Models.swift` | Orbit HTTP client and records |
| `Support/` | Keychain + prefs, Carbon hotkeys, provider sign-in (PKCE), demo data and snapshots |
| `Views/` | Sign-in, task list, task page (`TaskDetailView`), status picker, Markdown theme and image loading |

## Orbit API

- The app uses Orbit's **internal** `/api/v1` API, as Orbit's mobile app does. The public API only allows one
  workspace per token. The internal API can change with any Orbit release.
- To check how an endpoint behaves, read Orbit's source: the OpenAPI document is
  `packages/api/src/generated/openapi.json`, the mobile client is `apps/mobile/src/data/orbit.ts`, and the server is
  `apps/server/src` (Rust).
- Every request sends `X-Orbit-Contract: orbit-api-v1`. URLSession sends no `Origin`, so Orbit treats the app as a
  native client: sign-in returns `session_token` in the body, and later requests send it as `Authorization: Bearer`.
  `OrbitClient.fileData` sends that token only to the signed-in server's own host.
- Task updates (`PATCH`) and deletes need `expected_version` equal to the task's **current** version, or the server
  answers 409. In `AppModel`:
  - `replace(_:)` never stores an older copy of a task over a newer one, and task list reloads merge the same way.
  - Quick list changes go through `quickUpdate`, which queues the writes of each task and sends each with the
    newest version.
  - On the task page, `commitDraft` saves one change at a time and retries after a 409.
  Keep these rules for any new write path.
- In an update body, an absent key means "unchanged" and `NSNull()` means "clear" (for example `due_at`). Bodies are
  `JSONBody` dictionaries, not `Encodable` structs, for this reason.
- Statuses belong to projects. Their `category` is `unstarted`, `started`, `completed`, `cancelled` or `duplicate`.
  Priorities are `none`, `low`, `medium`, `high`, `urgent`.
- Description images are relative `/api/...` attachment URLs that need the session (`AuthorizedImageProvider`).

## Pitfalls that already caused bugs

- **Bindings into optional state:** never force-unwrap model state in a `Binding` getter (`model.draft!`). Closing a
  page clears the state while SwiftUI still reads the binding once. Fall back to the last rendered value
  (see `TaskPage.draft`).
- **Observation:** a value read only inside a `Binding`'s `get` closure is not tracked. Read it in the view's body and
  capture it (see `View.statusPicker`), or the view never updates.
- **Keyboard:** the panel's keys go through one local monitor in `PanelController` and then `AppModel.handleKey`.
  Leave ⌘C/⌘V/⌘A/⌘X/⌘Z alone; they reach text fields through the hidden Edit menu (`installEditMenu`), which a menu
  bar app needs. Do not take a key while a text field is being edited unless it is clearly the panel's own (esc,
  ↑↓ in search, ⌘⏎). Nested popovers (the status picker) have their own window. The monitor routes their keys
  while `statusPicker` is set.
- **Focus:** the list and existing task pages open with no focused text field, so single-key shortcuts work. Closing
  the panel hands focus back to the previous app (`NSApp.hide`), but not while signed out, because a provider
  sign-in window may be open.

## Conventions

- When you add or change a shortcut, update `Shortcuts` in `KeyboardRouter.swift` (the Help screen) and the table in
  `README.md`.
- Keep the panel compact (`RootView.width` × `RootView.height`) and use native macOS controls. Put help text in
  `.help(...)` tooltips, not in paragraphs on the page.
- New pure logic (request bodies, parsing, PKCE, sorting) gets a test in `Tests/OrbitBarTests`.
- The project uses Swift 5 language mode (`swiftLanguageMode(.v5)`). Helpers that tests call from outside the main
  actor must be `nonisolated`.
