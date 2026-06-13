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

Targets are `glintId`s — snake_case, stable across reads:

- `floating_action_button` — top-level unique, no scope
- `elevated_button_in_flags_lab` — scoped by nearest uniquely-named ancestor
- `text_in_list#tso5` — `#xxxx` disambiguates duplicate siblings; can shift if the tree shape changes, prefer the un-suffixed id

Same widget at the same source location → same id every read. Coordinates exist as an escape hatch but are rarely needed.
''';

const _armedIntent = '''
## Armed intent

`awaitReady: true` on a targeted action: the server polls until the target exists in the tree AND passes a hit test, then fires. Ceiling `readyTimeoutMs` (default 5000). Use to chain actions across screen transitions — agent spends zero round-trips on the wait.

`wait_for_settle` blocks until frames quiet and no loading affordances remain. Use after an action that triggers async work.
''';

const _recovery = '''
## Recovery

Failures carry `errorKind` in `structuredContent`:

- `unresolvedTarget` — no such glintId. `get_scene`, pick a real id.
- `notHittable` — covered by overlay/absorber. Dismiss, retry.
- `targetNeverReady` — armed ceiling hit; target appeared but stayed unhittable. Raise `readyTimeoutMs` or dismiss the cover.
- `unsupportedBackendAction` — not wired on this platform (see Gotchas).
- `backendToolError` — native tool exited non-zero; read `detail`.
- `geometryResolveError` — inspector eval failed. Retry; else re-`attach`.
- `sessionNotAttached` — call `attach`.
- `invalidArgument` — fix per tool description.
- `internal` — glint bug. Surface `detail`.

`hittable=false` is a warning by default. Pass `refuseNotHittable: true` on `tap` to fail loud.
''';

const _gotchas = '''
## Gotchas

- **iOS hardware buttons partial** (Xcode 26): only `lock` reliable; Face-ID `home` doesn't dispatch.
- **`type` needs focus.** Pass `focus: <id>` to tap-and-type in one call.
- **Scroll is content-relative.** `scroll down` moves content down (finger swipes up).
- **`hittable=false`** — OS tap landed but Flutter hit-test routed elsewhere.
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

# chain across a screen transition (armed intent)
tap glintId=submit_button
tap glintId=ok_on_confirm_modal awaitReady=true
```
''';

/// Full instruction text shipped with the MCP server. Assembled from
/// independently-editable sections above.
const String kGlintInstructions = '''
glint lets you drive a running Flutter app on a simulator or emulator. Every tool reply uses the same envelope: `summary`, optional `warnings`, optional `nextSteps`, and on failure an `errorKind` you can branch on.

$_workflow
$_addressing
$_armedIntent
$_recovery
$_gotchas
$_examples''';
