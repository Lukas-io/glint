# Changelog

All notable changes to glint are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semver, where before 1.0 a minor bump may break things.

## [Unreleased]

First tagged release. glint lets an AI agent drive a running Flutter app on an iOS Simulator or Android emulator, with nothing added to the app.

### What it does

- `get_scene` reads the screen as a compact scene built from Flutter's own widget tree over the Dart VM service, with ids an agent can act on, and shows dialogs and sheets above the page they cover.
- Actions work like a person's: `tap`, `long_press`, `type`, `key`, `scroll`, `scroll_to_find`, `swipe`, `drag`, `hardware_button` and `batch`. Each reports whether and how the screen changed.
- `attach` with no arguments finds the running app and its device, and keeps working across a hot restart.
- Device mode drives a simulator or emulator without a Flutter app, through screenshots and coordinates.
- Also: app logs, screen recording, Face ID and Touch ID enrolment and matching on the iOS Simulator, and lock and unlock.

### Security and privacy

- Password fields show only their length, and typed text never reaches the action log or an issue report.
- `report_issue` drafts first and files only with the user's OK; paths, tokens, keys and passwords are redacted.
- Android typing sends text as one quoted argument, so shell characters are typed literally.
- Telemetry is off unless the user sets `GLINT_TELEMETRY=on`; see `TELEMETRY.md`.

### Known limits

See "Limits today" in the README: debug and profile builds only, Xcode 26 for iOS, ASCII typing, no web or desktop yet.
