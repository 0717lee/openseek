# Shell Parse

`shell_parse` is a conservative parser for shell policy decisions. It accepts
flat command lines whose argv can be known statically, and classifies runtime
shell behavior such as expansions, command substitution, subshells, heredocs,
and globbing as `TooComplex`.

The package is not a shell interpreter and is not a security sandbox. Its job is
to give higher-level policy code a trustworthy list of simple commands when the
input is statically knowable, and to decline analysis otherwise.

The full `SimpleCommand` snapshot is intentionally part of the example. Policy
callers often need both the literal argv and the effective command name: wrappers
such as `command -p moon fmt` keep `"command"` in `argv[0]`, but
`command_name()` reports `"moon"` because that is the program the wrapper will
execute.

```moonbit check
///|
test "shell parser exposes static command structure" {
  let parsed = @shell_parse.parse_for_policy(
    "cd ./pkg && FOO=bar command -p moon fmt > out.log",
  )
  debug_inspect(
    parsed,
    content=(
      #|Simple(
      #|  [
      #|    {
      #|      argv: ["cd", "./pkg"],
      #|      env: [],
      #|      redirects: [],
      #|      separator_before: None,
      #|      source: "cd ./pkg",
      #|    },
      #|    {
      #|      argv: ["command", "-p", "moon", "fmt"],
      #|      env: [{ name: "FOO", value: "bar" }],
      #|      redirects: [{ op: ">", target: "out.log" }],
      #|      separator_before: Some("&&"),
      #|      source: "FOO=bar command -p moon fmt > out.log",
      #|    },
      #|  ],
      #|)
    ),
  )
  guard parsed is Simple(commands) else { fail("expected flat command line") }
  debug_inspect(
    commands.map(command => (command.command_name(), command.command_index())),
    content=(
      #|[(Some("cd"), Some(0)), (Some("moon"), Some(2))]
    ),
  )
}
```

When static argv is unknowable, callers should branch on `TooComplex` instead
of guessing. This includes ordinary shell expansion features whose result
depends on runtime state.

```moonbit check
///|
test "shell parser declines runtime shell expansion" {
  debug_inspect(
    @shell_parse.parse_for_policy("moon $SUBCOMMAND"),
    content=(
      #|TooComplex("shell expansion is not supported")
    ),
  )
  debug_inspect(
    @shell_parse.parse_for_policy("moon test *.mbt"),
    content=(
      #|TooComplex("unquoted glob expansion is not supported")
    ),
  )
}
```
