# Drive a Flutter app with glint

Install glint and add it to your agent:

```bash
dart pub global activate glint_mcp
claude mcp add glint -- glint
```

Other MCP hosts (Cursor, Windsurf, VS Code) take the same command in their MCP config:

```json
{
  "mcpServers": {
    "glint": { "command": "glint" }
  }
}
```

Run your app in debug mode on a simulator, an emulator or a phone:

```bash
flutter run
```

Then ask your agent something like *"Sign up with a test email and tell me what the next screen says"*. It works through glint's tools:

| Step | Tool call |
| --- | --- |
| Find the app and the device | `attach` |
| Read the screen | `get_scene` |
| Tap a button | `tap text:"Create account"` or `tap glintId:"elevated_button"` |
| Type into a field | `type focus:"text_field" text:"ada@example.com"` |
| Find something further down | `scroll_to_find text:"Terms"` |

Every action reply says whether the screen changed and how (`routeChanged`, `overlayAppeared`, `contentChanged`, `nothing`), and every failure carries an `errorKind` with `nextSteps`, so the agent reads what happened instead of guessing.

The full tool list, setup per platform and current limits are in the [repository README](https://github.com/Lukas-io/glint#readme).
