# Shell Parse

`shell_parse` is a conservative parser for shell policy decisions. It accepts
flat command lines whose argv can be known statically, and classifies runtime
shell behavior such as expansions, command substitution, subshells, heredocs,
and globbing as `TooComplex`.

The package is not a shell interpreter and is not a security sandbox. Its job is
to give higher-level policy code a trustworthy list of simple commands when the
input is statically knowable, and to decline analysis otherwise.

```moonbit check
///|
test "shell parser exposes effective command names" {
  guard @shell_parse.parse_for_policy("cd ./pkg && command -p moon fmt")
    is Simple(commands) else {
    fail("expected flat command line")
  }
  assert_eq(commands.length(), 2)
  assert_true(commands[0].command_name() == Some("cd"))
  assert_true(commands[1].command_name() == Some("moon"))
  assert_true(commands[1].command_index() == Some(2))
  assert_true(@shell_parse.contains_command(Simple(commands), "moon"))
}
```

```moonbit check
///|
test "shell parser declines runtime shell expansion" {
  assert_true(
    @shell_parse.parse_for_policy("moon $SUBCOMMAND") is TooComplex(_),
  )
  assert_true(@shell_parse.parse_for_policy("moon test *.mbt") is TooComplex(_))
}
```
