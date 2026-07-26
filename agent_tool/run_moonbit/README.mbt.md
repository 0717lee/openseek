# run_moonbit

Compile and run a **self-contained MoonBit program** and return its merged
stdout/stderr and exit status. It is the agent's way to *script in MoonBit* —
for automation (read and transform files, parse JSON, compute) and for probing
how a language feature behaves — instead of reaching for shell `python`/`node`.
The more the agent scripts in MoonBit, the more fluent it gets, and the safe
wasm backend (planned) makes it the natural sandboxed automation surface.

## How it works

The `source` is a `.mbtx` **single-file script** — MoonBit's own one-file
program format. The tool does nothing clever: it writes `source` to a throwaway
temp file and runs `moon run <file>.mbtx --target <target> --target-dir <temp>`
**with your workspace as the working directory**, returns what moon prints,
removes the temp dir, and enforces a 60s bound. Because the working directory is
the workspace, relative paths like `@fs.read_file("data.json")` reach workspace
files and anything the program writes lands in the workspace — while all build
artifacts stay in the temp dir, so your `_build` is never touched. moon's
single-file runner handles the inline import block; moon's own compiler
diagnostics are the error message when something does not build.

## Arguments

- `source` (string, required): a full `.mbtx` program. It may open with an
  inline `import { "pkg", "pkg", … }` block (comma-separated module paths),
  then the program including its own `main`. Use `async fn main` for
  filesystem/stdio work.
- `target` (string, optional, default `native`): the backend — one of
  `native`, `wasm`, `wasm-gc`, `js`, `llvm`. The async IO packages
  (`@fs`, `@stdio`, `@process`) require `native`.
- `cwd` (string, optional, default workspace root): the working directory the
  program runs in. A relative `cwd` resolves against the workspace root, like
  the `shell` tool.
- `warning` (string, optional, `"off"`/`"on"`, default `"off"`): whether
  compiler warnings appear in the output. Snippets are throwaway scripts, so
  unused-value style noise is suppressed unless the warnings themselves are
  what you are probing. Selected correctness diagnostics whose default state
  is `error` (such as `partial_match`) are maintained as explicit mnemonic
  exceptions and still fail compilation with warnings off.

Only **dependency resolution** is isolated: a local-package import resolves to
the **published registry snapshot** (not your uncommitted edits), and a
third-party import resolves to its **latest** registry version, which can differ
from your workspace's pinned versions — so verify dependency-API probes against
the workspace, not run_moonbit. Use it for self-contained scripts; to exercise
your working-tree code, add a `*_test.mbt` to that package and run `moon test`
via shell.

## Source-file protection

Because the program runs in your workspace, on **macOS** the run is wrapped in
`sandbox-exec` with a profile that **denies direct writes to protected source
files** (`*.mbt`, `*.mbti`, `*.mbt.md`, `moon.mod`/`moon.pkg`/`moon.work`)
anywhere except the throwaway build dir — the same profile the `shell` tool
uses. A snippet can still read anything and write non-source outputs (e.g.
`people.json`).

A denied write surfaces inside the program as a bare OS error (e.g.
`OSError("@fs.open(): \"keep.mbt\": Operation not permitted")`), which on its
own reads like a filesystem fault. When a sandboxed run's output shows such a
denial on a protected source path, the tool result appends an explanation: the
sandbox denied the write by design, the snippet should not try to work around
it, and source changes belong to the `edit` tool. The run is reported as an
error even if the snippet caught the failure and exited 0, matching `shell`.

This is **best-effort, not a hard boundary**: `shell` also statically preflights
its command text to catch directory-rename tricks, which is impossible for an
arbitrary snippet — so a determined program can still smuggle sources in or out
via directory renames. Treat it as a guard against accidental source clobbering,
not a security boundary; full containment is the planned wasm backend's job. On
non-macOS hosts (or inside a nested sandbox that cannot enforce) the run is
unsandboxed.

## Examples

A quick language probe — no imports, pure core:

```mbt check
///|
async test "run_moonbit runs a pure-core probe" {
  let action = match @run_moonbit.definition(workspace_root=".").execute {
    Async(execute) =>
      execute({ "source": "fn main { println([1, 2, 3].map(x => x * x)) }" })
    Sync(_) => fail("run_moonbit is async")
  }
  debug_inspect(
    action,
    content=(
      #|Respond(
      #|  {
      #|    content: "[1, 4, 9]\n",
      #|    is_error: false,
      #|    brief: Some("run_moonbit (exit=0)"),
      #|  },
      #|)
    ),
  )
}
```

The workspace root is also the snippet's default working directory, so a
checked example can exercise real file IO through a relative path:

```mbt check
///|
async test "run_moonbit reads a workspace file" {
  @vfs.with_tmpdir(prefix="run-moonbit-readme-io-", workspace => {
    @fs.write_file(
      workspace + "/data.txt",
      "Ada\nGrace\n",
      create_mode=CreateOrTruncate,
    )
    let source =
      #|import { "moonbitlang/async", "moonbitlang/async/fs", "moonbitlang/async/stdio" }
      #|
      #|async fn main {
      #|  let text = @fs.read_file("data.txt").text()
      #|  let lines = [..text.split("\n")].filter(line => !line.is_empty())
      #|  @stdio.stdout.write("lines=\{lines.length()}\n")
      #|}
    let action = match
      @run_moonbit.definition(workspace_root=workspace).execute {
      Async(execute) => execute({ "source": source })
      Sync(_) => fail("run_moonbit is async")
    }
    debug_inspect(
      action,
      content=(
        #|Respond(
        #|  {
        #|    content: "lines=2\n",
        #|    is_error: false,
        #|    brief: Some("run_moonbit (exit=0)"),
        #|  },
        #|)
      ),
    )
  })
}
```

Pure snippets can select another supported backend explicitly:

```mbt check
///|
async test "run_moonbit accepts an explicit target" {
  let action = match @run_moonbit.definition(workspace_root=".").execute {
    Async(execute) =>
      execute({ "source": "fn main { println(6 * 7) }", "target": "js" })
    Sync(_) => fail("run_moonbit is async")
  }
  debug_inspect(
    action,
    content=(
      #|Respond(
      #|  {
      #|    content: "42\n",
      #|    is_error: false,
      #|    brief: Some("run_moonbit (exit=0)"),
      #|  },
      #|)
    ),
  )
}
```

Warnings are quiet by default and can be restored for diagnostic probes:

```mbt check
///|
async test "run_moonbit can show compiler warnings" {
  @vfs.with_tmpdir(prefix="run-moonbit-readme-warning-", workspace => {
    let execute = match
      @run_moonbit.definition(workspace_root=workspace).execute {
      Async(execute) => execute
      Sync(_) => fail("run_moonbit is async")
    }
    let source = "fn main { let unused = 1; println(\"done\") }"
    let quiet = execute({ "source": source })
    let loud = execute({ "source": source, "warning": "on" })
    guard quiet is Respond(quiet_output) else { fail("expected Respond") }
    guard loud is Respond(loud_output) else { fail("expected Respond") }
    assert_false(quiet_output.is_error)
    assert_false(quiet_output.content.contains("Warning"))
    assert_false(loud_output.is_error)
    assert_true(loud_output.content.contains("unused"))
  })
}
```

Reading and transforming a file (what you pass as `source`) — note the inline
import block, with `moonbitlang/async` present so `async fn main` compiles:

```mbt nocheck
///|
import {
  "moonbitlang/async",
  "moonbitlang/async/fs",
  "moonbitlang/async/stdio",
}

///|
async fn main {
  let text = @fs.read_file("data.txt").text()
  let lines = [..text.split("\n")].filter(l => !l.is_empty())
  @stdio.stdout.write("lines=\{lines.length()}\n")
}
```

Probing a language feature (what you pass as `source`):

```mbt nocheck
///|
fn main {
  let classify = c => {
    match c {
      'a'..='z' => "lower"
      '0'..='9' => "digit"
      _ => "other"
    }
  }
  println(classify('k'))
  println(classify('7'))
}
```
