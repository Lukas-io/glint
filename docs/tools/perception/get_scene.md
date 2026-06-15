---
tool: get_scene
description: Read the current screen as a compact, addressable tree. Source of truth for every targeted action.
when_to_use: Before EVERY action. After EVERY action. The framework is the source of truth, not your prediction.
---

## DO NOT USE THIS TOOL WHEN

- You're polling for an animation to finish — use `wait_for_settle` instead. `get_scene` is a snapshot, not a wait.
- You want geometry without acting — `resolve` is cheaper, no full tree walk.
- The user only wants the app's logs — `app_logs` is the right tool.
- You're tempted to call it twice in a row before reading the first result — don't. Each call is a VM eval; cache the response.

## Use this when

- You're starting a task and need to know what's on screen.
- You've just performed an action and want to confirm the framework reflects it.
- You're trying to find a widget by content / role — `get_scene` is where labels and previews live.
- You need to enumerate scrollables before deciding which one to use.

## How it works

1. Calls `ext.flutter.inspector.getRootWidgetTree` (summary tree by default — user-code only).
2. Walks the tree, classifies each node (tappable / typeable / scrollable / static), assigns stable `glintId`s based on type + nearest uniquely-named ancestor, disambiguates duplicate siblings with `#xxxx`.
3. Compacts repeated runs (`{tile_in_list × 12}` instead of 12 lines) and drops empty leaves.
4. Returns a tree of `SceneNode`s with `glintId`, `label`, `textPreview`, `depth`, `createdByLocalProject`, and a per-node action capability marker.

## Args

- `depth` (string, optional, default `summary`) — `summary` (user code only) or `full` (every internal node).
- `format` (string, optional, default `tree`) — `tree` (the compacted indented view) or `json` (raw `SceneNode.toJson`).

## Returns

```json
{
  "summary": "<root>\n  Scaffold\n    AppBar\n      Text  \"Settings\"\n    ListView <>\n      {tile_in_list × 4}\n      tile_with_chevron *  (about_tile)\n  floating_action_button *  (floating_action_button)",
  "data": {
    "root": { /* SceneNode.toJson */ },
    "addressableCount": 23,
    "depth": "summary"
  }
}
```

Markers in the tree view:

- `*` tappable
- `>` typeable
- `<>` scrollable
- `-` static (read-only)

`textPreview` is included inline in quotes when present.
`(local)` is appended to nodes created by the user's project (vs. framework internals).
A `#xxxx` suffix on an id means it's disambiguated against duplicate siblings.

## Pairs well with

- Every targeted tool. The id you pass to `tap` / `type` / `scroll_to_find` comes from here.
- `resolve` — when you have the id and want raw coordinates.
- `wait_for_settle` — when the scene is mid-transition (some nodes missing / shifting).

## Example

```
> attach …
> get_scene
< Scaffold
    AppBar
      Text "Profile"
    Column <>
      avatar_circle - 
      name_field >  "Wisdom"   (name_field)
      sign_out_button *  (sign_out_button)
> tap  glintId:"sign_out_button"
< {summary:"tapped sign_out_button"}
> get_scene   # confirm
< … (the sign-out dialog)
```
