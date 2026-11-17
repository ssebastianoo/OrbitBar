# OrbitBar

A macOS menu bar app for [Orbit](https://github.com/coollabsio/orbit) tasks.

- Connect any Orbit instance (self-hosted or cloud) with email + password, two-factor codes, or Google / GitHub / SSO.
- Your tasks, grouped by status, filtered by workspace, project, "My tasks / All tasks", done, and search.
- Create, edit, complete, re-prioritize, assign, and trash tasks.
- Fully keyboard-driven, with global shortcuts.

<img width="519" height="670" alt="image" src="https://github.com/user-attachments/assets/678908a2-1c64-4671-acf3-e8fc1deab61d" />


## Build & install

Requires macOS 14+ and Xcode / Swift 6.

```sh
scripts/build-app.sh            # → build/OrbitBar.app (universal, signed with your Apple Development identity, else ad-hoc)
scripts/build-app.sh --install  # also copies it to /Applications and launches it
swift test                      # unit tests
```

## Release

```sh
scripts/release.sh              # → build/OrbitBar <version>.dmg (drag to Applications)
```

Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist` first.

Or let GitHub Actions do it: `git tag v0.2.0 && git push origin v0.2.0` runs `.github/workflows/release.yml`, which tests,
builds, and attaches the dmg to a GitHub release. The version comes from the tag. To sign with a stable identity, set the
`MACOS_CERT_P12` (base64 of an exported `.p12`) and `MACOS_CERT_PASSWORD` repository secrets. Without them the app is
signed ad-hoc. The workflow file explains how to export the certificate.

The app is not notarized (that needs a paid Apple Developer account), so on first launch macOS shows a warning. Tell
people to do one of these:

- macOS 14: right-click the app → Open → Open.
- macOS 15+: try to open it, then System Settings → Privacy & Security → Open Anyway.
- Any version: `xattr -dr com.apple.quarantine "/Applications/OrbitBar.app"`.

If you ever get a Developer ID certificate, `scripts/release.sh` finds it (or set `ORBITBAR_SIGN_IDENTITY`) and signs with
the hardened runtime. Store notary credentials once with
`xcrun notarytool store-credentials <profile> --apple-id <you> --team-id <TEAMID>` and run
`ORBITBAR_NOTARY_PROFILE=<profile> scripts/release.sh` to notarize too, which removes the warning.

During development, `swift run` launches it directly. Debug-only switches: `ORBITBAR_DEMO=1` loads sample data without a server,
`ORBITBAR_OPEN=1` opens the panel at launch, and `ORBITBAR_SCREEN=editor|new|help|account` picks the screen it opens on.

## Keyboard

| Anywhere | |
|---|---|
| ⌥⌘O | Show / hide the panel |
| ⌥⌘N | New task |

| Task list | |
|---|---|
| ↑ ↓ / j k | Move selection |
| ⏎ / e | Edit |
| n, ⌘N | New task |
| x / space | Toggle done |
| s / p / a | Next status / next priority / assign or unassign me |
| o, ⌘O / c | Open in browser / copy link |
| ⌫ | Move to trash (⏎ confirms) |
| / , ⌘F | Search (↑ ↓ ⏎ work while typing; esc clears) |
| m / h | My ↔ all tasks / show or hide done |
| [ ] | Previous / next project |
| ⌘[ ⌘], ⌘1…9 | Switch workspace |
| r, ⌘R | Refresh |
| ⌘, / ? | Account / shortcut help |

In the editor: ⌘⏎ saves, esc cancels, and ⌘⌫ moves the task to the trash. ⌘K opens the status picker. Right-click the menu bar icon to toggle Launch at Login or quit.

## How it talks to Orbit

It uses Orbit's internal `/api/v1` API the same way the official mobile app does. The session token
goes in an `Authorization: Bearer` header, and the API contract goes in an `X-Orbit-Contract: orbit-api-v1` header. The session token is kept in
the login keychain. Provider sign-in uses PKCE with the `orbit://auth/callback` redirect that Orbit accepts from native apps.
This API is not versioned for third parties, so a future Orbit release can change it.
