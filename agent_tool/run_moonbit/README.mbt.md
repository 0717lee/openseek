# run_moonbit

Compile and run a **self-contained MoonBit program** in an ephemeral, isolated
package, returning its merged stdout/stderr and exit status. It is the agent's
way to *script in MoonBit* — for automation (read and transform files, parse
JSON, compute) and for probing how a MoonBit language feature behaves —
instead of reaching for shell `python`/`node`.

Why a dedicated tool:

- **No shell quoting.** `source` is a structured argument, so a program with
  quotes, `$`, backticks, and `\{}` interpolation goes straight to disk — no
  double-escaping through the shell.
- **Sandboxed by an allowlist.** The snippet may import only a curated set of
  standard *batteries* (below) — notably NOT process spawning, which stays
  behind the sandboxed `shell` tool. A non-battery `@alias` — a local package
  like `@agent_tool`, or `@process` — is refused with a pointer elsewhere.
- **Worktree-safe, never stale.** It runs in an isolated module (its own
  `moon.mod`/`_build`/lock in a temp dir) that imports only pinned registry
  batteries. It never touches the working-tree module, so it cannot pick up a
  stale snapshot or contend with your `moon build` — unlike `moon run -e`.
- **MoonBit is the point.** Every script the agent writes here is MoonBit
  practice, and moon's own compiler diagnostics are captured verbatim as the
  feedback when something does not compile.

## Argument

- `source` (string, required): a full top-level MoonBit program including its
  own `main`. Use `async fn main` for filesystem/stdio/process work (the
  package builds on the native target). Reference batteries as `@fs`, `@json`,
  `@stdio`, …; they are imported automatically from your `@alias.` uses.

## Batteries (the allowlist)

`fs`, `stdio`, `io` (from `moonbitlang/async`), and `json`,
`strconv`, `math`, `buffer`, `env`, `random`, `list` (from `moonbitlang/core`).
Anything else is refused — for a **local** package, exercise it by adding a
`*_test.mbt` to that package and running `moon test`, which has full,
worktree-safe access to it.

## Examples

A quick language probe — no batteries, pure core:

```mbt check
///|
async test "run_moonbit runs a pure-core probe" {
  let action = match @run_moonbit.definition().execute {
    Async(execute) =>
      execute({ "source": "fn main { println([1, 2, 3].map(x => x * x)) }" })
    Sync(_) => fail("run_moonbit is async")
  }
  guard action is Respond(output) else { fail("expected Respond") }
  assert_false(output.is_error)
  assert_true(output.content.contains("[1, 4, 9]"))
}
```

Reading and transforming a file (what you pass as `source`):

```mbt nocheck
///|
async fn main {
  let text = @fs.read_file("data.json").text()
  let json = @json.parse(text)
  guard json is Array(items) else { return }
  @stdio.stdout.write("items=\{items.length()}\n")
}
```

Probing a language feature (what you pass as `source`):

```mbt nocheck
///|
fn main {
  // Does a range pattern match the way I expect?
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

A non-battery import is refused rather than silently resolved:

```mbt nocheck
// source: fn main { println(@agent_tool.brief_basename("a/b")) }
// -> error: run_moonbit imports only the standard automation packages …
//    `@agent_tool` is not one of them — if it is a local package, exercise it
//    by adding a `*_test.mbt` to that package and running `moon test`.
```
