# Device routing foundation

The product must support multiple computers and future phone/glasses interfaces without hard-coding combinations such as iPhone + Mac.

`DeviceRouter` provides the first portable routing layer:

- each executor has a stable `DeviceIdentity`,
- executors advertise their actual `ToolDescriptor` capabilities,
- callers can ask for candidates supporting a tool,
- execution is routed to an explicit device ID,
- the router creates `RequestContext` with the selected device and session,
- optional approval IDs are forwarded unchanged,
- unknown devices and unadvertised capabilities fail before execution.

`platform` is metadata only. It is never used to decide which device receives a request.

`RuntimeDeviceExecutor` adapts a local `ToolRuntime` to the same `DeviceExecuting` boundary that a future encrypted remote executor can implement.

There is intentionally no network listener, gateway, pairing flow, persistence, heartbeat, or authentication in this slice. The current router is in-memory only.

Before remote devices are supported, add authenticated device identity, encrypted outbound transport, capability freshness/heartbeat handling, replay protection, bounded payloads, rate limits, disconnect semantics, and durable session ownership.
