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

Only **dependency resolution** is isolated: a local-package import resolves to
the **published registry snapshot** (not your uncommitted edits), and a
third-party import resolves to its **latest** registry version, which can differ
from your workspace's pinned versions — so verify dependency-API probes against
the workspace, not run_moonbit. Use it for self-contained scripts; to exercise
your working-tree code, add a `*_test.mbt` to that package and run `moon test`
via shell.

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
  guard action is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("[1, 4, 9]"))
}
```

Reading and transforming a file (what you pass as `source`) — note the inline
import block, with `moonbitlang/async` present so `async fn main` compiles:

```mbt nocheck
import { "moonbitlang/async", "moonbitlang/async/fs", "moonbitlang/async/stdio" }

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
