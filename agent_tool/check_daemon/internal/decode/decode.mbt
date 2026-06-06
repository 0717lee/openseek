///|
pub let default_max_output_chars : Int = 12000

///|
pub let hard_max_output_chars : Int = 50000

///|
pub let default_initial_wait_ms : Int = 500

///|
pub let hard_initial_wait_ms : Int = 5000

///|
pub(all) enum CheckDaemonAction {
  Start
  Status
  Stop
}

///|
pub struct CheckDaemonInput {
  action : CheckDaemonAction
  cmd : String?
  cwd : String?
  name : String?
  id : String?
  max_output_chars : Int
  initial_wait_ms : Int
}

///|
pub fn decode(arguments : Json) -> CheckDaemonInput raise {
  match arguments {
    Object(fields) => parse_fields(fields)
    _ => fail("object arguments")
  }
}

///|
fn parse_fields(fields : Map[String, Json]) -> CheckDaemonInput raise {
  let action = required_action(fields)
  let cmd = optional_string(fields, "cmd")
  let id = optional_string(fields, "id")
  match action {
    Start if cmd is None => fail("arguments.cmd for action start")
    Status | Stop if id is None => fail("arguments.id for action status/stop")
    _ => ()
  }
  {
    action,
    cmd,
    cwd: optional_string(fields, "cwd"),
    name: optional_string(fields, "name"),
    id,
    max_output_chars: cap_int(
      optional_positive_int(
        fields, "max_output_chars", default_max_output_chars,
      ),
      hard_max_output_chars,
    ),
    initial_wait_ms: cap_int(
      optional_positive_int(fields, "initial_wait_ms", default_initial_wait_ms),
      hard_initial_wait_ms,
    ),
  }
}

///|
fn required_action(fields : Map[String, Json]) -> CheckDaemonAction raise {
  match fields.get("action") {
    Some(String("start")) => Start
    Some(String("status")) => Status
    Some(String("stop")) => Stop
    Some(String(_)) => fail("arguments.action to be one of start, status, stop")
    Some(Null) | None => fail("arguments.action")
    _ => fail("arguments.action to be a string")
  }
}

///|
fn optional_string(fields : Map[String, Json], name : String) -> String? raise {
  match fields.get(name) {
    Some(String(value)) if value != "" => Some(value)
    Some(String(_)) | Some(Null) | None => None
    _ => fail("arguments.\{name} to be a string")
  }
}

///|
fn optional_positive_int(
  fields : Map[String, Json],
  name : String,
  default : Int,
) -> Int raise {
  match fields.get(name) {
    Some(Number(value, ..)) => {
      let int_value = value.to_int()
      if int_value <= 0 {
        fail("arguments.\{name} to be a positive number")
      }
      int_value
    }
    Some(Null) | None => default
    _ => fail("arguments.\{name} to be a number")
  }
}

///|
fn cap_int(value : Int, maximum : Int) -> Int {
  if value > maximum {
    maximum
  } else {
    value
  }
}
