---
name: Bug report
about: A glint or glint_network tool returned wrong output, crashed, or didn't do what it said
labels: bug
---

> **Filing this is dead simple — agents are the recommended channel.**
> If you have Claude Code, Cursor, or another MCP-capable agent open right now, just say
> *"file a bug for this"* and it should open this template, fill the Quick report section,
> and submit. The Optional detail below is collapsible — skip it if you don't have it.

## Quick report (required — ~30 seconds)

**Package**
<!-- glint (screen, input, attach) or glint_network (HTTP, sockets, logs).
     Add the matching label, `glint` or `network`, if you can. -->

**Version**
<!-- e.g. 0.1.0. glint reports it in `telemetry op:"status"`, glint_network in
     `network_status` (mcp.version). Without it we can't tell whether your bug
     was already fixed in a later release. -->

**What broke**
<!-- One sentence. What did you (or the agent) expect, what actually happened? -->

**Failing tool call**
<!-- Tool name + the args you used. e.g.  tap  glintId:"submit_button" -->

**Platform / device**
<!-- ios / android, plus the simulator UDID or emulator serial. -->

**`session` or `network_status` response**
<!-- glint: paste the structuredContent from a recent `session` call.
     glint_network: paste a recent `network_status` reply.
     If `session` itself is what's broken, write "n/a — session broken". -->

---

<details><summary><strong>Optional detail</strong> (helps a lot, never required)</summary>

### Environment
- Dart SDK: <!-- dart --version -->
- Flutter SDK: <!-- flutter --version, first line is enough -->
- macOS / Linux / Windows version:
- IDE / agent: <!-- VS Code + Claude Code / Cursor / etc. -->

### Capture context
- VM service URI freshness: <!-- "fresh, app just started" or "running ~30 min" -->
- Debug build? <!-- release/profile have the VM service stripped -->
- iOS bridge path or adb path (only if non-default):
- Server invocation: <!-- the `command` + `args` from your .mcp.json -->

### Reproduction steps
1.
2.
3.

### Scene snippet
<!-- A few lines of `get_scene` output around the failing target — drop the
     unrelated subtree. Helps diagnose addressing / hit-test failures. -->

### Stderr / MCP host logs
<!-- The MCP server writes stack traces to stderr (never into tool responses),
     so check the IDE's MCP server logs for a traceback. -->

</details>
