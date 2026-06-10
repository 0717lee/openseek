///|
/// Turns are delimited by `Terminal` events, so a turn that contains mid-turn
/// steering (extra `User` events before the terminal) stays a single turn.
test "group_turns keeps steering messages within one turn" {
  let s = @agent_session.Session(SessionId("g"), system_prompt="")
    .append(User(UserMessage("do the thing")))
    .append(Assistant(AssistantMessage("working")))
    .append(User(UserMessage("actually, also this")))
    .append(Assistant(AssistantMessage("ok")))
    .append(Terminal(Finished("done")))
  let turns = group_turns(s.events())
  inspect(turns.length(), content="1")
  inspect(turns[0].length(), content="5")
}

///|
/// Two complete turns produce two groups; a trailing turn with no terminal
/// (cut off mid-flight) becomes its own final group.
test "group_turns splits on terminals and keeps an unterminated tail" {
  let s = @agent_session.Session(SessionId("g"), system_prompt="")
    .append(User(UserMessage("one")))
    .append(Terminal(Finished("first")))
    .append(User(UserMessage("two")))
    .append(Terminal(Finished("second")))
    .append(User(UserMessage("three (still running)")))
  let turns = group_turns(s.events())
  inspect(turns.length(), content="3")
  inspect(turns[0].length(), content="2")
  inspect(turns[1].length(), content="2")
  inspect(turns[2].length(), content="1")
}
