///|
pub fn moonbit_command_policy_error(cmd : String) -> String? {
  let words = shell_words(cmd)
  let command_index = first_command_word_index(words)
  match command_index {
    None => None
    Some(index) => {
      let first = words[index]
      if first == "moon_cmd" {
        return Some(
          "error: moon_cmd is a tool, not a shell command; call the moon_cmd tool directly",
        )
      }
      if first == "moon" && index + 1 < words.length() {
        let subcommand = words[index + 1]
        if guarded_moon_subcommands().contains(subcommand) {
          return Some(
            "error: shell blocked `moon \{subcommand}`; use the moon_cmd tool so MoonBit commands keep structured args, output caps, and guardrails",
          )
        }
      }
      if contains_guarded_moon_fragment(cmd) {
        Some(
          "error: shell blocked an embedded MoonBit command; use cwd plus moon_cmd instead of `cd ... && moon ...`",
        )
      } else {
        None
      }
    }
  }
}

///|
fn guarded_moon_subcommands() -> Array[String] {
  ["check", "test", "run", "info", "fmt", "build"]
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
  word.trim(chars="\t\r\n ").to_owned().trim(chars=";&|()").to_owned()
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
  let parts = word.split("=").map(part => part.to_owned()).collect()
  parts.length() == 2 && parts[0] != "" && parts[1] != ""
}

///|
fn contains_guarded_moon_fragment(cmd : String) -> Bool {
  let probes = ["&& moon ", "; moon ", "\nmoon "]
  for probe in probes {
    for subcommand in guarded_moon_subcommands() {
      if cmd.contains(probe + subcommand) {
        return true
      }
    }
  }
  false
}
