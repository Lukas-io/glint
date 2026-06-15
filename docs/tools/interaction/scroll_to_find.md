---
tool: scroll_to_find
description: Scroll a scrollable until a target glintId becomes hittable OR a content predicate matches.
when_to_use: When the target you need is below the fold and you don't want to script a loop of `scroll` + `get_scene`.
---

## DO NOT USE THIS TOOL WHEN

- The target is already visible AND hittable — just `tap` it. (Check `get_scene` first.)
- The screen has no `<>`-marked scrollable — there's nothing to scroll. Probably an overlay; dismiss it.
- The target is in a horizontal scrollable but you only know the direction is "down" — pass `direction: "right"` / `"left"` instead.
- You want to scroll a *specific* offset (e.g. "scroll 200px down") — that's `scroll`. `scroll_to_find` is for "scroll until X is hittable".

## Use this when

- The user describes a destination ("scroll to the privacy tile") rather than a distance.
- You're navigating a long settings or feed where the item's position varies.
- You're searching by content — pass `contentMatches` instead of `glintId` when the id might disambiguate to `#xxxx` (you can't know in advance).

## How it works

1. Picks the target scrollable: explicit `scrollableId`, or the highest-priority scrollable currently visible (heuristic: nearest-to-top, biggest viewport).
2. Loops: read scene → check predicate → if not matched, fire one `scroll` of `stepFraction` of the viewport in `direction` → wait for the frame to settle.
3. Exits when:
   - The predicate matches AND the matched widget passes a hit test → success.
   - `maxScrolls` reached → `targetNeverReady`.
   - Two consecutive scrolls produce zero scroll delta → `internal` "scroll exhausted".

## Args

- `glintId` (string, optional) — target widget. One of `glintId` or `contentMatches` required.
- `contentMatches` (string, optional) — substring match against `textPreview`.
- `scrollableId` (string, optional) — explicit scrollable. Auto-picked if omitted.
- `direction` (string, optional, default `down`) — `up` / `down` / `left` / `right`.
- `stepFraction` (number, optional, default 0.6) — viewport fraction per step.
- `maxScrolls` (int, optional, default 12) — give-up ceiling.

## Returns

Success:
```json
{
  "summary": "found privacy_tile after 3 scrolls",
  "data": {
    "glintId": "privacy_tile",
    "scrolls": 3,
    "scrollableId": "settings_list",
    "physical": {"x": 195, "y": 1200}
  },
  "nextSteps": ["call `tap` to act on it"]
}
```

Note: `scroll_to_find` does NOT tap the target. Call `tap` separately. (Reason: many use cases just need to bring something into view — e.g. confirming a status — without acting on it.)

Error (`targetNeverReady`) — scrolled `maxScrolls` times, target not found / not hittable. Raise the ceiling, or check the direction.

## Pairs well with

- `tap` / `type` immediately after — the target is now in view + hittable.
- `awaitReady: true` on the follow-up tap is unnecessary; `scroll_to_find` already proved it's hittable.
