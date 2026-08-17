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
  `sessionIds` account, minus the registry-global archive set; a Workspace
  Desktop generated for a worktree is presented under the project it was cut
  from rather than beside it, reconstructed from the `<project>/.worktrees/`
  path convention because dsh files every Workspace as a peer;
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

Only the eleven dsh methods used by that page are allowlisted:
`workspace.list`, `workspace.create`, `workspace.delete`,
`workspace.archiveSession`, `session.list`, `session.create`,
`session.history`, `session.models`, `session.selectModel`, `session.prompt`,
and `session.cancel`. Settings, credentials, arbitrary path operations, plugin
management, `workspace.rename`, `workspace.insertSessionBefore`, and other dsh
APIs are not exposed by this integration.

Archiving and removing a Workspace registration are the page's only cleanup
verbs, and dsh gives no others: it has no session deletion at all.

Archiving hides a conversation from every grouping surface and **cannot be
undone**. dsh's archive set is append-only — no operation removes an id from
it, and dsh's own API documents unarchive as "a future" capability — so an
archived conversation is invisible to every dsh client from then on, dsh's own
included. Its log stays on disk and it keeps its slot in the Workspace
account, which is what that future unarchive would restore. OpenSeek's sidebar
has a Restore action and routes it for OpenSeek and Codex rows; dsh rows do
not offer it, because there is no dsh operation behind it.

Removing a Workspace registration keeps the directory and every session log;
the conversations it grouped become ungrouped rather than disappearing.

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
  in that checkout or anywhere inside it. Archiving the conversation is the
  ordinary way to satisfy that; `force` overrides it anyway, and has to, since
  dsh has no session deletion and an unarchivable occupant would otherwise
  make the checkout unremovable for the rest of that conversation's life —
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
baselines before attaching a directory. Once the conversation exists in the
generated Workspace, the next `workspace.list` extends the Files and Terminal
grant to that path.

## Runtime prerequisite

Desktop does not package or configure DeepSeek Harness. It executes the exact
command shown above, so `dsh` and the Node environment it requires must already
be available through the login-shell `PATH`. dsh remains responsible for its
installation, `DSH_HOME`, provider credentials, and profile environment.

If `dsh` cannot start, Desktop reports DeepSeek Harness as unavailable. There
is no Desktop setting or environment-variable override for another executable.
