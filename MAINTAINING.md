# Maintaining glint

How this repository is organised, and how changes, checks and releases move through it. If something here and the tooling disagree, the tooling wins and this file gets fixed.

## Layout

```
pubspec.yaml         workspace root (never published)
packages/<name>/     one directory per package, each released on its own
fixtures/            Flutter apps the tests and device checks drive
tool/                release tool, device check, CI scripts
.github/             CI, device check, release workflows
```

The workspace uses [Dart pub workspaces](https://dart.dev/tools/pub/workspaces): run `dart pub get` once at the root and every package resolves against one shared `pubspec.lock`. A package that depends on another package in this repo uses the local copy automatically, so a change to shared code and its callers can land in one PR.

## Setting up

```bash
git clone https://github.com/Lukas-io/glint.git
cd glint && dart pub get
(cd packages/glint_mcp/native/ios_sim_bridge && swift build)   # iOS only
```

Run a package's checks from its directory, the same way CI does:

```bash
cd packages/glint_mcp
dart analyze --fatal-warnings lib bin test
dart test
```

Repo tooling has its own tests: `dart test tool/test` from the root.

## Making a change

1. Branch from `main`. Never push to `main` directly.
2. One concern per PR. A PR may touch several packages when the change spans them; that is what the monorepo is for.
3. Start the PR title with the package it changes, in plain words: `glint_mcp: Refuse bridge actions on an untested Xcode`. Use `repo:` for workspace, CI or docs changes.
4. Every user-visible change adds a line under `## [Unreleased]` in that package's `CHANGELOG.md`, in the same PR.
5. A tool change follows the tool feedback rule in [CONTRIBUTING.md](./CONTRIBUTING.md): what happened on success, a branchable `errorKind` with `detail` and `nextSteps` on failure, progress on anything slow.
6. If a tool's name, arguments or description changes, the tool contract golden fails on purpose. Regenerate it in the same PR so the change is visible in review.

## Checks

The `CI` workflow runs on every PR and every push to `main`:

| Job | Runs when |
| --- | --- |
| `<package> (ubuntu, macos)` | that package changed, or anything outside `packages/` changed, or `glint_core` changed |
| `Repo tooling` | always |
| `iOS simulator bridge (Swift)` | `glint_mcp` is being tested |
| `CI passed` | always; fails if any job above failed |

`CI passed` is the one required check. `main` is protected: a PR merges only when it is green. Don't bypass that. When a check fails, fix the cause or fix the check in the same PR.

The `Device check` workflow drives `fixtures/counter_app` on a real Android emulator and iOS simulator: nightly on Flutter stable, weekly on beta, and on demand with `gh workflow run device.yml --ref <branch>`. Run it on the branch before merging anything that touches input, attach, or the bridge. A green job is not enough on its own: read its `PASS` lines.

## Releases

Each package has its own version, changelog and tags. Versions follow semver with Dart's pre-1.0 rule: until 1.0, a minor bump may break things and a patch bump never does. A package's public API is its tool names, arguments, `errorKind` values and reply shape.

1. On an up-to-date `main`, run `dart run tool/release.dart prepare <package> <x.y.z>`. It bumps the package's version files, moves its Unreleased entries under a dated heading, and commits on `release/<package>-v<x.y.z>`. Open a PR from that branch and merge it once green.
2. Back on `main`, run `dart run tool/release.dart tag <package>`. It creates and pushes the tag `<package>-v<x.y.z>`.
3. The `Release` workflow checks the tag against the package's `pubspec.yaml`, runs the package's tests, and publishes a GitHub Release with that version's changelog section as notes. A `glint_mcp` release also attaches the universal `glint-iossim-macos` bridge and its sha256.

The release tool refuses to release a package that depends on `glint_core` while `glint_core` has unreleased changes. Release `glint_core` first, then raise the constraint in the dependent package.

Tag only a commit whose own CI run on `main` is green.

## Shared code

Code used by more than one package belongs in `glint_core`. Its API is internal to this repository until it is published, so change it freely, but update every caller in the same PR. When `glint_core` changes, CI tests every package.

Before copying code from one package to another, move it into `glint_core` instead.

## Issues

There is one issue tracker for all packages. Label each issue with the package it concerns (`glint`, `network` or `core`) plus its kind (`bug`, `ux-friction`, `enhancement`). Issues filed by an agent through `report_issue` carry `agent-filed`, and the agent shows the draft to the user before filing.

Security problems are not filed as issues; see [SECURITY.md](./SECURITY.md).

## Commits

Plain sentences in the imperative, no prefixes or ticket codes: `Refuse bridge actions on an untested Xcode`. The PR title carries the package name; commit messages don't need to. Merge PRs with a merge commit so each PR's history stays readable.
