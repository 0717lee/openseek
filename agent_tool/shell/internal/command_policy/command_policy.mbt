///|
/// Policy gate for agent shell commands: returns the error to feed back to
/// the model when `cmd` must not run, or `None` when it may.
///
/// `moon check` (and every other `moon` subcommand) runs through shell; the
/// only redirection left is the tool name `moon_cmd` typed as a shell command,
/// which is pointed back at running `moon ...` directly. `sed -i` (in-place file
/// editing) is also blocked: it silently misapplies edits often enough to be
/// untrustworthy, so the model is sent to the `edit`/`write` tools instead. The
/// error wording tells the model what to do, because the model is the caller who
/// reads it.
pub fn moonbit_command_policy_error(cmd : String) -> String? {
  let parsed = @shell_parse.parse_for_policy(cmd)
  moonbit_command_policy_error_for_parse(cmd, parsed)
}

///|
/// Apply shell command policy using an already-computed shell parse result.
///
/// This is used by `shell` so policy and follow-up Moon checks share one parse
/// of the same command string.
pub fn moonbit_command_policy_error_for_parse(
  cmd : String,
  parsed : @shell_parse.ParseResult,
) -> String? {
  if @shell_parse.contains_command(parsed, "moon_cmd") {
    Some(moon_cmd_error_message())
  } else if parsed is Simple(commands) {
    if commands.any(sed_edits_files) {
      Some(sed_in_place_error_message())
    } else {
      None
    }
  } else if first_command_word(shell_words(cmd)) == Some("moon_cmd") {
    // Parse too complex to analyze structurally (globs, expansions, …): fall
    // back to rough checks for the `moon_cmd` typo or a `sed -i` edit such as
    // `cd src && sed -i 's/a/b/' *.mbt`.
    Some(moon_cmd_error_message())
  } else if rough_sed_in_place(cmd) {
    Some(sed_in_place_error_message())
  } else {
    None
  }
}

///|
fn moon_cmd_error_message() -> String {
  "error: moon_cmd is not a shell command; run moon subcommands like `moon check` or `moon test` through shell directly"
}

///|
fn sed_in_place_error_message() -> String {
  "error: `sed -i` edits files in place and is unreliable for code changes; use the `edit` tool to modify file contents, or `write` to replace a whole file"
}

///|
/// True when `command` is `sed` (after any `env`/`command`/`builtin` wrapper)
/// invoked with an in-place edit flag. Read-only `sed` — `sed -n '1,5p' file`,
/// `... | sed s/a/b/`, or a non-`sed` `-i` such as `grep -i` / `env -i sed ...`
/// — is left alone.
fn sed_edits_files(command : @shell_parse.SimpleCommand) -> Bool {
  guard command.command_name() is Some("sed") else { return false }
  guard command.command_index() is Some(start) else { return false }
  // `command_index` skips the wrapper, so scan only `sed`'s own arguments.
  for index in (start + 1)..<command.argv.length() {
    let arg = command.argv[index]
    if arg == "--" {
      // Everything after `--` is a file operand, not a flag.
      break
    }
    if is_sed_in_place_flag(arg) {
      return true
    }
  }
  false
}

///|
/// Rough fallback for parses too complex to analyze structurally (globs,
/// expansions) — used only when `parse_for_policy` returns `TooComplex` /
/// `SyntaxError`. Split on shell separators and flag any segment that leads with
/// `sed` carrying an in-place flag, so `cd src && sed -i 's/a/b/' *.mbt` is
/// caught and `echo sed -i *.txt` (sed as data) is not. Quote-unaware, like the
/// moon_cmd fallback: an operator inside quotes can still split a segment.
fn rough_sed_in_place(cmd : String) -> Bool {
  for segment in rough_command_segments(cmd) {
    if segment_leads_with_sed_in_place(shell_words(segment)) {
      return true
    }
  }
  false
}

///|
/// Split `cmd` into rough command segments on the `&&`, `||`, `;`, `|`, and
/// newline separators. Quote-unaware — adequate for the complex-parse fallback,
/// which only needs approximate command boundaries.
fn rough_command_segments(cmd : String) -> Array[String] {
  let normalized = cmd
    .replace_all(old="&&", new="\n")
    .replace_all(old="||", new="\n")
    .replace_all(old=";", new="\n")
    .replace_all(old="|", new="\n")
  [
    for segment in normalized.split("\n") => segment.to_owned()
  ]
}

///|
/// True when a segment's leading command word (after env assignments) is `sed`
/// and a following word is an in-place flag. Does not unwrap
/// `command`/`env`/`builtin`, matching the moon_cmd fallback's conservatism.
fn segment_leads_with_sed_in_place(words : Array[String]) -> Bool {
  let mut index = 0
  while index < words.length() && is_env_assignment_prefix(words[index]) {
    index += 1
  }
  guard index < words.length() && words[index] == "sed" else { return false }
  for cursor in (index + 1)..<words.length() {
    if words[cursor] == "--" {
      break
    }
    if is_sed_in_place_flag(words[cursor]) {
      return true
    }
  }
  false
}

///|
/// Whether a single `sed` argument requests in-place editing: the long
/// `--in-place[=suffix]` form, or a short cluster containing `i` (`-i`, `-i.bak`,
/// `-Ei`). `-e`/`-f` consume the rest of the token as their value, so an `i`
/// inside a script like `-e's/i/x/'` is not mistaken for `-i`.
fn is_sed_in_place_flag(arg : String) -> Bool {
  if arg == "--in-place" || arg.has_prefix("--in-place=") {
    return true
  }
  if !arg.has_prefix("-") || arg.has_prefix("--") || arg == "-" {
    return false
  }
  let mut first = true
  for ch in arg {
    if first {
      first = false
      continue
    }
    match ch {
      'i' => return true
      'e' | 'f' => return false
      _ => ()
    }
  }
  false
}

///|
fn shell_words(cmd : String) -> Array[String] {
  let words : Array[String] = []
  for piece in cmd.split(" ") {
    let word = clean_shell_word(piece.to_owned())
    if word != "" {
      words.push(word)
    }
  }
  words
}

///|
fn clean_shell_word(word : String) -> String {
  "\{word.trim(chars="\t\r\n ").trim(chars=";&|()")}"
}

///|
fn first_command_word(words : Array[String]) -> String? {
  for word in words {
    if !looks_like_env_assignment(word) {
      return Some(word)
    }
  }
  None
}

///|
/// A leading `NAME=value` environment prefix (any value), used to skip command
/// env assignments when locating a segment's command word. More permissive than
/// `looks_like_env_assignment`, which rejects values containing `/`, `-`, or
/// empty — so a real prefix like `PATH=/usr/bin` before `sed -i` is skipped.
fn is_env_assignment_prefix(word : String) -> Bool {
  match word.find("=") {
    Some(0) | None => false
    Some(equals) => is_valid_env_name(word[:equals])
  }
}

///|
fn is_valid_env_name(name : StringView) -> Bool {
  if name.length() == 0 {
    return false
  }
  let mut first = true
  for ch in name {
    let valid = if first {
      first = false
      ch is ('a'..='z' | 'A'..='Z' | '_')
    } else {
      ch is ('a'..='z' | 'A'..='Z' | '0'..='9' | '_')
    }
    if !valid {
      return false
    }
  }
  true
}

///|
fn looks_like_env_assignment(word : String) -> Bool {
  if word.contains("/") || word.contains("-") {
    return false
  }
  let parts = word.split("=").collect()
  parts.length() == 2 && parts[0] != "" && parts[1] != ""
}
