///|
/// A snippet is bounded to this wall-clock so a runaway loop or a build that
/// never finishes cannot block the whole turn. On expiry the run is cancelled
/// (which tears down the moon subprocess) and reported as a timeout.
const RunTimeoutMs : Int = 60_000

///|
/// Output is streamed to a file on disk, not buffered in memory, so a snippet
/// that floods stdout (e.g. `while true { println(…) }`) cannot exhaust the
/// agent's memory before the timeout fires. Only this many bytes are read back
/// — the rest is dropped with a truncation marker.
const OutputCapBytes : Int = 48_000

///|
/// Best-effort refusal of the two obvious native escapes: process spawning
/// (`moonbitlang/async/process` — the `shell` tool owns commands) and native
/// FFI (`extern`, which can bind libc `system`). A substring scan is NOT a
/// real boundary — a determined native snippet can still escape — so HARD
/// containment is deferred to the planned wasm backend (safe by construction).
/// Until then this closes the trivial escapes and keeps descendant processes
/// from outliving the timeout. Returns the reason to report, or None.
fn native_escape(source : String) -> String? {
  if source.contains("moonbitlang/async/process") {
    Some(
      "spawns processes (moonbitlang/async/process) — use the shell tool for commands",
    )
  } else if source.contains("extern") {
    Some("uses native FFI (extern), which the wasm sandbox will contain later")
  } else {
    None
  }
}

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
  guard native_escape(input.source) is None else {
    return @agent_tool.ToolAction::respond(
      "run_moonbit refuses this program: it \{native_escape(input.source).unwrap()}. run_moonbit is the compute/IO surface; deeper containment arrives with the wasm backend.",
      is_error=true,
    )
  }
  // Run the snippet as a `.mbtx` single-file script in a throwaway directory:
  // moon's single-file runner handles the inline import block, so there is no
  // module to scaffold. `with_tmpdir` is the OUTER scope so its cleanup runs on
  // the normal (uncancelled) path even when the timeout fires; the timeout
  // wraps only the process body. Output is redirected to a file (not buffered
  // in memory) and read back capped, so a flood cannot exhaust memory.
  @vfs.with_tmpdir(prefix="openseek-run-moonbit-", dir => {
    @fs.write_file(
      "\{dir}/snippet.mbtx",
      input.source,
      create_mode=CreateOrTruncate,
    )
    let log = "\{dir}/output.log"
    // Pre-create the merged output file so both redirects open it; both append
    // so stdout and stderr interleave in write order.
    @fs.write_file(log, "", create_mode=CreateOrTruncate)
    let result = @async.with_timeout_opt(RunTimeoutMs, () => {
      let exit_code = @process.run(
        "moon",
        ["run", "snippet.mbtx", "--target", input.target],
        cwd=dir,
        inherit_env=true,
        stdout=@process.redirect_to_file(log, append=true),
        stderr=@process.redirect_to_file(log, append=true),
      )
      (exit_code, read_capped(log))
    })
    match result {
      Some((exit_code, raw)) => {
        // moon's diagnostics point at the throwaway temp file (the source is
        // copied into `_build/snippet.mbt`; line:col stay faithful to the
        // source). Rewrite that path to `source` so the model reads
        // `source:LINE:COL` about its own input, not a random temp path.
        let real = @fs.realpath(dir) catch { _ => dir }
        let text = raw
          .replace_all(old="\{real}/_build/snippet.mbt", new="source")
          .replace_all(old="\{real}/snippet.mbtx", new="source")
          .replace_all(old="\{dir}/_build/snippet.mbt", new="source")
          .replace_all(old="\{dir}/snippet.mbtx", new="source")
        // PREPEND the exit status so it survives the agent loop's outer 60k
        // result clamp (which cuts the tail); the output cap is below 60k so
        // both the status line and the body are retained.
        let body = if text.trim() == "" {
          "run_moonbit: program exited \{exit_code} with no output"
        } else if exit_code != 0 {
          "[run_moonbit: exited \{exit_code}]\n\{text}"
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
  })
}

///|
/// Read at most `OutputCapBytes` from the process output file, decoding lossily
/// and appending a marker when there was more. The file — not memory — absorbs
/// a flood; only this bounded prefix is ever materialized.
async fn read_capped(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly) catch { _ => return "" }
  defer file.close()
  let buf = FixedArray::make(OutputCapBytes, b'\x00')
  let mut filled = 0
  while filled < OutputCapBytes {
    let n = file.read(buf, offset=filled, max_len=OutputCapBytes - filled)
    if n <= 0 {
      break
    }
    filled += n
  }
  let text = @utf8.decode_lossy(Bytes::from_array(buf[:filled]))
  // If we filled the cap there may be more; note the truncation.
  if filled == OutputCapBytes {
    "\{text}\n[run_moonbit: output truncated at \{OutputCapBytes} bytes]"
  } else {
    text
  }
}
