// The rail's public contract: the entry projection, the key round trip, and
// the pure state machine. What `rail` draws from that state is browser-only
// now — rabbita 0.15.1 removed the js-target `render_to_string`.

///|
fn item(
  kind : @transcript.ItemKind,
  content : String,
  sequence? : Int,
) -> @transcript.TranscriptItem {
  { kind, content, ts: None, sequence }
}

///|
test "entries pick user turns and pair each with its first answer" {
  let rows = @transcript_overview.entries(
    [
      item(User, "first question", sequence=1),
      item(Reasoning, "thinking", sequence=2),
      item(
        Tool(
          call_id="c1",
          name="read",
          arguments=None,
          has_result=true,
          is_error=false,
          brief=None,
        ),
        "",
        sequence=2,
      ),
      item(Assistant(is_danger=false), "first answer", sequence=2),
      item(Assistant(is_danger=false), "afterthought", sequence=3),
      item(User, "second question", sequence=4),
    ],
    display=text => text,
  )
  inspect(rows.length(), content="2")
  @debug.assert_eq(rows[0].key, @transcript_overview.Durable(1))
  inspect(rows[0].text, content="first question")
  // The first assistant row answers the turn; the afterthought does not
  // replace it, and the open second turn has no answer yet.
  @debug.assert_eq(rows[0].reply, Some("first answer"))
  @debug.assert_eq(rows[1].key, @transcript_overview.Durable(4))
  @debug.assert_eq(rows[1].reply, None)
}

///|
test "an abort bubble is the answer a turn got" {
  let rows = @transcript_overview.entries(
    [
      item(User, "question", sequence=1),
      item(Assistant(is_danger=true), "aborted", sequence=2),
    ],
    display=text => text,
  )
  @debug.assert_eq(rows[0].reply, Some("aborted"))
}

///|
test "a row without a sequence keys by its position" {
  let rows = @transcript_overview.entries(
    [item(Assistant(is_danger=false), "notice"), item(User, "local bubble")],
    display=text => text,
  )
  inspect(rows.length(), content="1")
  @debug.assert_eq(rows[0].key, @transcript_overview.Local(1))
}

///|
test "the display projection owns the prompt's shown form" {
  let rows = @transcript_overview.entries(
    [item(User, "raw envelope", sequence=1)],
    display=_ => "typed text $skill",
  )
  inspect(rows[0].text, content="typed text $skill")
}

///|
test "anchor ids round-trip through the DOM" {
  for key in [@transcript_overview.Durable(12), @transcript_overview.Local(0)] {
    @debug.assert_eq(
      @transcript_overview.TurnKey::from_anchor(key.anchor()),
      Some(key),
    )
  }
  @debug.assert_eq(@transcript_overview.TurnKey::from_anchor("stream"), None)
  // A mangled ordinal is nobody's key, not a crash.
  @debug.assert_eq(@transcript_overview.TurnKey::from_anchor("turn-s12x"), None)
  @debug.assert_eq(@transcript_overview.TurnKey::from_anchor("turn-s"), None)
}

///|
test "the state machine's transitions are idempotent" {
  let initial = @transcript_overview.State::empty()
  for
    msg in (
      [
        @transcript_overview.Entered(
          @transcript_overview.Durable(3),
          flip=false,
          anchor=48,
        ),
        @transcript_overview.Left,
        @transcript_overview.Clicked(@transcript_overview.Local(2)),
        @transcript_overview.ActiveChanged(
          Some(@transcript_overview.Durable(9)),
        ),
        @transcript_overview.ActiveChanged(None),
      ] : Array[@transcript_overview.Msg]) {
    let once = @transcript_overview.update(msg, initial)
    @debug.assert_eq(@transcript_overview.update(msg, once), once)
  }
}

///|
test "hover opens on enter, survives a click, and closes on leaving the rail" {
  let key = @transcript_overview.Durable(7)
  let state = @transcript_overview.update(
    @transcript_overview.Entered(key, flip=true, anchor=132),
    @transcript_overview.State::empty(),
  )
  // The enter-time flip and anchor measurements ride along with the hover.
  @debug.assert_eq(state.hover, Some({ key, flip: true, anchor: 132 }))
  let clicked = @transcript_overview.update(
    @transcript_overview.Clicked(key),
    state,
  )
  // The click highlights eagerly and keeps the popover: the pointer is
  // still on the tick.
  @debug.assert_eq(clicked.active, Some(key))
  @debug.assert_eq(clicked.hover, Some({ key, flip: true, anchor: 132 }))
  let left = @transcript_overview.update(@transcript_overview.Left, clicked)
  @debug.assert_eq(left.hover, None)
  @debug.assert_eq(left.active, Some(key))
}

///|
test "a hover carries the measurements the popover is placed from" {
  // The rail renders its popover outside the scrollable list, so the tick's
  // own position cannot place it: the enter-time anchor and flip decision
  // ride on the hover and must survive every later transition.
  let key = @transcript_overview.Durable(1)
  let entered = @transcript_overview.update(
    @transcript_overview.Entered(key, flip=true, anchor=300),
    @transcript_overview.State::empty(),
  )
  @debug.assert_eq(entered.hover, Some({ key, flip: true, anchor: 300 }))
  let re_entered = @transcript_overview.update(
    @transcript_overview.Entered(key, flip=false, anchor=24),
    entered,
  )
  @debug.assert_eq(re_entered.hover, Some({ key, flip: false, anchor: 24 }))
}
