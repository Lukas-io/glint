// Module D — the instruction layer the MCP server ships with.
// Loaded into the agent's system prompt via MCPServer.instructions.
// Keep tight: every char is a token cost (see source-of-truth §7.5).

const _workflow = '''
## Workflow

1. `attach` once at session start.
2. `get_scene` to read what's on screen.
3. Act with a `glintId` from the scene. The marker on each line tells you what works:
   - `*` tappable — `tap`, `long_press`, `double_tap`, `drag`
   - `>` typeable — `type`
   - `<>` scrollable — `scroll`, `swipe`, `scroll_to_find`
   - `-` static — read-only
4. `get_scene` again to confirm. The framework is the source of truth, not your prediction.
''';

const _addressing = '''
## Addressing

Targets are `glintId`s — snake_case names that stay stable across reads:

- `floating_action_button` — top-level uniqueness, no scope needed
- `elevated_button_in_flags_lab` — scoped by the nearest uniquely-named ancestor
- `text_in_single_child_scroll_view#tso5` — `#xxxx` suffix disambiguates duplicate siblings

Same widget at the same source location → same id every read. `#xxxx` suffixes can shift if the surrounding tree shape changes; prefer the un-suffixed id when both exist.

Coordinates are an escape hatch via `CoordinateTarget` and are rarely needed.
''';

const _recovery = '''
## Recovery

Every failure returns `errorKind` in `structuredContent`:

- `unresolvedTarget` — no such glintId. `get_scene`, pick a real id.
- `notHittable` — something covers the target. Dismiss it, retry.
- `unsupportedBackendAction` — this gesture isn't wired on this platform (see Gotchas).
- `backendToolError` — native tool exited non-zero. Read `detail`.
- `geometryResolveError` — inspector eval failed. Retry once; else `attach` again.
- `sessionNotAttached` — call `attach`.
- `invalidArgument` — fix per the tool's description.
- `internal` — glint bug. Surface `detail`.

`hittable=false` is a warning by default — the agent decides. Pass `refuseNotHittable: true` to `tap` to fail loud instead.
''';

const _gotchas = '''
## Gotchas

- **iOS hardware buttons are partial** (Xcode 26): only `lock` is reliably mapped; `home` on Face ID devices doesn't dispatch.
- **`type` needs focus.** Pass `focus: <input glintId>` to tap-and-type in one call.
- **Scroll direction is content-relative.** `scroll down` moves content down (finger swipes up).
- **`hittable=false`** means the OS-level tap landed but Flutter's hit-test routed it elsewhere.
- **`scroll_to_find`** caps at 8 scrolls; raise `maxScrolls` if needed.
''';

const _examples = '''
## Examples

```
# increment a counter
get_scene                                          → * button floating_action_button
tap glintId=floating_action_button
get_scene                                          → confirm new value

# fill a text field
get_scene                                          → > input email_field
type text="user@example.com" focus="email_field"

# find a row in a long list
get_scene                                          → text_in_list#* (29 more, last: text_in_list#5ifw)
scroll_to_find targetGlintId="text_in_list#5ifw" direction="down"
```
''';

/// Full instruction text shipped with the MCP server. Assembled from
/// independently-editable sections above.
const String kGlintInstructions = '''
glint lets you drive a running Flutter app on a simulator or emulator. Every tool reply uses the same envelope: `summary`, optional `warnings`, optional `nextSteps`, and on failure an `errorKind` you can branch on.

$_workflow
$_addressing
$_recovery
$_gotchas
$_examples''';
