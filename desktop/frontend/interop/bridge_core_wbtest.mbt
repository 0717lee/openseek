///|
test "op failure text is peeled down to the raised message" {
  inspect(
    tidy_op_failure(
      "op ext:openseek/terminal_input failed: <openseek_desktop/internal/extension.HostError.HostError: terminal 3 is not open>",
    ),
    content="terminal 3 is not open",
  )
}

///|
test "text without the op failure shape passes through untouched" {
  inspect(
    tidy_op_failure("bridge request timed out"),
    content="bridge request timed out",
  )
  inspect(
    tidy_op_failure("op x failed: plain text detail"),
    content="op x failed: plain text detail",
  )
}
