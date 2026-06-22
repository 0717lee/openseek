///|
test "parse simple moon command" {
  guard @shell_parse.parse_for_policy("moon check --target native")
    is Simple(commands) else {
    fail("expected simple command")
  }
  assert_eq(commands.length(), 1)
  assert_true(commands[0].argv == ["moon", "check", "--target", "native"])
  assert_eq(commands[0].env.length(), 0)
  assert_eq(commands[0].redirects.length(), 0)
  assert_true(@shell_parse.contains_command(Simple(commands), "moon"))
}

///|
test "parse cd then moon as separate top level commands" {
  guard @shell_parse.parse_for_policy("cd pkg/foo && moon test --target native")
    is Simple(commands) else {
    fail("expected simple compound command")
  }
  assert_eq(commands.length(), 2)
  assert_true(commands[0].argv == ["cd", "pkg/foo"])
  assert_true(commands[1].argv == ["moon", "test", "--target", "native"])
  assert_true(@shell_parse.has_cd(Simple(commands)))
  assert_true(@shell_parse.has_cd_and_command(Simple(commands), "moon"))
}

///|
test "parse quotes and backslash escapes without expansion" {
  guard @shell_parse.parse_for_policy(
      "moon run cmd/main -- \"a b\" 'c$d' escaped\\ space",
    )
    is Simple(commands) else {
    fail("expected quoted command")
  }
  assert_eq(commands.length(), 1)
  assert_true(
    commands[0].argv ==
    ["moon", "run", "cmd/main", "--", "a b", "c$d", "escaped space"],
  )
}

///|
test "preserve empty quoted words" {
  guard @shell_parse.parse_for_policy("cmd \"\" '' arg") is Simple(commands) else {
    fail("expected empty quoted words")
  }
  assert_eq(commands.length(), 1)
  assert_true(commands[0].argv == ["cmd", "", "", "arg"])
  guard @shell_parse.parse_for_policy("\"\" moon") is Simple(empty_name) else {
    fail("expected empty command word")
  }
  assert_true(empty_name[0].argv == ["", "moon"])
  assert_true(!@shell_parse.contains_command(Simple(empty_name), "moon"))
}

///|
test "parse environment assignments and redirects" {
  guard @shell_parse.parse_for_policy(
      "FOO=bar JSON=a=b moon run cmd/main > out.json 2>> err.log 2>&1",
    )
    is Simple(commands) else {
    fail("expected command with env and redirects")
  }
  assert_eq(commands.length(), 1)
  assert_true(
    commands[0].env ==
    [{ name: "FOO", value: "bar" }, { name: "JSON", value: "a=b" }],
  )
  assert_true(commands[0].argv == ["moon", "run", "cmd/main"])
  assert_true(
    commands[0].redirects ==
    [
      { op: ">", target: "out.json" },
      { op: "2>>", target: "err.log" },
      { op: "2>&", target: "1" },
    ],
  )
}

///|
test "parse quoted and escaped environment assignment values" {
  guard @shell_parse.parse_for_policy("FOO=\"bar baz\" PATH=\\~/bin moon check")
    is Simple(commands) else {
    fail("expected quoted assignment values")
  }
  assert_eq(commands.length(), 1)
  assert_true(
    commands[0].env ==
    [{ name: "FOO", value: "bar baz" }, { name: "PATH", value: "~/bin" }],
  )
  assert_true(commands[0].argv == ["moon", "check"])
  guard @shell_parse.parse_for_policy("FOO=bar\\ baz moon check")
    is Simple(escaped) else {
    fail("expected escaped assignment value")
  }
  assert_true(escaped[0].env == [{ name: "FOO", value: "bar baz" }])
  assert_true(escaped[0].argv == ["moon", "check"])
  guard @shell_parse.parse_for_policy("HOME=\"~\" moon check")
    is Simple(quoted_tilde) else {
    fail("expected quoted tilde assignment value")
  }
  assert_true(quoted_tilde[0].env == [{ name: "HOME", value: "~" }])
  assert_true(quoted_tilde[0].argv == ["moon", "check"])
}

///|
test "parse fd qualified input redirects" {
  guard @shell_parse.parse_for_policy("cmd 0<input 2<err.log")
    is Simple(commands) else {
    fail("expected fd qualified input redirects")
  }
  assert_eq(commands.length(), 1)
  assert_true(commands[0].argv == ["cmd"])
  assert_true(
    commands[0].redirects ==
    [{ op: "0<", target: "input" }, { op: "2<", target: "err.log" }],
  )
}

///|
test "preserve spaced numeric arguments before redirects" {
  guard @shell_parse.parse_for_policy("cmd 2 < input 3 > out")
    is Simple(commands) else {
    fail("expected spaced numeric arguments and redirects")
  }
  assert_eq(commands.length(), 1)
  assert_true(commands[0].argv == ["cmd", "2", "3"])
  assert_true(
    commands[0].redirects ==
    [{ op: "<", target: "input" }, { op: ">", target: "out" }],
  )
  guard @shell_parse.parse_for_policy("cmd 2>out 3>>err") is Simple(attached) else {
    fail("expected attached fd redirects")
  }
  assert_true(attached[0].argv == ["cmd"])
  assert_true(
    attached[0].redirects ==
    [{ op: "2>", target: "out" }, { op: "3>>", target: "err" }],
  )
}

///|
test "keep quoted words out of special shell grammar" {
  guard @shell_parse.parse_for_policy("cmd \"2\"<input") is Simple(commands) else {
    fail("expected quoted numeric argument")
  }
  assert_true(commands[0].argv == ["cmd", "2"])
  assert_true(commands[0].redirects == [{ op: "<", target: "input" }])
  assert_true(@shell_parse.parse_for_policy("A\"\"=x env") is TooComplex(_))
  assert_true(@shell_parse.parse_for_policy("A\\=x env") is TooComplex(_))
  assert_true(@shell_parse.parse_for_policy("\"A\"=x env") is TooComplex(_))
}

///|
test "detect env wrapper command name" {
  guard @shell_parse.parse_for_policy("env FOO=bar moon check")
    is Simple(commands) else {
    fail("expected env wrapper")
  }
  assert_eq(commands.length(), 1)
  assert_true(commands[0].command_name() == Some("moon"))
  assert_true(@shell_parse.contains_command(Simple(commands), "moon"))
}

///|
test "detect command wrapper but keep complex env options conservative" {
  guard @shell_parse.parse_for_policy("command moon check") is Simple(commands) else {
    fail("expected command wrapper")
  }
  assert_eq(commands.length(), 1)
  assert_true(commands[0].command_name() == Some("moon"))
  assert_true(@shell_parse.contains_command(Simple(commands), "moon"))
  guard @shell_parse.parse_for_policy("env -u FOO moon check")
    is Simple(env_commands) else {
    fail("expected env option wrapper to parse")
  }
  assert_true(env_commands[0].command_name() == Some("env"))
  assert_true(!@shell_parse.contains_command(Simple(env_commands), "moon"))
}

///|
test "parse safe quoted glob and escaped dollar as literals" {
  guard @shell_parse.parse_for_policy(
      "moon test \"*.mbt\" '${NOT_EXPANDED}' \"\\$literal\"",
    )
    is Simple(commands) else {
    fail("expected quoted literals")
  }
  assert_true(
    commands[0].argv == ["moon", "test", "*.mbt", "${NOT_EXPANDED}", "$literal"],
  )
}

///|
test "parse pipes and conditionals as visible top level commands" {
  guard @shell_parse.parse_for_policy("moon check 2>&1 | tee out.log || true")
    is Simple(commands) else {
    fail("expected pipeline and conditional commands")
  }
  assert_eq(commands.length(), 3)
  assert_true(commands[0].argv == ["moon", "check"])
  assert_true(commands[0].redirects == [{ op: "2>&", target: "1" }])
  assert_true(commands[1].argv == ["tee", "out.log"])
  assert_true(commands[2].argv == ["true"])
  assert_true(@shell_parse.contains_command(Simple(commands), "moon"))
}

///|
test "return syntax errors for dangling operators and redirects" {
  assert_true(@shell_parse.parse_for_policy("moon check &&") is SyntaxError(_))
  assert_true(@shell_parse.parse_for_policy("moon check >") is SyntaxError(_))
  assert_true(@shell_parse.parse_for_policy("&& moon check") is SyntaxError(_))
  assert_true(
    @shell_parse.parse_for_policy("moon 'unterminated") is SyntaxError(_),
  )
}

///|
test "return too complex for runtime expansion and shell structures" {
  assert_true(
    @shell_parse.parse_for_policy("cd \"$(pwd)\" && moon check")
    is TooComplex(_),
  )
  assert_true(
    @shell_parse.parse_for_policy("TOOL=moon; $TOOL check") is TooComplex(_),
  )
  assert_true(
    @shell_parse.parse_for_policy("(cd pkg && moon check)") is TooComplex(_),
  )
  assert_true(
    @shell_parse.parse_for_policy("for f in file; do moon check; done")
    is TooComplex(_),
  )
  assert_true(
    @shell_parse.parse_for_policy("for f in *.mbt; do moon check; done")
    is TooComplex(_),
  )
  assert_true(@shell_parse.parse_for_policy("moon test *.mbt") is TooComplex(_))
  assert_true(
    @shell_parse.parse_for_policy("moon check <<EOF") is TooComplex(_),
  )
  assert_true(@shell_parse.parse_for_policy("moon \\\ncheck") is TooComplex(_))
  assert_true(
    @shell_parse.parse_for_policy("eval 'moon check'") is TooComplex(_),
  )
  assert_true(@shell_parse.parse_for_policy("HOME=~ cmd") is TooComplex(_))
  assert_true(
    @shell_parse.parse_for_policy("PATH=/bin:~/bin cmd") is TooComplex(_),
  )
  assert_true(
    @shell_parse.parse_for_policy("HOME=~/\"quoted\" cmd") is TooComplex(_),
  )
}

///|
test "allow trailing semicolon and blank input" {
  guard @shell_parse.parse_for_policy("moon check;") is Simple(commands) else {
    fail("expected trailing semicolon to be accepted")
  }
  assert_eq(commands.length(), 1)
  guard @shell_parse.parse_for_policy("   \t ") is Simple(blank) else {
    fail("expected blank command to parse")
  }
  assert_eq(blank.length(), 0)
}
