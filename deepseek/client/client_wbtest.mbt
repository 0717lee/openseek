///|
/// Fast failures must not exhaust an attempt count before the DNS/edge retry
/// window expires. The bounded final sleep puts one last connect exactly at
/// the 65s deadline: 0, .5, 1.5, 3.5, 7.5, 15.5, 31.5, 63.5, 65 seconds.
test "connect retry schedule reaches the wall-clock deadline" {
  let deadline : Int64 = 65_000
  let starts : Array[Int64] = [0]
  let mut now : Int64 = 0
  let mut backoff_ms = 500
  for ;; {
    match connect_retry_sleep_ms(now, deadline, backoff_ms) {
      None => break
      Some(sleep_ms) => {
        now = now + sleep_ms.to_int64()
        starts.push(now)
        backoff_ms = max_backoff_ms.min(backoff_ms * 2)
      }
    }
  }
  debug_inspect(
    starts,
    content="[0, 500, 1500, 3500, 7500, 15500, 31500, 63500, 65000]",
  )
  assert_eq(connect_retry_sleep_ms(deadline, deadline, 500), None)
}

///|
/// A query can begin the request target even when the endpoint has no explicit
/// slash after its authority. The reusable client must retain that query and
/// normalize the target to origin-form with a leading slash.
test "query-only API endpoints preserve their request target" {
  assert_eq(
    split_api_endpoint("https://api.example?api-version=1"),
    ("https://api.example", "/?api-version=1"),
  )
  assert_eq(
    split_api_endpoint("https://api.example/chat?api-version=1"),
    ("https://api.example", "/chat?api-version=1"),
  )
}
