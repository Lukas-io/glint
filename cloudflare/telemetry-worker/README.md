# glint telemetry worker

Cloudflare Worker that receives anonymous usage events from glint
installations and writes them to a Workers Analytics Engine dataset
for aggregation.

## What the Worker accepts

`POST /v1/event` with a JSON body matching this shape:

```json
{
  "v": 1,
  "instance": "<uuid v4>",
  "event": "tool_call" | "session" | "attach" | "error",
  "ts": "<ISO-8601 UTC>",
  "platform": "ios" | "android",
  "fields": {
    "name": "<tool name>",
    "elapsedMs": 412,
    "errorKind": "...",
    "armed": true,
    "op": "open" | "close"
  }
}
```

`fields` contents vary per event type — see `lib/src/observability/telemetry.dart`.

The Worker validates the schema (UUIDv4 instance, allow-listed event,
parseable timestamp, bounded body) and writes one Analytics Engine
data point per request.

There is no auth on the endpoint — events have no PII, and rate
limiting is enforced by Cloudflare's edge defaults.

## Deploy

```bash
cd cloudflare/telemetry-worker
npm install
npx wrangler login        # one time
npm run deploy
```

`wrangler deploy` provisions the `glint_events` Analytics Engine
dataset automatically (declared in `wrangler.jsonc`).

## Querying

Once events are flowing, you can query the dataset via Cloudflare's
SQL API (see https://developers.cloudflare.com/analytics/analytics-engine/sql-api/),
e.g.:

```sql
SELECT
  blob1 AS event,
  count() AS n
FROM glint_events
WHERE timestamp > now() - INTERVAL '1' DAY
GROUP BY event
ORDER BY n DESC
```

## Privacy

Events have no PII — no VM URIs, glintIds, app names, source paths,
user names, file system paths. The `instance` UUID is generated fresh
per glint process; it does not persist across restarts.

Glint clients are opt-in via `config.telemetryEnabled = true` (default
false). Anyone can run their own Worker and point glint at it:

```
config set telemetryEndpoint "https://your-own.workers.dev/v1/event"
```
