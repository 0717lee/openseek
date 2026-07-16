// Private bindings to the async runtime's last signal observation. These are
// read only while unwinding the desktop main task, so a one-off cancellation
// still leaves enough evidence in the durable launch log to distinguish a
// real waited signal from mask setup or console-control handling.

///|
// 0 = none, 1 = POSIX mask setup, 2 = POSIX sigwait return,
// 3 = Windows console control.
extern "C" fn async_signal_diagnostic_event() -> Int = "moonbitlang_async_signal_diagnostic_event"

///|
fn async_signal_diagnostic_event_name(event : Int) -> String {
  match event {
    0 => "none"
    1 => "mask_setup"
    2 => "sigwait_return"
    3 => "console_control"
    code => "unknown_\{code}"
  }
}

///|
extern "C" fn async_signal_diagnostic_signal() -> Int = "moonbitlang_async_signal_diagnostic_signal"

///|
extern "C" fn async_signal_diagnostic_wait_result() -> Int = "moonbitlang_async_signal_diagnostic_wait_result"

///|
extern "C" fn async_signal_diagnostic_wait_errno() -> Int = "moonbitlang_async_signal_diagnostic_wait_errno"

///|
extern "C" fn async_signal_diagnostic_mask_result() -> Int = "moonbitlang_async_signal_diagnostic_mask_result"

///|
extern "C" fn async_signal_diagnostic_signal_in_waitset() -> Int = "moonbitlang_async_signal_diagnostic_signal_in_waitset"

///|
extern "C" fn async_signal_diagnostic_sigusr2_blocked() -> Int = "moonbitlang_async_signal_diagnostic_sigusr2_blocked"

///|
extern "C" fn async_signal_diagnostic_cancel_requests_at_return() -> Int = "moonbitlang_async_signal_diagnostic_cancel_requests_at_return"

///|
extern "C" fn async_signal_diagnostic_sigwait_cancel_requests_at_return() -> Int = "moonbitlang_async_signal_diagnostic_sigwait_cancel_requests_at_return"

///|
extern "C" fn async_worker_cancel_diagnostic_request_count() -> Int = "moonbitlang_async_worker_cancel_diagnostic_request_count"

///|
extern "C" fn async_worker_cancel_diagnostic_recent_bytes() -> Bytes = "moonbitlang_async_worker_cancel_diagnostic_recent"

///|
fn async_worker_cancel_diagnostic_recent() -> String {
  @utf8.decode_lossy(async_worker_cancel_diagnostic_recent_bytes())
}
