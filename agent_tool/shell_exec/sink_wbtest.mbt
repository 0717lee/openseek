///|
async test "small output stays in memory, no file" {
  let sink = ShellOutputSink::new(inline_cap=100)
  sink.append_text("hello")
  assert_eq(sink.head(), "hello")
  assert_eq(sink.read_all(), "hello")
  assert_eq(sink.size(), 5)
  assert_false(sink.over_inline_cap())
  assert_true(sink.spill_path() is None)
  assert_false(sink.truncated())
}

///|
async test "output over the inline cap spills; read_all returns everything, head previews" {
  let path = "/tmp/openseek-sink-spill-1.out"
  let sink = ShellOutputSink::new(inline_cap=4, hard_cap=1000, spill_path=path)
  sink.append_text("abcdefghij")
  assert_true(sink.over_inline_cap())
  assert_true(sink.spill_path() is Some(_))
  // Head is the first inline_cap chars (a preview); read_all is the full output.
  assert_eq(sink.head(), "abcd")
  assert_eq(sink.read_all(), "abcdefghij")
  assert_eq(sink.size(), 10)
  sink.close()
}

///|
async test "the spill file is seeded with output buffered before the spill" {
  let path = "/tmp/openseek-sink-spill-2.out"
  let sink = ShellOutputSink::new(inline_cap=4, hard_cap=1000, spill_path=path)
  sink.append_text("ab") // total 2, under inline cap: memory only, no file yet
  assert_false(sink.over_inline_cap())
  sink.append_text("cdef") // total 6 > 4: spill, seeding the file with "ab"
  assert_eq(sink.read_all(), "abcdef") // seed + new chunk, in order
  assert_eq(sink.head(), "abcd")
  sink.close()
}

///|
async test "memory-only (no spill path) keeps the head and drops the rest" {
  let sink = ShellOutputSink::new(inline_cap=4, hard_cap=1000)
  sink.append_text("abcdefghij")
  assert_true(sink.over_inline_cap())
  assert_true(sink.spill_path() is None)
  // No file: read_all is the bounded head, not the full output.
  assert_eq(sink.read_all(), "abcd")
  assert_eq(sink.size(), 10) // size still reports what was produced
}

///|
async test "output over the hard cap truncates" {
  let sink = ShellOutputSink::new(inline_cap=2, hard_cap=5)
  sink.append_text("abc")
  sink.append_text("defgh") // total 8 > 5
  assert_true(sink.truncated())
  assert_eq(sink.size(), 5)
  let seq_before = sink.seq()
  sink.append_text("xyz") // dropped, no seq bump
  assert_eq(sink.seq(), seq_before)
}

///|
async test "append_chunk decodes utf-8 across a chunk boundary" {
  let sink = ShellOutputSink::new(inline_cap=100)
  // "café" = 63 61 66 C3 A9, split between é's lead and continuation byte.
  sink.append_chunk(([0x63, 0x61, 0x66, 0xC3] : Bytes))
  sink.append_chunk(([0xA9] : Bytes))
  assert_eq(sink.head(), "café")
}

///|
async test "finish flushes an incomplete trailing sequence lossily" {
  let sink = ShellOutputSink::new(inline_cap=100)
  sink.append_chunk(([0x68, 0x69, 0xC3] : Bytes))
  assert_eq(sink.head(), "hi")
  sink.finish()
  assert_true(sink.size() >= 3)
}

///|
test "split_valid_utf8 surfaces corrupt trailing bytes instead of hiding them" {
  let bytes : Bytes = [0x68, 0x69, 0xff]
  let (text, rest) = split_valid_utf8(bytes)
  assert_true(rest.length() == 0)
  assert_true(text.has_prefix("hi"))
  assert_true(text.char_length() >= 3)
}

///|
test "split_valid_utf8 does not carry malformed multi-byte prefixes" {
  let (t1, r1) = split_valid_utf8(([0x78, 0xE0, 0x80] : Bytes))
  assert_true(r1.length() == 0)
  assert_true(t1.has_prefix("x"))
  let (t2, r2) = split_valid_utf8(([0x78, 0xF4, 0x90] : Bytes))
  assert_true(r2.length() == 0)
  assert_true(t2.has_prefix("x"))
  let (t3, r3) = split_valid_utf8(([0x78, 0xE0, 0xA0] : Bytes))
  assert_true(t3 == "x")
  assert_true(r3.length() == 2)
}
