///|
test "subcommand typo suggestions catch near-misses, not prompts" {
  // Near-miss typos map to the intended subcommand.
  assert_true(subcommand_typo_suggestion("ran") is Some("run"))
  assert_true(subcommand_typo_suggestion("serv") is Some("serve"))
  assert_true(subcommand_typo_suggestion("reveiw") is Some("review"))
  assert_true(subcommand_typo_suggestion("session") is Some("sessions"))
  // Exact subcommands and clear prompts are not typos.
  assert_true(subcommand_typo_suggestion("run") is None)
  assert_true(subcommand_typo_suggestion("fix the bug") is None)
  assert_true(subcommand_typo_suggestion("--base") is None)
  assert_true(subcommand_typo_suggestion("deploy") is None)
}

///|
test "levenshtein distance" {
  inspect(levenshtein("ran", "run"), content="1")
  inspect(levenshtein("run", "run"), content="0")
  inspect(levenshtein("reveiw", "review"), content="2")
  inspect(levenshtein("", "abc"), content="3")
}

///|
test "unknown command message names the fix and the prompt escape" {
  let message = unknown_command_message("ran", "run")
  assert_true(message.contains("unknown command 'ran'"))
  assert_true(message.contains("Did you mean 'run'?"))
  assert_true(message.contains("openseek -- ran"))
}
