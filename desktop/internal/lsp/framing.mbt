// The LSP base protocol's wire framing: JSON-RPC message bodies on a byte
// stream, each prefixed with a `Content-Length` header (DAP uses the same). This
// is the framing `@jsonrpc` deliberately leaves out; `StreamTransport` applies
// it over a reader/writer.

///|
/// Frame a message body for the stream. The `Content-Length` counts the body's
/// UTF-8 *bytes*, not its code units, so multi-byte content frames correctly.
fn frame_message(body : String) -> String {
  "Content-Length: " +
  @utf8.encode(body).length().to_string() +
  "\r\n\r\n" +
  body
}

///|
/// Parse a `Content-Length:` header line (case-insensitive, tolerant of the
/// trailing CRLF), returning the announced byte count. `None` for any other
/// header line, so the reader can skip headers it does not care about.
fn parse_content_length(line : String) -> Int? {
  let trimmed = line.trim(char_set="\r\n ")
  let prefix = "content-length:"
  guard trimmed.to_lower().strip_prefix(prefix) is Some(length) else {
    return None
  }
  Some(@string.parse_int(length.trim(), base=10)) catch {
    _ => None
  }
}

///|
/// Read one Content-Length-framed message body from `reader`. `None` at end of
/// stream; raises on a read or UTF-8 decode error, which the transport surfaces
/// to the client as end of stream.
async fn read_frame(reader : &@io.Reader) -> String? {
  let mut content_length = -1
  for ;; {
    guard reader.read_until("\n") is Some(line) else { return None }
    // A bare CRLF terminates the header block.
    if line.trim(char_set="\r\n") == "" {
      break
    }
    if parse_content_length(line) is Some(length) {
      content_length = length
    }
  }
  guard content_length >= 0 else { return None }
  let body = reader.read_exactly(content_length)
  Some(@utf8.decode(body))
}

///|
test "frame_message prefixes the byte length and a blank line" {
  assert_eq(frame_message("hi"), "Content-Length: 2\r\n\r\nhi")
  // The length is in UTF-8 bytes: "é" is one code unit but two bytes.
  assert_eq(frame_message("é"), "Content-Length: 2\r\n\r\né")
  assert_eq(frame_message(""), "Content-Length: 0\r\n\r\n")
}

///|
test "parse_content_length is case-insensitive and tolerates CRLF and spaces" {
  assert_true(parse_content_length("Content-Length: 42") is Some(42))
  assert_true(parse_content_length("content-length:7\r\n") is Some(7))
  assert_true(parse_content_length("CONTENT-LENGTH:   128  \r\n") is Some(128))
}

///|
test "parse_content_length rejects other headers and junk" {
  assert_true(parse_content_length("Content-Type: application/json") is None)
  assert_true(parse_content_length("Content-Length: not-a-number") is None)
  assert_true(parse_content_length("") is None)
}
