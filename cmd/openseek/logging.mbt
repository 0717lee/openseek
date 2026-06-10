///|
priv struct FlushedStdout {
  format : @xlog.Format
}

///|
fn FlushedStdout::FlushedStdout(
  format? : @xlog.Format = Jsonl,
) -> FlushedStdout {
  { format, }
}

///|
#borrow(data)
extern "C" fn write_flushed_stdout_line_ffi(data : Bytes) -> Int = "openseek_write_flushed_stdout_line"

///|
fn write_flushed_stdout_line(text : String) -> Unit raise {
  guard write_flushed_stdout_line_ffi(@utf8.encode(text)) == 0 else {
    fail("failed to write stdout")
  }
}

///|
impl @xlog.Handler for FlushedStdout with fn handle(
  self : FlushedStdout,
  entry : @xlog.Entry,
) -> Unit raise {
  let line = match self.format {
    Text => entry.to_string()
    Jsonl => entry.to_json().stringify()
  }
  write_flushed_stdout_line(line)
}
