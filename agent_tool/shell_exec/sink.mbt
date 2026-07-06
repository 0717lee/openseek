///|
/// Default inline cap: output at or below this many characters is shown inline;
/// larger output is rendered as a file pointer by the consumer. Matches the
/// shell tool's foreground default so a command reads the same either way.
pub let default_inline_cap : Int = 12000

///|
/// Default hard cap: the sink retains at most this many characters (a *prefix*)
/// in memory, bounding memory even for a runaway producer. The size watchdog is
/// expected to kill a backgrounded job well before this, so it is a backstop.
pub let default_hard_cap : Int = 1_000_000

///|
/// One owner for a single command's merged stdout+stderr, replacing both the
/// foreground prefix-cap and `bgjobs`' tail-cap with a single policy: retain the
/// output *prefix* (the start of compiler/test errors matters most) up to
/// `hard_cap`, decode UTF-8 across chunk boundaries, and expose enough for the
/// consumer to render the result inline or as a file pointer.
///
/// Pure and in-memory: the file spill for large output is a consumer step (it
/// writes `text()` to a file and shows a pointer when `over_inline_cap()`), so
/// this stays synchronous and trivially testable. Retained output is accumulated
/// in a `StringBuilder`, so appending a chunk is amortized O(chunk), not O(total)
/// as a naive `output + chunk` per chunk would be.
pub struct ShellOutputSink {
  priv builder : StringBuilder
  // Retained character count (== builder length); tracked so `size()` and the
  // hard-cap check never re-scan the whole buffer.
  priv mut char_count : Int
  // Trailing bytes of an incomplete UTF-8 sequence split across read chunks,
  // decoded once the rest arrives (or lossily at `finish`).
  priv mut pending : Bytes
  // Bumps whenever retained output grows, so a poller can tell if new output
  // arrived since it last looked.
  priv mut seq : Int
  // Set once output was dropped at the hard cap.
  priv mut truncated : Bool
  priv inline_cap : Int
  priv hard_cap : Int
}

///|
/// Create an empty sink. Non-positive caps are clamped to 1, so a degenerate
/// budget still bounds retention rather than disabling it.
pub fn ShellOutputSink::new(
  inline_cap? : Int = default_inline_cap,
  hard_cap? : Int = default_hard_cap,
) -> ShellOutputSink {
  {
    builder: StringBuilder(),
    char_count: 0,
    pending: b"",
    seq: 0,
    truncated: false,
    inline_cap: if inline_cap > 0 {
      inline_cap
    } else {
      1
    },
    hard_cap: if hard_cap > 0 {
      hard_cap
    } else {
      1
    },
  }
}

///|
/// Feed a raw output chunk from the process reader, decoding UTF-8 across chunk
/// boundaries — an incomplete trailing sequence is carried to the next chunk so
/// a multi-byte character on a boundary is not corrupted.
pub fn ShellOutputSink::append_chunk(
  self : ShellOutputSink,
  chunk : Bytes,
) -> Unit {
  let buffer = Buffer()
  buffer.write_bytes(self.pending)
  buffer.write_bytes(chunk)
  let (text, rest) = split_valid_utf8(buffer.to_bytes())
  self.pending = rest
  self.append_text(text)
}

///|
/// Feed already-decoded text. Retains the prefix up to `hard_cap`; any further
/// output is dropped and `truncated` is set. `seq` bumps only when retained
/// output actually grows.
pub fn ShellOutputSink::append_text(
  self : ShellOutputSink,
  text : String,
) -> Unit {
  guard text != "" else { return }
  guard !self.truncated else { return }
  let room = self.hard_cap - self.char_count
  guard room > 0 else {
    self.truncated = true
    return
  }
  let piece = if text.char_length() <= room {
    text
  } else {
    self.truncated = true
    prefix_chars(text, room)
  }
  self.builder.write_string(piece)
  self.char_count += piece.char_length()
  self.seq += 1
}

///|
/// Flush any incomplete trailing UTF-8 bytes at end of stream (decoded lossily),
/// so a multi-byte character that never completed is surfaced rather than lost.
pub fn ShellOutputSink::finish(self : ShellOutputSink) -> Unit {
  guard self.pending.length() > 0 else { return }
  let text = @utf8.decode_lossy(self.pending)
  self.pending = b""
  self.append_text(text)
}

///|
/// Retained character count (≤ `hard_cap`).
pub fn ShellOutputSink::size(self : ShellOutputSink) -> Int {
  self.char_count
}

///|
/// Output version, bumped whenever retained output grows.
pub fn ShellOutputSink::seq(self : ShellOutputSink) -> Int {
  self.seq
}

///|
/// Whether output was dropped at the hard cap.
pub fn ShellOutputSink::truncated(self : ShellOutputSink) -> Bool {
  self.truncated
}

///|
/// The full retained output (the prefix, up to `hard_cap`).
pub fn ShellOutputSink::text(self : ShellOutputSink) -> String {
  self.builder.to_string()
}

///|
/// Retained characters from `offset` onward — for polling only the output added
/// since a previous `size()`. An out-of-range offset yields "".
pub fn ShellOutputSink::tail_from(
  self : ShellOutputSink,
  offset : Int,
) -> String {
  guard offset >= 0 && offset < self.char_count else { return "" }
  let text = self.builder.to_string()
  match text.offset_of_nth_char(offset) {
    Some(start) => "\{text[start:]}"
    None => ""
  }
}

///|
/// Whether the consumer should render a file pointer instead of inline output.
pub fn ShellOutputSink::over_inline_cap(self : ShellOutputSink) -> Bool {
  self.char_count > self.inline_cap
}

///|
/// First `n` characters of `text` (assumes `n < text.char_length()`).
fn prefix_chars(text : String, n : Int) -> String {
  match text.offset_of_nth_char(n) {
    Some(end) => "\{text[:end]}"
    None => text
  }
}

///|
/// Split `bytes` into the longest valid-UTF-8 prefix (decoded lossily) and the
/// trailing bytes of an incomplete multi-byte sequence to carry to the next
/// chunk. A malformed (not merely incomplete) trailing sequence is surfaced now
/// rather than held for a completion that can never be valid.
fn split_valid_utf8(bytes : Bytes) -> (String, Bytes) {
  let end = bytes.length() - incomplete_suffix_len(bytes)
  let tail = Buffer()
  tail.write_bytes(bytes[end:])
  (@utf8.decode_lossy(bytes[:end]), tail.to_bytes())
}

///|
fn incomplete_suffix_len(bytes : Bytes) -> Int {
  let len = bytes.length()
  let lookback = if len < 3 { len } else { 3 }
  for i in 0..<lookback {
    let pos = len - 1 - i
    let b = bytes[pos].to_int()
    if b < 0x80 {
      // A complete ASCII byte; anything after it is a stray continuation.
      return 0
    }
    if b >= 0xC0 {
      // A lead byte: carry it only while its sequence is still incomplete AND
      // the continuation bytes already seen are legal for it — otherwise the
      // sequence is malformed (overlong / out of range) and must be surfaced
      // now rather than held for a completion that can never be valid.
      let expected = utf8_sequence_len(b)
      let have = len - pos
      guard expected != 0 && expected > have else { return 0 }
      for j in 1..<have {
        let (lo, hi) = continuation_range(b, j)
        let cb = bytes[pos + j].to_int()
        if cb < lo || cb > hi {
          return 0
        }
      }
      return have
    }
    // 0x80..=0xBF: a continuation byte — keep scanning back for its lead.
  }
  0
}

///|
fn utf8_sequence_len(b : Int) -> Int {
  if b >= 0xF0 && b <= 0xF4 {
    4
  } else if b >= 0xE0 && b <= 0xEF {
    3
  } else if b >= 0xC2 && b <= 0xDF {
    2
  } else {
    0
  }
}

///|
fn continuation_range(lead : Int, j : Int) -> (Int, Int) {
  if j == 1 {
    if lead == 0xE0 {
      (0xA0, 0xBF)
    } else if lead == 0xED {
      (0x80, 0x9F)
    } else if lead == 0xF0 {
      (0x90, 0xBF)
    } else if lead == 0xF4 {
      (0x80, 0x8F)
    } else {
      (0x80, 0xBF)
    }
  } else {
    (0x80, 0xBF)
  }
}
