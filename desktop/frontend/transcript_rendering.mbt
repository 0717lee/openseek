///|
/// Stable identity for one visible transcript row. Durable events may expand
/// into several rows, so their event sequence alone is not unique; the ordinal
/// is the row's position within that event. Old fixtures without a sequence use
/// their durable-array position, while client-local notices own an explicit id.
priv enum TranscriptRowIdentity {
  DurableTranscriptRow(sequence~ : Int, ordinal~ : Int)
  LegacyTranscriptRow(Int)
  LocalNoticeTranscriptRow(Int)
}

///|
/// Serialize a row identity for Rabbita's keyed-children map. NUL is an
/// internal field separator already used by the frontend's composite keys; the
/// result is renderer-private and is never emitted as a DOM id or attribute.
fn TranscriptRowIdentity::wire(self : TranscriptRowIdentity) -> String {
  match self {
    DurableTranscriptRow(sequence~, ordinal~) => "s\{sequence}\u{0}o\{ordinal}"
    LegacyTranscriptRow(index) => "l\{index}"
    LocalNoticeTranscriptRow(id) => "n\{id}"
  }
}

///|
/// Project one client-local notice without discarding its renderer identity.
fn LocalNotice::visible_transcript_row(
  self : LocalNotice,
) -> @transcript_component.VisibleRow {
  {
    item: { kind: self.kind, content: self.content, ts: None, sequence: None },
    identity: LocalNoticeTranscriptRow(self.id).wire(),
  }
}

///|
/// Interleave durable rows and local notices while retaining the stable
/// identity of both. This is deliberately separate from `visible_items`, whose
/// callers only need transcript content and should not know renderer keys.
fn Conversation::visible_transcript_rows(
  self : Conversation,
) -> Array[@transcript_component.VisibleRow] {
  let durable : Array[@transcript_component.VisibleRow] = []
  let ordinals : Map[Int, Int] = Map([])
  for index, item in self.messages {
    let identity = match item.sequence {
      Some(sequence) => {
        let ordinal = ordinals.get(sequence).unwrap_or(0)
        ordinals.set(sequence, ordinal + 1)
        DurableTranscriptRow(sequence~, ordinal~)
      }
      None => LegacyTranscriptRow(index)
    }
    durable.push({ item, identity: identity.wire() })
  }
  if self.overlay.is_empty() {
    return durable
  }
  let visible : Array[@transcript_component.VisibleRow] = []
  for index in 0..<durable.length() {
    for notice in self.overlay {
      if notice.after_messages == index {
        visible.push(notice.visible_transcript_row())
      }
    }
    visible.push(durable[index])
  }
  for notice in self.overlay {
    if notice.after_messages >= durable.length() {
      visible.push(notice.visible_transcript_row())
    }
  }
  visible
}

///|
/// Streaming output is owned by its run. The Starting/idle cases keep this
/// total for tests and transient states even though normal deltas arrive only
/// after the host has supplied a run id.
fn Conversation::streaming_render_identity(self : Conversation) -> String {
  match self.run {
    Open(run_id~, ..) => run_id
    Starting(submission_id~) => "submission\u{0}\{submission_id}"
    NoRun(..) =>
      match self.last_run_id {
        Some(run_id) => run_id
        None => "idle"
      }
  }
}

///|
test "transcript row identities include event ordinals and stable notice ids" {
  let with_notice = {
    ..test_conversation(),
    messages: [
      { kind: User, content: "question", ts: None, sequence: Some(41) },
      {
        kind: Assistant(is_danger=false),
        content: "answer",
        ts: None,
        sequence: Some(41),
      },
    ],
  }.append_local_notice(Assistant(is_danger=true), "local failure")
  assert_eq(with_notice.visible_transcript_rows().map(row => row.identity), [
    "s41\u{0}o0", "s41\u{0}o1", "n1",
  ])
  // A notice keeps the key it was allocated wherever its boundary places it,
  // rather than deriving one from whichever array slot it occupies.
  let moved = {
    ..with_notice,
    overlay: [{ ..with_notice.overlay[0], after_messages: 1 }],
  }
  assert_eq(moved.visible_transcript_rows().map(row => row.identity), [
    "s41\u{0}o0", "n1", "s41\u{0}o1",
  ])
  let twice = moved.append_local_notice(Assistant(is_danger=true), "second")
  assert_eq(twice.overlay[1].id, 2)
}
