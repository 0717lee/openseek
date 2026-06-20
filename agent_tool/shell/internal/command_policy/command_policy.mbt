///|
/// Policy gate for agent shell commands: returns the error to feed back to
/// the model when `cmd` must not run, or `None` when it may.
///
/// `moon check` (and every other `moon` subcommand) runs through shell; the
/// only redirection left is the tool name `moon_cmd` typed as a shell command,
/// which is pointed back at running `moon ...` directly. The error wording tells
/// the model what to do instead, because the model is the caller who reads it.
pub fn moonbit_command_policy_error(cmd : String) -> String? {
  let words = shell_words(cmd)
  match first_command_word_index(words) {
    None => None
    Some(index) =>
      if words[index] == "moon_cmd" {
        Some(
          "error: moon_cmd is not a shell command; run moon subcommands like `moon check` or `moon test` through shell directly",
        )
      } else {
        None
      }
  }
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
fn first_command_word_index(words : Array[String]) -> Int? {
  for index, word in words {
    if !looks_like_env_assignment(word) {
      return Some(index)
    }
  }
  None
}

///|
fn looks_like_env_assignment(word : String) -> Bool {
  if word.contains("/") || word.contains("-") {
    return false
  }
  let parts = word.split("=").collect()
  parts.length() == 2 && parts[0] != "" && parts[1] != ""
}
