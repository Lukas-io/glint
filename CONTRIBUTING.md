# Contributing to glint

Thanks for helping. This page covers what a good change looks like here. The mechanics (layout, checks, releases) are in [MAINTAINING.md](./MAINTAINING.md).

## What glint promises

- **Nothing added to the app.** glint works on any Flutter app as it is: no package to add, no init code, no hooks. A change that needs the app to cooperate will not be merged.
- **The agent is told, not left guessing.** Every tool reply says what happened and what to do next. An agent should never need a screenshot or a retry loop to find out whether an action worked.
- **Every reply costs tokens.** Keep output compact without losing anything the agent needs to act on.

## Before you start

For anything bigger than a small fix, open an issue first so we can agree on the shape. Pick the package label (`glint`, `network` or `core`) so it reaches the right place.

## Writing a tool or changing one

MCP tool calls are synchronous: the agent waits and sees only the reply, so the reply is the whole experience.

- **Success:** say what happened and return the data the agent needs for its next call.
- **Failure:** return a branchable `errorKind`, a real `detail`, and `nextSteps` the agent can follow. Never fail silently or with a raw exception.
- **Slow work** (booting, building, installing, anything longer than a few seconds): send `notifications/progress` about every 15 seconds with the current phase.

If you change a tool's name, arguments or description, regenerate the tool contract golden in the same PR. The diff shows reviewers exactly what agents will see.

## Code style

- Run `dart format` on the lines you touch, not on whole files you didn't otherwise change.
- Comments are single-line `///` doc comments on declarations, and only where the code can't say it itself. No multi-line comment blocks, no comments that restate the code.
- Test your own logic, not the libraries underneath it. A bug fix comes with a test that fails without it.

## Checking your change

From the package you changed:

```bash
dart analyze --fatal-warnings lib bin test
dart test
```

If your change touches attaching, input or the iOS bridge, also run the device check against a simulator or emulator (see [MAINTAINING.md](./MAINTAINING.md#checks)), or say in the PR that you couldn't.

## Opening the PR

- Title it with the package: `glint_mcp: Keep focus when the keyboard covers the field`.
- Add a line to that package's `CHANGELOG.md` under `## [Unreleased]` if users will notice the change.
- Fill in the PR template: what changed, why, and how a reviewer can check it.

## Security and licence

Report security problems privately; see [SECURITY.md](./SECURITY.md).

glint is licensed under [Apache-2.0](./LICENSE). By opening a PR you agree your contribution is licensed the same way.
