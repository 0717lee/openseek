# agent_tool/shell/internal/git_policy

Pure git command-line policy for the `shell` source-write sandbox: parse a git
invocation's subcommand and classify it. No filesystem, workspace, or
shell-parse dependencies — just argv/word grammar — so the policy can be read and
tested in isolation. `agent_tool/shell` supplies the workspace-path glue and the
trusted-command-class wiring.

## Why a git-specific policy exists at all

The macOS sandbox in `agent_tool/internal/sandbox` denies writes to `*.mbt` and
the manifests, and that covers most of the problem. It does not cover all of it:

- the sandbox is macOS-only, and a Linux run has no runtime enforcement;
- `git checkout -- .` legitimately rewrites protected source, so a blanket deny
  would break normal recovery workflows.

So `shell` also asks a **cross-platform, pre-execution** question: is this
particular git invocation destructive in a way that cannot be undone? The
answer is `should_preblock`. Everything else in this package exists to compute
it or to answer the same question on the degraded text path.

## The classification

The load-bearing distinction is **recoverable** versus **not**.

A subcommand that "writes from the object store" only ever materializes content
git already has — HEAD, the index, a commit or tree, a stash — or deletes a
tracked file recoverable from it. Those run freely: the worst case is reviewable
and reversible through git itself.

```mbt check
///|
test "the recoverable writers, and the two that are not" {
  for subcommand in ["checkout", "switch", "restore", "reset", "stash", "rm"] {
    inspect(
      @git_policy.subcommand_writes_from_object_store(subcommand),
      content="true",
    )
  }
  // `mv` moves arbitrary worktree bytes onto the destination, and `clean`
  // deletes UNTRACKED files that have no object-store copy at all.
  inspect(
    @git_policy.subcommand_writes_from_object_store("mv"),
    content="false",
  )
  inspect(
    @git_policy.subcommand_writes_from_object_store("clean"),
    content="false",
  )
  // Store feeders take bytes from outside the repository.
  inspect(
    @git_policy.subcommand_writes_from_object_store("apply"),
    content="false",
  )
  // Read-only git is not a writer either.
  inspect(
    @git_policy.subcommand_writes_from_object_store("status"),
    content="false",
  )
}
```

`rm` stays on the safe side because it only deletes *tracked* files. `clean`
does not, because deleting an untracked file is permanent.

## `parse` — find the subcommand, or fail closed

Global options come before the subcommand and some of them take a value, so the
subcommand is not simply `argv[1]`. `parse` skips the global-option prefix and
reports both the subcommand and its index; the index is what lets callers scan
the *global region* separately from the subcommand's own arguments.

```mbt check
///|
/// Renders a parse result as `subcommand@index`, or `-` when parsing declines
/// to guess.
fn parsed(argv : Array[String]) -> String {
  match @git_policy.parse(argv, 1) {
    Some(invocation) =>
      "\{invocation.subcommand}@\{invocation.subcommand_index}"
    None => "-"
  }
}

///|
test "global options are skipped, with and without attached values" {
  inspect(parsed(["git", "status"]), content="status@1")
  inspect(parsed(["git", "-C", "/tmp", "status"]), content="status@3")
  inspect(parsed(["git", "-C/tmp", "status"]), content="status@2")
  inspect(
    parsed(["git", "-c", "user.name=x", "commit", "-m", "hi"]),
    content="commit@3",
  )
  inspect(parsed(["git", "--git-dir=/tmp/x", "log"]), content="log@2")
  inspect(parsed(["git", "--no-pager", "diff"]), content="diff@2")
}
```

Anything it cannot confidently classify returns `None` — **fail closed**. A
caller must not read `None` as "no subcommand, therefore harmless"; it means
"this package has no opinion", and `should_preblock` treats it as not-blocked
only because the sandbox and the rest of `shell` still apply.

```mbt check
///|
test "unrecognized shapes decline rather than guess" {
  // An unknown option could be a value option whose operand we would then
  // mistake for the subcommand.
  inspect(parsed(["git", "--not-a-real-option", "status"]), content="-")
  // A value option with no value left.
  inspect(parsed(["git", "-C"]), content="-")
  // Help, an explicit `--`, and a bare `git`.
  inspect(parsed(["git", "--help"]), content="-")
  inspect(parsed(["git", "-h"]), content="-")
  inspect(parsed(["git", "--", "status"]), content="-")
  inspect(parsed(["git"]), content="-")
}

///|
test "aliases are not resolved" {
  // Resolving `co` would require reading the user's config, which this package
  // will not do. The caller sees the literal word.
  inspect(parsed(["git", "co", "main"]), content="co@1")
}
```

## `global_option_reconfigures` — the precursor that changes everything

`git -c filter.x.smudge=<command> checkout` runs arbitrary code during an
otherwise ordinary checkout. `git -C /elsewhere` and `--work-tree=` point the
same subcommand at a different tree. Options that repoint config, the exec path,
the git dir, the namespace, or the cwd/worktree therefore turn a recoverable
writer into an unbounded one.

```mbt check
///|
test "the options that make an object-store writer unsafe" {
  for
    arg in [
      "-c", "-cfilter.x=y", "--config-env", "--config-env=X=y", "--exec-path", "--exec-path=/tmp",
      "--git-dir", "--git-dir=/tmp/x", "--namespace", "--namespace=n", "-C", "-C/tmp",
      "--work-tree", "--work-tree=/tmp",
    ] {
    inspect(@git_policy.global_option_reconfigures(arg), content="true")
  }
  // Options that only change presentation or object lookup do not.
  for arg in ["--no-pager", "-p", "--paginate", "--bare", "--version", "status"] {
    inspect(@git_policy.global_option_reconfigures(arg), content="false")
  }
}
```

## `should_preblock` — the decision

Read `true` as "refuse before spawning". Read `false` as "this guard has no
objection", not as "safe" — the sandbox and the rest of `shell`'s preflight still
run.

Ordinary git, and the recoverable writers in their plain forms, are not blocked:

```mbt check
///|
/// `should_preblock` over a full argv, starting the scan just past `git`.
fn preblock(argv : Array[String]) -> Bool {
  @git_policy.should_preblock(argv, 1)
}

///|
test "read-only git and plain recoverable writes run" {
  inspect(preblock(["git", "status"]), content="false")
  inspect(preblock(["git", "log", "--oneline", "-5"]), content="false")
  inspect(preblock(["git", "diff"]), content="false")
  // Plain index restore: the classic "undo my edits" recovery.
  inspect(preblock(["git", "checkout", "--", "src/main.mbt"]), content="false")
  inspect(preblock(["git", "restore", "src/main.mbt"]), content="false")
  // Bare branch switch, reset, stash, and tracked-file removal.
  inspect(preblock(["git", "checkout", "main"]), content="false")
  inspect(preblock(["git", "reset", "--hard"]), content="false")
  inspect(preblock(["git", "stash"]), content="false")
  inspect(preblock(["git", "rm", "src/old.mbt"]), content="false")
}
```

Store feeders and the two non-recoverable writers are blocked outright:

```mbt check
///|
test "commands that source bytes from outside the object store are blocked" {
  inspect(preblock(["git", "am", "patch.mbox"]), content="true")
  inspect(preblock(["git", "update-index", "--index-info"]), content="true")
  inspect(preblock(["git", "read-tree", "HEAD"]), content="true")
  inspect(preblock(["git", "fast-import"]), content="true")
  // `mv` moves arbitrary worktree bytes onto the destination.
  inspect(preblock(["git", "mv", "notes.txt", "src/main.mbt"]), content="true")
}
```

A recoverable writer becomes blocked as soon as the global region reconfigures
it:

```mbt check
///|
test "reconfiguration promotes a recoverable write to a blocked one" {
  inspect(
    preblock(["git", "-c", "filter.x.smudge=curl evil", "checkout", "main"]),
    content="true",
  )
  inspect(preblock(["git", "-C", "/elsewhere", "rm", "f.mbt"]), content="true")
  inspect(
    preblock(["git", "--work-tree=/elsewhere", "reset", "--hard"]),
    content="true",
  )
  // Only the region *before* the subcommand counts — a `-c` after it is the
  // subcommand's own argument, and git does not treat it as global config.
  inspect(preblock(["git", "stash", "-c"]), content="false")
}
```

`--help` on a subcommand prints text and exits, so it is never blocked even for
a subcommand that would otherwise be:

```mbt check
///|
test "asking for help is not running the command" {
  inspect(preblock(["git", "clean", "--help"]), content="false")
  inspect(preblock(["git", "am", "-h"]), content="false")
}
```

## The two subcommands with real argument analysis

### `checkout` / `switch` / `restore` and untracked files

These are recoverable *for tracked files*. They stop being recoverable when they
can overwrite an **untracked** file — git's own guard against that is bypassed by
`-f`, and sourcing paths from another tree writes files the index does not know
about. Plain index restore stays allowed.

```mbt check
///|
test "forced or tree-sourced checkouts are blocked; plain ones are not" {
  // Force, overlay, and side-picking overwrite regardless of untracked state.
  inspect(preblock(["git", "checkout", "-f", "main"]), content="true")
  inspect(preblock(["git", "checkout", "--force", "main"]), content="true")
  inspect(preblock(["git", "restore", "--ours", "f.mbt"]), content="true")
  inspect(preblock(["git", "switch", "--force", "other"]), content="true")
  // `-f` clustered with other short flags still counts.
  inspect(preblock(["git", "checkout", "-fq", "main"]), content="true")
  // An explicit source tree-ish, spelled any of the four ways.
  inspect(
    preblock(["git", "restore", "--source", "HEAD~1", "f.mbt"]),
    content="true",
  )
  inspect(
    preblock(["git", "restore", "--source=HEAD~1", "f.mbt"]),
    content="true",
  )
  inspect(preblock(["git", "restore", "-s", "HEAD~1", "f.mbt"]), content="true")
  inspect(preblock(["git", "restore", "-sHEAD~1", "f.mbt"]), content="true")
  // A positional tree-ish before `--` is a source too.
  inspect(
    preblock(["git", "checkout", "HEAD~1", "--", "f.mbt"]),
    content="true",
  )
  // ...but `--` with nothing before it is plain index restore.
  inspect(preblock(["git", "checkout", "--", "f.mbt"]), content="false")
  inspect(preblock(["git", "checkout", "-q", "main"]), content="false")
}
```

The `-f` test matches any short cluster containing `f`, which is deliberately
approximate: enumerating git's clustering rules per subcommand would be a second
implementation of getopt, and over-blocking a rare flag costs one refused
command while under-blocking costs an unrecoverable file.

### `clean` and dry runs

`git clean` is blocked because it permanently deletes untracked files — unless it
is a dry run, which is exactly how an agent should be inspecting what would go.

```mbt check
///|
test "clean is blocked unless it is demonstrably a dry run" {
  inspect(preblock(["git", "clean", "-fd"]), content="true")
  inspect(preblock(["git", "clean", "-fdx"]), content="true")
  inspect(preblock(["git", "clean", "-n"]), content="false")
  inspect(preblock(["git", "clean", "--dry-run"]), content="false")
  // In `git clean`, `n` inside a cluster always means dry run.
  inspect(preblock(["git", "clean", "-nfd"]), content="false")
}

///|
test "an exclude pattern makes the dry-run reading untrustworthy" {
  // `-e` takes a pattern operand that can itself look like `-n`, so
  // `git clean -e -n -fd` deletes files while appearing to be a dry run.
  // Rather than reimplement getopt, any clean carrying an exclude stays
  // blocked — including ones that really were dry runs.
  inspect(preblock(["git", "clean", "-e", "-n", "-fd"]), content="true")
  inspect(preblock(["git", "clean", "-e", "*.log", "-n"]), content="true")
  inspect(preblock(["git", "clean", "--exclude=*.log", "-n"]), content="true")
}
```

### `apply` and its read-only modes

`git apply` writes the worktree from a patch file — bytes from outside the object
store — so it is blocked, except in the modes that only validate or describe.

```mbt check
///|
test "apply writes unless it is purely informational" {
  inspect(preblock(["git", "apply", "patch.diff"]), content="true")
  inspect(preblock(["git", "apply", "--check", "patch.diff"]), content="false")
  inspect(preblock(["git", "apply", "--stat", "patch.diff"]), content="false")
  inspect(
    preblock(["git", "apply", "--numstat", "patch.diff"]),
    content="false",
  )
  inspect(
    preblock(["git", "apply", "--summary", "patch.diff"]),
    content="false",
  )
  // A read-only flag alongside a forcing one is treated as writing.
  inspect(
    preblock(["git", "apply", "--check", "--index", "patch.diff"]),
    content="true",
  )
  inspect(
    preblock(["git", "apply", "--stat", "--3way", "p.diff"]),
    content="true",
  )
}
```

## The text path

When `shell` cannot tokenize a command line into a clean argv — pipelines,
substitutions, anything it classifies as TooComplex — it falls back to a flat
word list and a `[start, end)` range. The same policy runs over that shape.

```mbt check
///|
test "text_should_preblock mirrors should_preblock over a word range" {
  // `echo hi | git clean -fd` — the git invocation is words[3..7).
  let words = ["echo", "hi", "|", "git", "clean", "-fd"]
  inspect(@git_policy.text_should_preblock(words, 4, 6), content="true")
  let dry = ["echo", "hi", "|", "git", "clean", "-n"]
  inspect(@git_policy.text_should_preblock(dry, 4, 6), content="false")
}
```

`text_invocation_writes_from_object_store` exists because the text path cannot
see everything the argv path can. A custom environment set *before* `git` — an
assignment the word list does not expose in `words[start..]` — could redirect a
recoverable writer. The caller asks this predicate whether the invocation is one
of those writers, and if so treats the unseen environment as disqualifying.

```mbt check
///|
test "the text path can ask whether the writer is the recoverable kind" {
  let words = ["GIT_DIR=/tmp/x", "git", "checkout", "main"]
  inspect(
    @git_policy.text_invocation_writes_from_object_store(words, 2, 4),
    content="true",
  )
  let read_only = ["GIT_DIR=/tmp/x", "git", "status"]
  inspect(
    @git_policy.text_invocation_writes_from_object_store(read_only, 2, 3),
    content="false",
  )
}
```
