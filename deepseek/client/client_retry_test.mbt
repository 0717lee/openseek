///|
/// A server whose first `failures` responses are `status`, after which it
/// serves a minimal valid chat completion (or an SSE stream when `sse`).
/// Returns the endpoint URL and a counter of requests actually received.
async fn flaky_server(
  group : @async.TaskGroup[Unit],
  failures~ : Int,
  status~ : Int,
  sse? : Bool = false,
) -> (String, Ref[Int])? {
  guard bind_test_server("local TCP bind unavailable; skipping retry test")
    is Some(server) else {
    return None
  }
  let hits : Ref[Int] = { val: 0 }
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(
      (_request, body, conn) => {
        let _ = body.read_all()
        hits.val = hits.val + 1
        if hits.val <= failures {
          conn.send_response(status, "Error", extra_headers={
            "Content-Type": "text/plain",
          })
          conn.write("synthetic failure")
        } else if sse {
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          conn.write(
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n",
          )
          conn.write("data: [DONE]\n\n")
        } else {
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "application/json",
          })
          conn.write(
            "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}",
          )
        }
      },
      max_connections=8,
    )
  }
  Some(("http://127.0.0.1:\{server.addr.port()}/chat/completions", hits))
}

///|
async test "chat retries transient 5xx and succeeds" {
  @async.with_task_group() <| group => {
    guard flaky_server(group, failures=2, status=503) is Some((url, hits)) else {
      return
    }
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=3,
      retry_backoff_ms=1,
    )
    let response = client.chat([ChatMessage(User, content="hello")])
    assert_eq(response.content, "ok")
    assert_eq(hits.val, 3)
  }
}

///|
async test "chat gives up after the retry budget with the API error" {
  @async.with_task_group() <| group => {
    guard flaky_server(group, failures=99, status=500) is Some((url, hits)) else {
      return
    }
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=2,
      retry_backoff_ms=1,
    )
    let _ = client.chat([ChatMessage(User, content="hello")]) catch {
      error => {
        assert_true("\{error}".contains("DeepSeek API error 500"))
        assert_eq(hits.val, 2)
        return
      }
    }
    fail("expected exhausted retries")
  }
}

///|
async test "chat never retries a non-429 client error" {
  @async.with_task_group() <| group => {
    guard flaky_server(group, failures=99, status=400) is Some((url, hits)) else {
      return
    }
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=3,
      retry_backoff_ms=1,
    )
    let _ = client.chat([ChatMessage(User, content="hello")]) catch {
      error => {
        assert_true("\{error}".contains("DeepSeek API error 400"))
        assert_eq(hits.val, 1)
        return
      }
    }
    fail("expected immediate failure")
  }
}

///|
async test "streaming chat retries a pre-stream 429 and then streams" {
  @async.with_task_group() <| group => {
    guard flaky_server(group, failures=1, status=429, sse=true)
      is Some((url, hits)) else {
      return
    }
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=3,
      retry_backoff_ms=1,
    )
    defer client.close()
    let deltas : Array[String] = []
    let response = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=delta => deltas.push(delta)),
    )
    assert_eq(response.content, "ok")
    assert_eq(deltas.join("|"), "ok")
    assert_eq(hits.val, 2)
  }
}

///|
async test "streaming Kimi chat retries a pre-stream 502 and then streams" {
  @async.with_task_group() <| group => {
    guard flaky_server(group, failures=1, status=502, sse=true)
      is Some((url, hits)) else {
      return
    }
    let client = @client.Client(
      api_key="test-key",
      model=Kimi(K27Code),
      api_url=url,
      retry_attempts=3,
      retry_backoff_ms=1,
    )
    defer client.close()
    let deltas : Array[String] = []
    let response = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=delta => deltas.push(delta)),
    )
    assert_eq(response.content, "ok")
    assert_eq(deltas.join("|"), "ok")
    assert_eq(hits.val, 2)
  }
}

///|
/// A 2xx connection that dies before any event is transport-shaped: with no
/// delta delivered, the stream call retries and the second connection
/// serves the full stream.
async test "streaming chat retries a pre-delta stream drop" {
  @async.with_task_group() <| group => {
    guard bind_test_server("local TCP bind unavailable; skipping retry test")
      is Some(server) else {
      return
    }
    let hits : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(
        (_request, body, conn) => {
          let _ = body.read_all()
          hits.val = hits.val + 1
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          if hits.val > 1 {
            conn.write(
              "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n",
            )
            conn.write("data: [DONE]\n\n")
          }
        },
        max_connections=8,
      )
    }
    let url = "http://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=3,
      retry_backoff_ms=1,
    )
    defer client.close()
    let response = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=_ => ()),
    )
    assert_eq(response.content, "ok")
    assert_eq(hits.val, 2)
  }
}

///|
/// An actively refused port is deterministic and should fail on the ordinary
/// attempt budget rather than consume the long bad-edge retry window. Reserve
/// and close a loopback port first to produce `ECONNREFUSED` reliably.
async test "streaming TCP refusal does not consume the long connect window" {
  @async.with_task_group() <| _ => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
      _ => {
        println("local TCP bind unavailable; skipping retry test")
        return
      }
    }
    let port = server.addr.port()
    server.close()
    let url = "https://127.0.0.1:\{port}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=2,
      retry_backoff_ms=1,
      connect_retry_window_ms=100,
    )
    let _ = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=_ => ()),
    ) catch {
      error => {
        let message = "\{error}"
        assert_true(message.contains("before any response event"))
        assert_true(message.contains("after 2 attempts"))
        assert_true(message.contains("DNS/TCP/TLS setup"))
        assert_true(message.contains("OSError"))
        assert_false(message.contains("attempts over"))
        return
      }
    }
    fail("expected exhausted connection retries")
  }
}

///|
/// TLS implementations classify an EOF during the handshake differently.
/// Regardless of whether it surfaces as `ConnectionClosed` or `TlsError`, the
/// client can retry it safely because the HTTP request has not started.
async test "streaming TLS handshake close retries before sending the request" {
  @async.with_task_group() <| group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
      _ => {
        println("local TCP bind unavailable; skipping retry test")
        return
      }
    }
    let hits : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever((_, _) => hits.val = hits.val + 1, max_connections=8)
    }
    let url = "https://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=1,
      retry_backoff_ms=1,
      connect_retry_window_ms=100,
    )
    let _ = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=_ => ()),
    ) catch {
      error => {
        let message = "\{error}"
        assert_true(message.contains("before sending the request"))
        assert_true(message.contains("DNS/TCP/TLS setup"))
        assert_true(message.contains("attempts over"))
        assert_true(hits.val > 1)
        return
      }
    }
    fail("expected exhausted TLS connection retries")
  }
}

///|
/// Disabling the separate setup window must leave the ordinary request retry
/// policy intact. Each outer attempt gets one setup try, so two configured
/// attempts should produce two accepted and immediately closed connections.
async test "disabled setup window falls back to ordinary retries" {
  @async.with_task_group() <| group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
      _ => {
        println("local TCP bind unavailable; skipping retry test")
        return
      }
    }
    let hits : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever((_, _) => hits.val = hits.val + 1, max_connections=8)
    }
    let url = "https://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=2,
      retry_backoff_ms=1,
      connect_retry_window_ms=0,
    )
    let _ = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=_ => ()),
    ) catch {
      error => {
        let message = "\{error}"
        assert_true(message.contains("before any response event"))
        assert_true(message.contains("after 2 attempts"))
        assert_true(message.contains("DNS/TCP/TLS setup"))
        assert_false(message.contains("attempts over"))
        assert_eq(hits.val, 2)
        return
      }
    }
    fail("expected exhausted ordinary retries")
  }
}

///|
/// Bare async transport errors such as TLS `ConnectionClosed` do not say at
/// which request stage they occurred. Preserve the I/O phase and attempt count
/// when retries are exhausted so the user sees an actionable failure instead
/// of only the low-level error name.
async test "exhausted pre-event transport error reports phase and attempts" {
  @async.with_task_group() <| group => {
    guard bind_test_server("local TCP bind unavailable; skipping retry test")
      is Some(server) else {
      return
    }
    let hits : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(
        (_request, body, conn) => {
          let _ = body.read_all()
          hits.val = hits.val + 1
          conn.close()
        },
        max_connections=4,
      )
    }
    let url = "http://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=2,
      retry_backoff_ms=1,
    )
    let _ = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=_ => ()),
    ) catch {
      error => {
        let message = "\{error}"
        assert_true(message.contains("before any response event"))
        assert_true(message.contains("after 2 attempts"))
        assert_true(message.contains("waiting for response headers"))
        assert_eq(hits.val, 2)
        return
      }
    }
    fail("expected exhausted transport retries")
  }
}

///|
/// Once a delta has been delivered, a failure must surface instead of
/// retrying — replaying the stream would hand the consumer duplicate
/// content. The server streams one delta then ends without [DONE] on every
/// request, so a retry (if one wrongly happened) would be observable as a
/// second hit.
async test "streaming chat never retries after the first delta" {
  @async.with_task_group() <| group => {
    guard bind_test_server("local TCP bind unavailable; skipping retry test")
      is Some(server) else {
      return
    }
    let hits : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(
        (_request, body, conn) => {
          let _ = body.read_all()
          hits.val = hits.val + 1
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          conn.write(
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n",
          )
        },
        max_connections=8,
      )
    }
    let url = "http://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=3,
      retry_backoff_ms=1,
    )
    let deltas : Array[String] = []
    let _ = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=delta => deltas.push(delta)),
    ) catch {
      error => {
        assert_true("\{error}".contains("ended before [DONE]"))
        assert_eq(deltas.join("|"), "partial")
        assert_eq(hits.val, 1)
        return
      }
    }
    fail("expected truncated stream error")
  }
}

///|
/// Tool-call deltas carry no text, so the content callbacks never fire —
/// but they are model output all the same. A stream that emits only a
/// tool-call delta and then drops must surface the failure rather than
/// retry: a replay could generate (and bill) a different call. (Codex
/// review: the bail flag used to track callback-delivered text only.)
async test "streaming chat never retries after a tool-call-only delta" {
  @async.with_task_group() <| group => {
    guard bind_test_server("local TCP bind unavailable; skipping retry test")
      is Some(server) else {
      return
    }
    let hits : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(
        (_request, body, conn) => {
          let _ = body.read_all()
          hits.val = hits.val + 1
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          conn.write(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]}}]}\n\n",
          )
        },
        max_connections=8,
      )
    }
    let url = "http://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=3,
      retry_backoff_ms=1,
    )
    let _ = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=_ => ()),
    ) catch {
      error => {
        assert_true("\{error}".contains("ended before [DONE]"))
        assert_eq(hits.val, 1)
        return
      }
    }
    fail("expected truncated stream error")
  }
}
