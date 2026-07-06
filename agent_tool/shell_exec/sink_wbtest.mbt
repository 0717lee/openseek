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
test "split_valid_utf8 carries an incomplete trailing character across chunks" {
  // "café" = 63 61 66 C3 A9 (é is a 2-byte sequence).
  let full : Bytes = [0x63, 0x61, 0x66, 0xC3, 0xA9]
  let (text, rest) = split_valid_utf8(full)
  assert_true(text == "café")
  assert_true(rest.length() == 0)
  // A chunk that ends on é's lead byte: decode "caf" now, hold the lead byte.
  let truncated : Bytes = [0x63, 0x61, 0x66, 0xC3]
  let (head, tail) = split_valid_utf8(truncated)
  assert_true(head == "caf")
  assert_true(tail.length() == 1)
  // The next chunk's continuation byte completes é rather than corrupting it.
  let joined = Buffer()
  joined.write_bytes(tail)
  joined.write_bytes(([0xA9] : Bytes))
  let (completed, remainder) = split_valid_utf8(joined.to_bytes())
  assert_true(completed == "é")
  assert_true(remainder.length() == 0)
}

///|
test "split_valid_utf8 surfaces corrupt trailing bytes instead of hiding them" {
  // 0xff is neither a valid lead nor a continuation byte: it must be decoded
  // (lossily) right away, not held in pending bytes waiting for a completion
  // that can never come — otherwise a running job's output would vanish.
  let bytes : Bytes = [0x68, 0x69, 0xff]
  let (text, rest) = split_valid_utf8(bytes)
  assert_true(rest.length() == 0)
  assert_true(text.has_prefix("hi"))
  assert_true(text.char_length() >= 3)
}

///|
test "split_valid_utf8 does not carry malformed multi-byte prefixes" {
  // 0xE0 0x80 looks like the start of a 3-byte char, but 0x80 is below the
  // legal 0xA0 for 0xE0 (an overlong encoding) — surface it now, don't hold it.
  let (t1, r1) = split_valid_utf8(([0x78, 0xE0, 0x80] : Bytes))
  assert_true(r1.length() == 0)
  assert_true(t1.has_prefix("x"))
  // 0xF4 0x90 is out of range (0xF4 continuations must be 0x80..0x8F).
  let (t2, r2) = split_valid_utf8(([0x78, 0xF4, 0x90] : Bytes))
  assert_true(r2.length() == 0)
  assert_true(t2.has_prefix("x"))
  // A genuinely valid incomplete prefix (0xE0 0xA0, missing its last byte) is
  // still carried, so real multi-byte output is not corrupted.
  let (t3, r3) = split_valid_utf8(([0x78, 0xE0, 0xA0] : Bytes))
  assert_true(t3 == "x")
  assert_true(r3.length() == 2)
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
