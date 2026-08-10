# agent_tool/shell/internal/git_policy

Pure Git command-line policy for the `shell` source-write sandbox. It parses a
Git invocation and answers three separate questions without filesystem or shell
parser dependencies:

1. Is this a recognized first-party porcelain command?
2. Can that command write a worktree?
3. Does this particular argv select a dangerous form that must be refused before
   execution?

`agent_tool/shell` combines those answers with workspace paths and the runtime
sandbox.

## Policy boundary

Known porcelain composes by default. This is what allows a normal workflow such
as `git fetch && git rebase`: `fetch` is a recognized metadata command and
`rebase` is a recognized worktree writer. Aliases, plumbing, external
`git-foo` commands, and commands whose behavior is defined primarily by an
external program are not recognized and therefore remain sandboxed.

```mbt check
///|
test "recognized porcelain, not aliases or plumbing" {
  for command in ["status", "fetch", "pull", "merge", "rebase", "worktree"] {
    inspect(
      @git_policy.subcommand_is_recognized_porcelain(command),
      content="true",
    )
  }
  for command in ["co", "checkout-index", "commit-tree", "difftool"] {
    inspect(
      @git_policy.subcommand_is_recognized_porcelain(command),
      content="false",
    )
  }
}

///|
test "worktree writers are separate from metadata commands" {
  for command in ["checkout", "merge", "pull", "rebase", "submodule"] {
    inspect(@git_policy.subcommand_may_write_worktree(command), content="true")
  }
  for command in ["add", "commit", "diff", "fetch", "status"] {
    inspect(@git_policy.subcommand_may_write_worktree(command), content="false")
  }
}
```

This is deliberately a convenience/safety tradeoff. Recognized porcelain and
the repository's Git configuration and hooks are trusted. The policy remains a
guardrail, not a hard security boundary.

## Parsing

Global options precede the subcommand and some consume a value. `parse` skips
that region and returns both the literal subcommand and its argv index. It does
not resolve aliases.

```mbt check
///|
fn parsed(argv : Array[String]) -> String {
  match @git_policy.parse(argv, 1) {
    Some(invocation) =>
      "\{invocation.subcommand}@\{invocation.subcommand_index}"
    None => "-"
  }
}

///|
test "global options are skipped" {
  inspect(parsed(["git", "status"]), content="status@1")
  inspect(parsed(["git", "-C", "/tmp", "status"]), content="status@3")
  inspect(parsed(["git", "-c", "user.name=x", "commit"]), content="commit@3")
  inspect(parsed(["git", "--no-pager", "diff"]), content="diff@2")
  inspect(parsed(["git", "co", "main"]), content="co@1")
}

///|
test "unrecognized global shapes fail closed" {
  inspect(parsed(["git", "--not-a-real-option", "status"]), content="-")
  inspect(parsed(["git", "-C"]), content="-")
  inspect(parsed(["git", "--help"]), content="-")
  inspect(parsed(["git"]), content="-")
}
```

Options that repoint config, the exec path, Git directory, namespace, cwd, or
worktree disqualify worktree-writing commands from trust.

```mbt check
///|
test "reconfiguring global options" {
  for
    arg in [
      "-c", "-cfilter.x=y", "--config-env", "--exec-path", "--git-dir", "--namespace",
      "-C", "-C/tmp", "--work-tree", "--work-tree=/tmp",
    ] {
    inspect(@git_policy.global_option_reconfigures(arg), content="true")
  }
  for arg in ["--no-pager", "--bare", "--version", "status"] {
    inspect(@git_policy.global_option_reconfigures(arg), content="false")
  }
}
```

## Dangerous-form blocklist

`should_preblock` returning `true` means refuse before spawning. Returning
`false` means only that this guard has no objection; the trust classifier,
workspace checks, and runtime sandbox still apply.

```mbt check
///|
fn preblock(argv : Array[String]) -> Bool {
  @git_policy.should_preblock(argv, 1)
}

///|
test "ordinary porcelain is not preblocked" {
  inspect(preblock(["git", "fetch", "origin", "main"]), content="false")
  inspect(preblock(["git", "rebase", "origin/main"]), content="false")
  inspect(preblock(["git", "pull", "--rebase"]), content="false")
  inspect(preblock(["git", "merge", "main"]), content="false")
  inspect(preblock(["git", "cherry-pick", "HEAD~1"]), content="false")
  inspect(preblock(["git", "worktree", "add", "../wt"]), content="false")
}

///|
test "external byte sources and permanent loss are blocked" {
  inspect(preblock(["git", "apply", "patch.diff"]), content="true")
  inspect(preblock(["git", "am", "patch.mbox"]), content="true")
  inspect(preblock(["git", "update-index", "--index-info"]), content="true")
  inspect(preblock(["git", "mv", "notes", "main.mbt"]), content="true")
  inspect(preblock(["git", "clean", "-fd"]), content="true")
  inspect(
    preblock(["git", "worktree", "remove", "--force", "../wt"]),
    content="true",
  )
  inspect(
    preblock(["git", "worktree", "move", "../wt", "../moved"]),
    content="true",
  )
}

///|
test "explicit command runners are blocked" {
  inspect(preblock(["git", "rebase", "-i", "main"]), content="true")
  inspect(preblock(["git", "rebase", "--exec", "cmd", "main"]), content="true")
  inspect(preblock(["git", "bisect", "run", "./test.sh"]), content="true")
  inspect(preblock(["git", "merge", "-s", "external", "main"]), content="true")
  inspect(preblock(["git", "pull", "--rebase=interactive"]), content="true")
}

///|
test "read-only exceptions remain available" {
  inspect(preblock(["git", "apply", "--check", "patch.diff"]), content="false")
  inspect(preblock(["git", "apply", "--stat", "patch.diff"]), content="false")
  inspect(preblock(["git", "clean", "-fdn"]), content="false")
  inspect(preblock(["git", "clean", "--dry-run"]), content="false")
}

///|
test "reconfigured writers are blocked" {
  inspect(
    preblock(["git", "-c", "filter.x.smudge=cmd", "checkout", "main"]),
    content="true",
  )
  inspect(
    preblock(["git", "-C", "/elsewhere", "merge", "main"]),
    content="true",
  )
}
```

## Degraded text path

Too-complex shell strings are scanned as a flat word range. The text-path APIs
mirror the argv decisions and identify custom-environment worktree writers.

```mbt check
///|
test "text path mirrors the blocklist" {
  let words = ["echo", "hi", "|", "git", "clean", "-fd"]
  inspect(@git_policy.text_should_preblock(words, 4, 6), content="true")
  let dry = ["echo", "hi", "|", "git", "clean", "-n"]
  inspect(@git_policy.text_should_preblock(dry, 4, 6), content="false")
}

///|
test "text path distinguishes fetch from rebase" {
  let fetch = ["GIT_DIR=/tmp/x", "git", "fetch", "origin"]
  inspect(
    @git_policy.text_invocation_may_write_worktree(fetch, 2, 4),
    content="false",
  )
  let rebase = ["GIT_DIR=/tmp/x", "git", "rebase", "main"]
  inspect(
    @git_policy.text_invocation_may_write_worktree(rebase, 2, 4),
    content="true",
  )
}
```
