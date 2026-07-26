///|
/// Run a wrapped command and materialize its merged output as text — the same
/// consumption pattern real callers use, so the tests exercise the capability
/// exactly as shipped.
async fn merged_output_text(command : @sandbox.ProcessCommand) -> (Int, String) {
  @async.with_task_group() <| group => {
    let (reader, writer) = @process.read_from_process()
    defer reader.close()
    let child = @process.spawn(
      group,
      command.program,
      command.args,
      stdout=writer,
      stderr=writer,
      no_wait=true,
    )
    let mut text = ""
    while reader.read_some(max_len=4096) is Some(chunk) {
      text += @utf8.decode_lossy(chunk)
    }
    (child.wait(), text)
  }
}

///|
/// The capability surface, end to end where the platform allows: acquire,
/// wrap, run, classify. Guarded on real availability so the suite passes
/// (by skipping) where `sandbox-exec` cannot enforce.
async test "sandbox denies a source write and the classifier recognizes it" {
  @vfs.with_tmpdir(prefix="openseek-sandbox-capability-", dir => {
    guard @sandbox.SourceWriteSandbox::create_if_available(dir) is Some(sandbox) else {
      return
    }
    let wrapped = sandbox.wrap_shell_command("printf x > \{dir}/new.mbt")
    let (exit_code, text) = merged_output_text(wrapped.command)
    assert_true(exit_code != 0)
    // The write never landed, and the classifier recognizes the denial.
    assert_false(@fs.exists("\{dir}/new.mbt"))
    assert_true(wrapped.denial_classifier.output_reports_denial(text))
    // Unrelated output does not classify as a denial.
    assert_false(wrapped.denial_classifier.output_reports_denial("compiled ok"))
  })
}

///|
async test "a writable subtree is re-allowed; the rest stays denied" {
  @vfs.with_tmpdir(prefix="openseek-sandbox-capability-lab-", dir => {
    @fs.mkdir("\{dir}/lab")
    guard @sandbox.SourceWriteSandbox::create_if_available(
        dir,
        writable_subtree="\{dir}/lab",
      )
      is Some(sandbox) else {
      return
    }
    let allowed = sandbox.wrap_shell_command("printf x > \{dir}/lab/draft.mbt")
    let (lab_exit, _) = merged_output_text(allowed.command)
    assert_eq(lab_exit, 0)
    assert_true(@fs.exists("\{dir}/lab/draft.mbt"))
    let denied = sandbox.wrap_shell_command("printf x > \{dir}/new.mbt")
    let (root_exit, _) = merged_output_text(denied.command)
    assert_true(root_exit != 0)
    assert_false(@fs.exists("\{dir}/new.mbt"))
  })
}

///|
async test "wrap_program produces the argv shape without a shell" {
  @vfs.with_tmpdir(prefix="openseek-sandbox-capability-argv-", dir => {
    guard @sandbox.SourceWriteSandbox::create_if_available(dir) is Some(sandbox) else {
      return
    }
    let wrapped = sandbox.wrap_program("moon", ["check", "--target", "native"])
    assert_eq(wrapped.command.program, "/usr/bin/sandbox-exec")
    // [-p, <profile>, moon, check, --target, native]
    assert_eq(wrapped.command.args[0], "-p")
    assert_eq(wrapped.command.args[2], "moon")
    assert_eq(wrapped.command.args[3], "check")
    assert_eq(wrapped.command.args.length(), 6)
  })
}

///|
async test "a writable subtree covering the root is a caller bug, not a profile" {
  @vfs.with_tmpdir(prefix="openseek-sandbox-capability-cover-", dir => {
    // Only meaningful where the probe passes; elsewhere the guard skips.
    guard @sandbox.SourceWriteSandbox::create_if_available(dir) is Some(_) else {
      return
    }
    let covering = try {
      ignore(
        @sandbox.SourceWriteSandbox::create_if_available(
          dir,
          writable_subtree=dir,
        ),
      )
      false
    } catch {
      _ => true
    }
    assert_true(covering)
  })
}
