///|
/// The async runtime version the ephemeral package pins — kept in lockstep with
/// the module's own `moon.mod` so the batteries resolve against the same cached
/// snapshot the agent builds with.
const AsyncVersion : String = "0.20.1"

///|
/// The battery allowlist: `@alias` → (module path, whether it needs the async
/// dependency in `moon.mod`). This map IS the sandbox boundary — a snippet may
/// only import these standard automation packages. An `@alias` that is not
/// here (a local package like `@agent_tool`, or an unmapped one) is refused
/// with a pointer to the test-file path, which is how local code is exercised.
fn battery(pkg_alias : String) -> (String, Bool)? {
  match pkg_alias {
    "async" => Some(("moonbitlang/async", true))
    "fs" => Some(("moonbitlang/async/fs", true))
    "stdio" => Some(("moonbitlang/async/stdio", true))
    "io" => Some(("moonbitlang/async/io", true))
    "process" => Some(("moonbitlang/async/process", true))
    "json" => Some(("moonbitlang/core/json", false))
    "strconv" => Some(("moonbitlang/core/strconv", false))
    "math" => Some(("moonbitlang/core/math", false))
    "buffer" => Some(("moonbitlang/core/buffer", false))
    "env" => Some(("moonbitlang/core/env", false))
    "random" => Some(("moonbitlang/core/random", false))
    "list" => Some(("moonbitlang/core/immut/list", false))
    _ => None
  }
}

///|
/// True for the characters that make up a package alias after `@`.
fn is_alias_char(code : UInt16) -> Bool {
  code is ('a'..='z' | '0'..='9' | '_')
}

///|
/// Every distinct alias used in `@alias.` position, in first-seen order. A
/// deliberately simple scan: it can match an alias mentioned inside a string
/// or comment, which at worst adds an unused import (a warning, not a failure)
/// or a spurious refusal — acceptable for short automation snippets.
fn used_aliases(source : String) -> Array[String] {
  let out : Array[String] = []
  let seen : Set[String] = Set([])
  let n = source.length()
  let mut i = 0
  while i < n {
    if source[i] == '@' {
      let start = i + 1
      let mut j = start
      while j < n && is_alias_char(source[j]) {
        j += 1
      }
      if j > start && j < n && source[j] == '.' {
        let name = source[start:j].to_owned()
        if !seen.contains(name) {
          seen.add(name)
          out.push(name)
        }
      }
      i = j
    } else {
      i += 1
    }
  }
  out
}

///|
/// Resolve the snippet's `@alias.` uses to import lines, or a refusal message
/// naming the first alias that is not a standard automation battery.
fn resolve_imports(source : String) -> Result[(Array[String], Bool), String] {
  let imports : Array[String] = []
  let mut needs_async = false
  for pkg_alias in used_aliases(source) {
    match battery(pkg_alias) {
      Some((path, async_dep)) => {
        imports.push(path)
        if async_dep {
          needs_async = true
        }
      }
      None =>
        return Err(
          "run_moonbit imports only the standard automation packages (fs, stdio, io, process, json, strconv, math, buffer, env, random, list). `@\{pkg_alias}` is not one of them — if it is a local package, exercise it by adding a `*_test.mbt` to that package and running `moon test -p <pkg>`; run_moonbit is for self-contained scripts and language probes.",
        )
    }
  }
  Ok((imports, needs_async))
}

///|
/// Assemble the ephemeral module's `moon.mod`. It pins the async snapshot only
/// when a battery needs it, so a pure-core snippet has no external deps.
fn module_manifest(needs_async : Bool) -> String {
  if needs_async {
    (
      #|name = "local/run_moonbit"
      #|import { "moonbitlang/async@$VER" }
      #|
    ).replace_all(old="$VER", new=AsyncVersion)
  } else {
    (
      #|name = "local/run_moonbit"
      #|
    )
  }
}

///|
/// Assemble the ephemeral runner package's `moon.pkg` from the inferred imports.
fn package_manifest(imports : Array[String], needs_async : Bool) -> String {
  // The bare `moonbitlang/async` package must be in scope for `async fn main`
  // to compile — its error/effect handling needs it even when only a
  // subpackage (`@fs`, `@stdio`, …) is used directly.
  let all = if needs_async && !imports.contains("moonbitlang/async") {
    ["moonbitlang/async", ..imports]
  } else {
    imports
  }
  let sb = StringBuilder()
  if all.length() > 0 {
    sb.write_string("import {\n")
    for path in all {
      sb.write_string("  \"\{path}\",\n")
    }
    sb.write_string("}\n")
  }
  sb.write_string("supported_targets = \"native\"\n")
  sb.write_string("options(\"is-main\": true)\n")
  sb.to_string()
}

///|
/// Tool definition for `run_moonbit`: compile and run a self-contained MoonBit
/// program in an ephemeral, isolated package, returning its merged
/// stdout/stderr and exit status. For scripting automation and language
/// probes — the source imports only standard batteries, never local packages
/// (see `resolve_imports`), so it is worktree-safe and cannot go stale.
///
/// ## Arguments
/// - `source` (string, required): a full top-level MoonBit program, including
///   its own `main`. Use `async fn main` for filesystem/stdio/process work
///   (the package builds on the native target). Reference batteries as
///   `@fs`, `@json`, `@stdio`, etc.; they are imported automatically.
///
/// ## Result
/// - `Respond(ToolOutput(<merged output>))` when the program exits 0.
/// - `Respond(ToolOutput(<compiler or runtime output>, is_error=true))` when
///   it fails to compile or exits non-zero — moon's own diagnostics are the
///   feedback.
/// - `Respond(ToolOutput("run_moonbit imports only ...", is_error=true))` when
///   the source references a non-battery (e.g. a local) package.
pub fn definition() -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="run_moonbit",
    description="Compile and run a self-contained MoonBit program and return its merged stdout/stderr and exit status. Use this for scripting automation (read/transform files, parse JSON, compute) and for probing MoonBit language behavior — PREFER it over shell python/node so the automation is MoonBit. `source` is a full top-level program including its own `main`; use `async fn main` for IO. Reference standard packages as `@fs`, `@json`, `@stdio`, `@strconv`, `@math`, `@buffer`, `@env`, `@process`, `@io`, `@random`, `@list` — they are imported automatically. It runs in an isolated ephemeral package and CANNOT import local packages: to exercise a local package, add a `*_test.mbt` to it and run `moon test` via shell instead.",
    schema=JsonSchema({
      "type": "object",
      "properties": { "source": { "type": "string" } },
      "required": ["source"],
    }),
    execute=Async(execute),
  )
}

///|
async fn execute(arguments : Json) -> @agent_tool.ToolAction {
  let input = @decode.decode(arguments) catch {
    error =>
      return @agent_tool.ToolAction::respond(
        "error: run_moonbit requires \{@tool_error.failure_message("\{error}")}",
        is_error=true,
      )
  }
  let (imports, needs_async) = match resolve_imports(input.source) {
    Ok(pair) => pair
    Err(message) =>
      return @agent_tool.ToolAction::respond(message, is_error=true)
  }
  @vfs.with_tmpdir(prefix="openseek-run-moonbit-", dir => {
    @fs.write_file(
      "\{dir}/moon.mod",
      module_manifest(needs_async),
      create_mode=CreateOrTruncate,
    )
    @fs.mkdir("\{dir}/run", recursive=true)
    @fs.write_file(
      "\{dir}/run/moon.pkg",
      package_manifest(imports, needs_async),
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{dir}/run/main.mbt",
      input.source,
      create_mode=CreateOrTruncate,
    )
    let (exit_code, output) = @process.collect_output_merged(
      "moon",
      ["run", "run", "--target", "native"],
      cwd=dir,
      inherit_env=true,
    )
    let text = output.text()
    let body = if text.trim() == "" {
      "run_moonbit: program exited \{exit_code} with no output"
    } else {
      text
    }
    @agent_tool.ToolAction::respond(
      body,
      is_error=exit_code != 0,
      brief="run_moonbit (exit=\{exit_code})",
    )
  })
}
