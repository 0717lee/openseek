///|
test "command policy allows moon subcommands through shell" {
  // moon check now runs through shell like every other moon subcommand.
  assert_true(
    @command_policy.moonbit_command_policy_error("moon check") is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error("cd demo && moon check")
    is None,
  )
  assert_true(@command_policy.moonbit_command_policy_error("moon test") is None)
  assert_true(
    @command_policy.moonbit_command_policy_error("moon run cmd/main") is None,
  )
  assert_true(@command_policy.moonbit_command_policy_error("moon info") is None)
  assert_true(@command_policy.moonbit_command_policy_error("moon fmt") is None)
  assert_true(
    @command_policy.moonbit_command_policy_error("moon build") is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error(
      "DEEPSEEK_MODEL=x moon run cmd/main",
    )
    is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error("git status --short") is None,
  )
}

///|
test "command policy still redirects the moon_cmd tool name" {
  guard @command_policy.moonbit_command_policy_error("moon_cmd check")
    is Some(message) else {
    fail("expected moon_cmd to be redirected")
  }
  assert_true(message.contains("moon_cmd is not a shell command"))
}

///|
test "command policy detects moon_cmd in simple shell compounds" {
  for
    cmd in [
      "cd demo && moon_cmd check", "DEEPSEEK_MODEL=x moon_cmd run cmd/main", "env DEEPSEEK_MODEL=x moon_cmd check",
      "env -- DEEPSEEK_MODEL=x moon_cmd check", "command moon_cmd check", "command -- moon_cmd check",
      "command -p moon_cmd check", "true || moon_cmd test", "moon_cmd check > out.log",
      "cd demo && moon_cmd check # trailing note", "true;\nmoon_cmd check",
    ] {
    guard @command_policy.moonbit_command_policy_error(cmd) is Some(message) else {
      fail("expected moon_cmd to be redirected for \{cmd}")
    }
    assert_true(message.contains("moon_cmd is not a shell command"))
  }
}

///|
test "command policy does not match moon_cmd as data" {
  assert_true(
    @command_policy.moonbit_command_policy_error("printf '%s\\n' moon_cmd")
    is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error("echo moon_cmd | cat") is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error(
      "MOON_TOOL=moon_cmd moon check",
    )
    is None,
  )
  assert_true(
    @command_policy.moonbit_command_policy_error(
      "env DEEPSEEK_MODEL=x -i moon_cmd check",
    )
    is None,
  )
}

///|
test "command policy redirects sed in-place editing to the edit tool" {
  for
    cmd in [
      "sed -i 's/a/b/' file.mbt", "sed -i.bak 's/a/b/' file.mbt", "sed -i '' 's/a/b/' file.mbt",
      "sed --in-place 's/a/b/' f", "sed --in-place=.bak 's/a/b/' f", "sed -Ei 's/a/b/' f",
      "sed -ni 's/a/b/' f", "command sed -i 's/a/b/' f", "env FOO=bar sed -i 's/a/b/' f",
      "cat f | sed -i 's/a/b/' f", "cd src && sed -i 's/a/b/' f",
      // Globs/expansions parse as TooComplex; caught by the rough fallback,
      // including after a separator.
       "sed -i 's/a/b/' *.mbt", "sed -i.bak 's/a/b/' *.mbt", "sed -i 's/a/b/' $(ls)",
      "VAR=x sed -i 's/a/b/' *.mbt", "cd src && sed -i 's/a/b/' *.mbt", "ls *.mbt; sed -i 's/a/b/' f",
      "cat *.mbt | sed -i 's/a/b/' f", "PATH=/usr/bin sed -i 's/a/b/' *.mbt", "sed '-i' 's/a/b/' *.mbt",
      "sleep 1 & sed -i 's/a/b/' *.mbt",
    ] {
    guard @command_policy.moonbit_command_policy_error(cmd) is Some(message) else {
      fail("expected sed -i to be redirected for \{cmd}")
    }
    assert_true(message.contains("sed -i") && message.contains("edit"))
  }
}

///|
test "command policy allows read-only and non-sed uses of -i" {
  for
    cmd in [
      "sed -n '1,5p' file.mbt", "sed 's/a/b/' file.mbt", "cat file | sed 's/a/b/'",
      "grep -i sed file.mbt", "env -i sed 's/a/b/' file", "echo sed -i", "sed -e 's/i/x/' file",
      // `-f`/`-e` consume the next word as the script/file, so a script file
      // named `-i` is not an in-place flag.
       "sed -f -i file.mbt", "sed -e 's/a/b/' -e p file.mbt",
      // TooComplex (glob) but not editing: read-only sed (even after a
      // separator) and non-sed leaders.
       "sed 's/a/b/' *.mbt", "echo sed -i *.txt", "grep -i sed *.mbt", "cat *.mbt | sed 's/a/b/'",
      "cd src && grep -i sed *.mbt",
    ] {
    guard @command_policy.moonbit_command_policy_error(cmd) is None else {
      fail("expected \{cmd} to be allowed")
    }
  }
}
