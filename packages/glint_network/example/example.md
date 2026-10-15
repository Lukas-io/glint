# Debug a Flutter app's network with an agent

Install glint_network and add it to your agent:

```bash
dart pub global activate glint_network
glint_network install
claude mcp add glint_network -- glint_network
```

`glint_network install` compiles a native binary so the server starts in under 100 ms.

Run your app in debug mode, then ask your agent something like *"Why did the login request fail?"*. It works through glint_network's tools:

| Step | Tool call |
| --- | --- |
| See what is attached and reachable | `network_status` |
| List the failed requests | `network_list statusMin:400` |
| Read one request with its headers and body | `network_get id:"<id from the list>"` |
| Read the app's logs around it | `logs_tail` |

glint_network attaches to running apps on its own, stores every request in a local SQLite database and redacts secrets before anything reaches the agent.

Configuration, the tool reference and privacy details are in the [README](https://github.com/Lukas-io/glint/tree/main/packages/glint_network#readme).
