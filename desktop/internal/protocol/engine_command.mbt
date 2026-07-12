///|
/// One stdin command sent from the desktop host to an `openseek serve`
/// engine. The enum is package-local; it models the host's outgoing half of
/// the serve protocol without widening any cross-module API.
enum EngineCommand {
  Prompt(String)
  Steer(String)
  Compact
  Cancel
}

///|
pub fn prompt(text : String) -> EngineCommand {
  Prompt(text)
}

///|
pub fn steer(text : String) -> EngineCommand {
  Steer(text)
}

///|
pub fn compact() -> EngineCommand {
  Compact
}

///|
pub fn cancel() -> EngineCommand {
  Cancel
}

///|
fn EngineCommand::to_json(self : EngineCommand) -> Json {
  match self {
    Prompt(text) => { "command": "prompt", "text": text }
    Steer(text) => { "command": "steer", "text": text }
    Compact => { "command": "compact" }
    Cancel => { "command": "cancel" }
  }
}

///|
pub fn EngineCommand::to_jsonl(self : EngineCommand) -> String {
  self.to_json().stringify() + "\n"
}

///|
test "engine commands encode serve protocol json" {
  let prompt : EngineCommand = Prompt("hello")
  assert_true(
    prompt.to_json()
    is { "command": String("prompt"), "text": String("hello"), .. },
  )
  let steer : EngineCommand = Steer("go left")
  assert_true(
    steer.to_json()
    is { "command": String("steer"), "text": String("go left"), .. },
  )
  let compact : EngineCommand = Compact
  assert_true(compact.to_json() is { "command": String("compact"), .. })
  let cancel : EngineCommand = Cancel
  assert_true(cancel.to_json() is { "command": String("cancel"), .. })
}

///|
test "engine commands encode one json line" {
  let command : EngineCommand = Prompt("quote \" newline\n")
  let line = command.to_jsonl()
  assert_true(line.has_suffix("\n"))
  guard @json.parse(line.trim())
    is { "command": String("prompt"), "text": String("quote \" newline\n"), .. } else {
    fail("prompt command did not round-trip through json")
  }
}
