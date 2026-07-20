///|
/// A snippet is bounded to this wall-clock so a runaway loop or a build that
/// never finishes cannot block the whole turn. On expiry the run is cancelled
/// (which tears down the moon subprocess) and reported as a timeout.
const RunTimeoutMs : Int = 60_000

///|
/// Tool definition for `run_moonbit`: compile and run a self-contained MoonBit
/// program and return its merged stdout/stderr and exit status.
///
/// The program is a `.mbtx` single-file script — it may open with an inline
/// `import { "pkg", … }` block (comma-separated module paths) naming the
/// standard packages it uses, followed by the program including its own
/// `main`. It runs via `moon run` in a throwaway temp directory that is not
/// part of the working-tree module, so it is not part of your
/// module — its build artifacts never touch your `_build`, and any
/// local-package import resolves to the published registry snapshot (so this
/// is for self-contained scripts; use a `*_test.mbt` + `moon test` for
/// working-tree code).
///
/// Note: the snippet runs on the native backend today with no capability
/// sandbox — the isolation is the throwaway package. Hard containment is
/// deferred to the planned wasm backend, where the runtime is safe by
/// construction and policy is applied there.
pub fn definition() -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name="run_moonbit",
    description="Compile and run a self-contained MoonBit program (a `.mbtx` single-file script) and return its merged stdout/stderr and exit status. Use this for scripting automation (read/transform files, parse JSON, compute) and for probing MoonBit language behavior — PREFER it over shell python/node so the automation is MoonBit. `source` may begin with an inline `import { \"pkg\", ... }` block (comma-separated module paths such as `\"moonbitlang/async\", \"moonbitlang/async/fs\", \"moonbitlang/core/json\"`) followed by the program including its own `main`; use `async fn main` for IO (add `\"moonbitlang/async\"` to the import block for it). It runs isolated from your working tree: a local-package import resolves to the published registry snapshot (NOT your uncommitted edits), so use this for self-contained scripts — to exercise your working-tree code, add a `*_test.mbt` to that package and run `moon test` via shell instead. Bounded to 60s.",
    schema=JsonSchema({
      "type": "object",
      "properties": {
        "source": { "type": "string" },
        "target": {
          "type": "string",
          "enum": ["native", "wasm", "wasm-gc", "js", "llvm"],
          "description": "Backend to run on; defaults to native (required for the async @fs/@stdio/@process IO batteries).",
        },
      },
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
  // Run the snippet as a `.mbtx` single-file script in a throwaway directory:
  // moon's own single-file runner handles the inline import block, so there is
  // no module to scaffold. The temp dir gives the snippet an isolated cwd (for
  // relative `@fs` paths) and keeps build artifacts off the working tree.
  let result = @async.with_timeout_opt(RunTimeoutMs, () => {
    @vfs.with_tmpdir(prefix="openseek-run-moonbit-", dir => {
      @fs.write_file(
        "\{dir}/snippet.mbtx",
        input.source,
        create_mode=CreateOrTruncate,
      )
      let (exit_code, output) = @process.collect_output_merged(
        "moon",
        ["run", "snippet.mbtx", "--target", input.target],
        cwd=dir,
        inherit_env=true,
      )
      // moon's diagnostics point at the throwaway temp file (the source is
      // copied into `_build/snippet.mbt` for the build, and line:col stay
      // faithful to the source). Rewrite that path to `source` so the model
      // reads `source:LINE:COL` about its own input, not a random temp path.
      let real = @fs.realpath(dir) catch { _ => dir }
      let cleaned = output
        .text()
        .replace_all(old="\{real}/_build/snippet.mbt", new="source")
        .replace_all(old="\{real}/snippet.mbtx", new="source")
        .replace_all(old="\{dir}/_build/snippet.mbt", new="source")
        .replace_all(old="\{dir}/snippet.mbtx", new="source")
      (exit_code, cleaned)
    })
  })
  match result {
    Some((exit_code, text)) => {
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
    }
    None =>
      @agent_tool.ToolAction::respond(
        "run_moonbit: timed out after \{RunTimeoutMs / 1000}s and was cancelled — the program did not finish (an infinite loop, or a build that never completed).",
        is_error=true,
        brief="run_moonbit (timeout)",
      )
  }
}
