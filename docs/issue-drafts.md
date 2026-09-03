# Issue response drafts (not posted)

## #13 — flutter mode: attach cannot probe viewport when root widget is ClarityWidget

Thanks for the precise report, the widget-inspector comparison is what made this diagnosable.

Two things were wrong, both fixed on `multi-app-bughunt`:

1. **The probe hid its own error.** `attach` retried the viewport probe until the timeout and swallowed every exception, then reported "no addressable node rendered", which is what you saw. With a ClarityWidget root the tree read succeeded but the node-anchored geometry eval failed, so the real reason never surfaced. The probe now keeps the last error and returns it in `detail` as `geometryResolveError` (commit fde3b17).
2. **The probe should never have needed a node.** The viewport is a property of the view, not of a widget. `attach` now asks `WidgetsBinding.instance.platformDispatcher.implicitView` first (no inspector selection involved) and only falls back to a node-anchored read. That removes the dependency on what sits above `MaterialApp` entirely (same commit).

The second issue, the bridge path resolving against the client's cwd, was fixed in f906f5a: the default now resolves relative to glint's own package root, so `iosBridgePath` is no longer needed.

Could you pull the branch (or the next tag), `dart pub global activate --source path .`, restart the MCP server, and run `attach` with no args? If it still fails, please paste the `detail` line: it will now name the eval that broke instead of guessing.

## #3, #5, #7 — closed, no reply needed

Same family as the `FormatException` crash seen in `scroll` / `scroll_to_find` (a geometry eval returning prose instead of JSON). Every geometry decode is now guarded and surfaces as `geometryResolveError` with the offending text, so a future eval-scope regression like the `HitTestResult` one fails with a readable reason rather than a stack trace.
