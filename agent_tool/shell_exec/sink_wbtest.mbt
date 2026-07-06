///|
test "small output is retained inline" {
  let sink = ShellOutputSink::new(inline_cap=100)
  sink.append_text("hello")
  assert_eq(sink.text(), "hello")
  assert_eq(sink.size(), 5)
  assert_false(sink.over_inline_cap())
  assert_false(sink.truncated())
}

///|
test "output over the inline cap keeps the full prefix and flags a pointer" {
  let sink = ShellOutputSink::new(inline_cap=4, hard_cap=100)
  sink.append_text("abcdefgh")
  assert_true(sink.over_inline_cap())
  // Under the hard cap: nothing dropped, full text kept — the pointer is a
  // rendering choice, not a truncation.
  assert_false(sink.truncated())
  assert_eq(sink.text(), "abcdefgh")
  assert_eq(sink.size(), 8)
}

///|
test "output over the hard cap retains the prefix and truncates" {
  let sink = ShellOutputSink::new(inline_cap=2, hard_cap=5)
  sink.append_text("abc")
  sink.append_text("defgh") // total 8 > 5
  assert_true(sink.truncated())
  assert_eq(sink.size(), 5)
  assert_eq(sink.text(), "abcde") // the prefix, not a tail
  // Further output is dropped and must not bump seq.
  let seq_before = sink.seq()
  sink.append_text("xyz")
  assert_eq(sink.seq(), seq_before)
  assert_eq(sink.text(), "abcde")
}

///|
test "tail_from returns only output added since an offset" {
  let sink = ShellOutputSink::new()
  sink.append_text("hello ")
  let mark = sink.size()
  sink.append_text("world")
  assert_eq(sink.tail_from(mark), "world")
  assert_eq(sink.tail_from(0), "hello world")
  assert_eq(sink.tail_from(sink.size()), "")
  assert_eq(sink.tail_from(999), "")
}

///|
test "seq bumps only when retained output grows" {
  let sink = ShellOutputSink::new()
  assert_eq(sink.seq(), 0)
  sink.append_text("a")
  assert_eq(sink.seq(), 1)
  sink.append_text("") // empty append is a no-op
  assert_eq(sink.seq(), 1)
  sink.append_text("b")
  assert_eq(sink.seq(), 2)
}

///|
test "append_chunk decodes utf-8 across a chunk boundary" {
  let sink = ShellOutputSink::new()
  // "café" = 63 61 66 C3 A9, split between é's lead and continuation byte.
  sink.append_chunk(([0x63, 0x61, 0x66, 0xC3] : Bytes))
  sink.append_chunk(([0xA9] : Bytes))
  assert_eq(sink.text(), "café")
}

///|
test "finish flushes an incomplete trailing sequence lossily" {
  let sink = ShellOutputSink::new()
  // A lone 0xC3 (a 2-byte lead, no continuation) stays pending until finish.
  sink.append_chunk(([0x68, 0x69, 0xC3] : Bytes))
  assert_eq(sink.text(), "hi")
  sink.finish()
  assert_true(sink.size() >= 3) // the lossy replacement char is now surfaced
}
