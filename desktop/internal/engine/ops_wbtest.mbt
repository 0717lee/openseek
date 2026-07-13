///|
#cfg(not(platform="windows"))
async test "one-shot session engine overrides ambient OPENSEEK_DIR" {
  let previous = @sys.get_env_var("OPENSEEK_DIR")
  @sys.set_env_var("OPENSEEK_DIR", "/missing/openseek-dir")
  let dir = @fs.tmpdir(prefix="openseek-session-env-")
  let engine = dir + "/engine.sh"
  @fs.write_file(
    engine,
    "#!/bin/sh\nprintf '%s' \"$OPENSEEK_DIR\"\n",
    create_mode=CreateOrTruncate,
  )
  let chmod = @process.run("chmod", ["+x", engine])
  assert_eq(chmod, 0)
  let manager = new_engine_manager(engine)
  let output = engine_stdout(manager, []) catch {
    error => {
      restore_openseek_dir(previous)
      @fs.rmdir(dir, recursive=true) catch {
        _ => ()
      }
      raise error
    }
  }
  restore_openseek_dir(previous)
  @fs.rmdir(dir, recursive=true)
  assert_eq(output, ".")
}

///|
fn restore_openseek_dir(previous : String?) -> Unit {
  if previous is Some(value) {
    @sys.set_env_var("OPENSEEK_DIR", value)
  } else {
    @sys.unset_env_var("OPENSEEK_DIR")
  }
}

///|
async test "compaction rejects an empty session before addressing a slot" {
  let manager = new_engine_manager("unused")
  let payload : @protocol.CompactPayload = {
    session: "",
    api_key: None,
    api_url: None,
    model: None,
    max_steps: None,
    session_root: None,
    workspace: None,
    wsl: None,
  }
  let message = try compact_run(manager, payload) catch {
    EngineError(message) => message
    _ => fail("expected EngineError")
  } noraise {
    _ => ""
  }
  assert_eq(message, "session id must not be empty")
}
