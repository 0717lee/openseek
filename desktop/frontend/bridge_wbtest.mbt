///|
test "start payload preserves frontend normalization policy" {
  let payload = start_payload(
    "  task stays verbatim  ",
    "  model-x  ",
    "19.75",
    "  secret  ",
    "   ",
    "  desktop-1  ",
    workspace=Some(Absolute("  /work/project  ")),
    wsl_enabled=true,
    wsl_distro="   ",
    wsl_engine="  openseek-dev  ",
  )
  assert_eq(payload.task, "  task stays verbatim  ")
  assert_true(payload.model is Some("model-x"))
  assert_true(payload.max_steps is Some(19))
  assert_true(payload.api_key is Some("secret"))
  assert_true(payload.api_url is None)
  assert_true(payload.session is Some("desktop-1"))
  assert_true(payload.session_root is None)
  assert_true(payload.workspace is Some("/work/project"))
  guard payload.wsl is Some(wsl) else { fail("expected WSL opt-in") }
  assert_true(wsl.distro is None)
  assert_true(wsl.engine is Some("openseek-dev"))

  let defaults = start_payload(
    "task",
    "",
    "0",
    "",
    "",
    "session",
    workspace=None,
    wsl_enabled=false,
    wsl_distro="Ubuntu",
    wsl_engine="openseek",
  )
  assert_true(defaults.max_steps is None)
  assert_true(defaults.workspace is None)
  assert_true(defaults.wsl is None)
}

///|
test "compact payload preserves frontend normalization policy" {
  let payload = compact_payload(
    session="  desktop-1  ",
    model="  model-x  ",
    max_steps="19.75",
    api_key="  secret  ",
    api_url="   ",
    workspace=Absolute("  /work/project  "),
    wsl_enabled=true,
    wsl_distro="   ",
    wsl_engine="  openseek-dev  ",
  )
  assert_eq(payload.session, "desktop-1")
  assert_true(payload.model is Some("model-x"))
  assert_true(payload.max_steps is Some(19))
  assert_true(payload.api_key is Some("secret"))
  assert_true(payload.api_url is None)
  assert_true(payload.session_root is None)
  assert_true(payload.workspace is Some("/work/project"))
  guard payload.wsl is Some(wsl) else { fail("expected WSL opt-in") }
  assert_true(wsl.distro is None)
  assert_true(wsl.engine is Some("openseek-dev"))

  let blank = compact_payload(
    session="   ",
    model="",
    max_steps="",
    api_key="",
    api_url="",
    wsl_enabled=false,
    wsl_distro="",
    wsl_engine="",
  )
  assert_eq(blank.session, "")
}
