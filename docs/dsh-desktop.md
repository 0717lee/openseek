# DeepSeek Harness in OpenSeek Desktop

OpenSeek Desktop can run one local DeepSeek Harness (`dsh`) Web process beside
its existing OpenSeek engine and Codex app-server processes. DeepSeek Harness
keeps ownership of its sessions, model configuration, tools, approvals, and
on-disk state. OpenSeek adds a peer **DeepSeek Harness** section to the global
sidebar's local device and adapts dsh history to the existing transcript and
composer.

This integration deliberately uses dsh's existing network carriers. It does
not introduce another dsh protocol:

- unary calls use `POST /api/<method>` with dsh's complete ApiProxy
  `client-request` and `server-response` envelopes;
- all-session events use the downlink WebSocket `/api/events.mux`;
- host lifecycle events use the downlink WebSocket `/api/events.host`;
- approval and question answers use `POST /api/respond` with the original
  `client-response` and `rpcId`.

The native Desktop process is the only component that knows the loopback port.
The browser page calls three Proton commands (`dsh.status`, `dsh.request`, and
`dsh.respond`), and the native process translates those calls to dsh HTTP. This
preserves dsh's Host/Origin checks instead of adding CORS or asking the renderer
to contact localhost directly.

## Process lifetime

`desktop/internal/dsh` owns the process, HTTP requests, and both WebSockets.
It starts:

```text
dsh web --host 127.0.0.1 --port 0
```

and accepts only a readiness line containing a loopback HTTP origin. HTTP
responses are limited to 32 MiB, WebSocket frames and requests to 8 MiB, and
the queues between transport tasks and the Desktop actor are bounded. A lost
WebSocket closes the pair; the next page request starts one reconnect attempt,
after which dsh replays subscription baselines and still-pending interactions.

The browser state lives in `desktop/frontend/dsh`. It currently supports:

- listing dsh Workspaces and grouping sessions by each Workspace's explicit
  `sessionIds` account;
- adopting the selected local OpenSeek project into dsh when its Workspace
  registry is empty;
- creating dsh sessions through a stable `workspaceId` rather than a loose
  `cwd`;
- loading dsh's per-session provider/model catalog and selecting the complete
  provider, model, and optional reasoning-effort tuple from the shared
  composer;
- choosing **Worktree** for a blank conversation: Desktop creates its normal
  Git worktree, registers that directory as a dsh Workspace, starts a new
  conversation inside it, and sends the first prompt there. dsh has no
  operation that moves a conversation between directories — a session's cwd is
  fixed in its header at creation and Workspace membership is derived from that
  cwd — so the blank conversation the user typed in keeps its own directory and
  stays in the sidebar; only the submission moves;
- loading the newest 200 message groups for a selected session;
- rendering user, assistant, reasoning, tool call/result, and turn-error rows
  through OpenSeek's shared transcript (model-only `surfaceOp: replace` copies
  are not duplicated in the human transcript);
- live assistant text deltas;
- queueing a prompt, steering a running session, and cancelling it;
- allowing or rejecting a tool approval once;
- answering single-select, multi-select, and free-text questions.

Only the nine dsh methods used by that page are allowlisted: `workspace.list`,
`workspace.create`, `session.list`, `session.create`, `session.history`,
`session.models`, `session.selectModel`, `session.prompt`, and
`session.cancel`. Settings, credentials, arbitrary path operations, plugin
management, the remaining Workspace mutations (`rename`, `delete`,
`insertSessionBefore`, `archiveSession`), and other dsh APIs are not exposed by
this integration.

## Local-only boundary

dsh sessions can execute tools, so these commands are registered only on the
embedded Desktop extension. They are absent from OpenSeek's remote WebSocket
method catalog, and `dsh.status_changed` / `dsh.event` notifications are
filtered before relay delivery. The DeepSeek Harness sidebar section is also
absent from browser-console builds.

dsh's Workspace registry is the authority for its Desktop Files, Editor, and
Terminal panels. `workspace.list` supplies each canonical directory and the
session ids it owns; OpenSeek does not infer that relationship from a session's
legacy display-only `cwd`. Selecting an accounted session therefore opens the
shared panels at its dsh Workspace root. An ungrouped session remains usable as
a conversation but does not receive filesystem authority.

At the native API boundary, OpenSeek converts its slash-rooted frontend
resource path to a host-native path before `workspace.create`, then converts
dsh's canonical host-native path back for the renderer. This keeps the grant
reversible on both POSIX and Windows instead of treating a display spelling as
authority.

A Desktop-created dsh worktree records **no owner** in the worktree registry.
This is deliberate. dsh's Workspace registry decides which conversation works
where, that mapping changes without Desktop's involvement, and dsh has no
operation that durably means "this conversation ended" — `host/session-removed`
reports that dsh dropped a session from memory, while `session.list` keeps
serving it from persistence. A recorded owner could therefore only go stale,
and a stale owner is what makes a checkout impossible to clean up.

Two consequences follow, both accepted:

- **Removal asks instead of remembering.** `worktree.remove` queries dsh's
  current `workspace.list` and refuses while any unarchived conversation works
  in that checkout or anywhere inside it. `force` overrides that refusal, and
  has to: dsh exposes no way to end a conversation — it has no delete, and
  this integration allowlists no archive — so an occupied checkout would
  otherwise be unremovable for the rest of that conversation's life, which is
  the failure this design exists to prevent. When dsh is not connected the
  removal proceeds without asking: no conversation can be executing without
  the process that would run it. A connected dsh that cannot answer refuses
  the removal rather than guessing. The question is asked before the workspace
  lifecycle lock is taken, and only about a checkout that is both unowned and
  still on disk, so a slow dsh cannot stall unrelated workspace operations.
- **First-send creation is not idempotent.** With no owner to key on, a lost
  `worktree.create` reply is reported as a failure instead of retried; any
  checkout that call may have made is an ordinary unowned worktree the user can
  remove. Retrying would create a second checkout, which is worse.

`worktree.create` still carries `dsh_session`, but only to authorize the
request: the host revalidates it against dsh's own blank-session and Workspace
baselines before attaching a directory. After dsh moves the session, the next
`workspace.list` replaces the Files and Terminal grant with the generated
Workspace path.

## Runtime prerequisite

Desktop does not package or configure DeepSeek Harness. It executes the exact
command shown above, so `dsh` and the Node environment it requires must already
be available through the login-shell `PATH`. dsh remains responsible for its
installation, `DSH_HOME`, provider credentials, and profile environment.

If `dsh` cannot start, Desktop reports DeepSeek Harness as unavailable. There
is no Desktop setting or environment-variable override for another executable.
