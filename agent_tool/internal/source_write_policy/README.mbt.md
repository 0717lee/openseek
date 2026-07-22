# agent_tool/internal/source_write_policy

Workspace policy shared by the macOS sandbox profile builder and the `shell`
tool's static command preflight. This package decides which MoonBit source paths
are protected; it does not execute commands or emit SBPL.

## API contracts

- `is_protected_source_path(path)` recognizes protected source and manifest
  names by case-sensitive suffix. It accepts a basename or full path and does
  not access the filesystem.
- `is_moon_managed_workspace_path(root, path)` recognizes `_build` and
  `.mooncakes` components below a workspace root. These trees are writable
  because Moon generates source files in them.
- `is_protected_workspace_source_path(root, target)` combines workspace
  containment, the build-tree exemption, and protected-name classification.
  The root should be absolute and canonical when the result is used to mirror
  sandbox behavior.
- `path_is_under_lab(target, lab)` is the scratch-lab authorization predicate.
  It normalizes both paths, includes the lab itself, and rejects an empty lab or
  `/`.

The package uses `internal/workspace_path` for generic path operations. Its
comparisons are lexical and case-sensitive: callers remain responsible for
resolving symlinks and canonicalizing user-controlled paths where filesystem
identity matters.
