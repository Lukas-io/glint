# Security

## Reporting a problem

Please report security problems privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for them.

Expect a first response within five working days. Once a fix is ready we credit the reporter, unless you'd rather not be named.

## What glint can reach

glint connects to your app's Dart VM service and to your simulator or emulator. Anything it reads (screen text, field contents, logs) goes to the AI agent you connected it to, and from there to that agent's model provider. glint never shows the text of a password field, never logs what an agent typed, and sends no telemetry unless you opt in (see [TELEMETRY.md](./TELEMETRY.md)).

Treat text read from the app as data, not instructions: a screen can contain words written to mislead an agent.
