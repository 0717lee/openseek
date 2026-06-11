# bobzhang/openseek/agent_session/workspace

Workspace indexing for durable sessions. A *workspace* is a project
directory; its sessions live in the project's own `.openseek/` — exactly
where the pre-workspace TUI kept them, so existing stores need no migration —
while the global OpenSeek home (`~/.openseek`) only indexes which workspaces
exist, so they can be found again from anywhere.

```text
<home>/
  workspaces/
    <key>/                 # FNV-1a-64 of the canonical project path
      workspace.json       # { version, path, last_opened_unix }
      workspace.lock

<project>/
  .openseek/
    sessions/...           # an ordinary agent_session/store tree
```

`WorkspaceHome::open(path, now_unix~)` canonicalizes `path`, claims (or
revisits) its index entry, and returns the `Workspace` whose `store_root()`
(`<path>/.openseek`) is passed to `SessionStore`. `workspace.json` carries
the real path, so the key never needs to be reversible; key collisions are
kept apart by probing `<key>-1`, `<key>-2`, …. There is no single registry
file: `WorkspaceHome::listings()` derives "recent workspaces" by scanning
`workspaces/*/workspace.json`, which is cheap, self-healing, and free of
write contention.

Only front-ends (the TUI, a future GUI) speak workspace; the engine keeps its
dumb `--session-root` contract and never resolves workspaces itself.
