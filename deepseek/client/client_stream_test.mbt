///|
async fn stream_test_server(
  group : @async.TaskGroup[Unit],
  finish? : Bool = true,
  kimi_usage? : Bool = false,
) -> String? {
  guard bind_test_server("local TCP bind unavailable; skipping stream test")
    is Some(server) else {
    return None
  }
  group.spawn_bg(no_wait=true) <| () => {
    server.run_forever(
      (request, body, conn) => {
        assert_eq(request.path, "/chat/completions")
        // The streaming request pins the identity encoding: a gzip-compressing
        // intermediary would buffer compression blocks and re-batch the SSE
        // deltas.
        assert_true(request.headers.get("accept-encoding") is Some("identity"))
        let request_body = body.read_all().text()
        assert_true(request_body.contains("\"stream\":true"))
        if kimi_usage {
          assert_true(request_body.contains("\"model\":\"kimi-k2.7-code\""))
          assert_true(request_body.contains("\"include_usage\":true"))
        } else {
          assert_true(request_body.contains("\"include_usage\":true"))
        }
        assert_false(request_body.contains("\"response_format\""))
        conn.send_response(200, "OK", extra_headers={
          "Content-Type": "text/event-stream",
        })
        conn.write(
          "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
        )
        conn.flush()
        conn.write(
          "data: {\"choices\":[{\"delta\":{\"content\":\" world\",\"reasoning_content\":\"hidden\",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\"\"}}]}}]}\n\n",
        )
        conn.write(
          if kimi_usage {
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":\\\"moon.mod\\\"}\"}}]},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":5,\"total_tokens\":8}}\n\n"
          } else {
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":\\\"moon.mod\\\"}\"}}]}}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":5,\"total_tokens\":8,\"prompt_cache_hit_tokens\":1,\"prompt_cache_miss_tokens\":2}}\n\n"
          },
        )
        if finish {
          conn.write("data: [DONE]\n\n")
        }
      },
      max_connections=1,
    )
  }
  Some("http://127.0.0.1:\{server.addr.port()}/chat/completions")
}

///|
async test "chat stream handler accumulates SSE content, tool calls, and usage" {
  @async.with_task_group() <| group => {
    guard stream_test_server(group) is Some(url) else { return }
    let client = @client.Client(api_key="test-key", api_url=url)
    defer client.close()
    let deltas : Array[String] = []
    let reasoning_deltas : Array[String] = []
    let callbacks : Array[String] = []
    let response = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(
        on_content_delta=delta => {
          deltas.push(delta)
          callbacks.push("content:\{delta}")
        },
        on_reasoning_delta=delta => {
          reasoning_deltas.push(delta)
          callbacks.push("reasoning:\{delta}")
        },
      ),
    )
    assert_eq(deltas.join("|"), "Hello| world")
    assert_eq(reasoning_deltas.join("|"), "hidden")
    assert_eq(
      callbacks.join("|"),
      "content:Hello|reasoning:hidden|content: world",
    )
    assert_eq(response.content, "Hello world")
    assert_eq(response.reasoning_content, "hidden")
    assert_eq(response.tool_calls.length(), 1)
    assert_eq(response.tool_calls[0].id, "call_1")
    assert_eq(response.tool_calls[0].name, "read")
    assert_eq(response.tool_calls[0].arguments, "{\"path\":\"moon.mod\"}")
    assert_eq(response.usage.prompt_tokens, 3)
    assert_eq(response.usage.completion_tokens, 5)
    assert_eq(response.usage.total_tokens, 8)
    assert_eq(response.usage.prompt_cache_hit_tokens, 1)
    assert_eq(response.usage.prompt_cache_miss_tokens, 2)
  }
}

///|
/// Sequential model rounds (especially tool-call loops) should reuse one
/// healthy HTTP/1.1 connection. Reconnecting every round repeats DNS, TCP, and
/// TLS setup and needlessly exposes the agent to a transient bad edge route.
async test "sequential streaming chats reuse a healthy connection" {
  @async.with_task_group() <| group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
      _ => {
        println("local TCP bind unavailable; skipping stream test")
        return
      }
    }
    let connections : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(
        (tcp, _peer) => {
          connections.val = connections.val + 1
          let conn = @http.ServerConnection::new(tcp)
          for ;; {
            let _request = conn.read_request()
            let _ = conn.read_all()
            conn.send_response(200, "OK", extra_headers={
              "Content-Type": "text/event-stream",
            })
            conn.write(
              "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n",
            )
            conn.write("data: [DONE]\n\n")
            conn.end_response()
          }
        },
        max_connections=2,
      )
    }
    let url = "http://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(api_key="test-key", api_url=url)
    defer client.close()
    for _ in 0..<2 {
      let response = client.chat(
        [ChatMessage(User, content="hello")],
        stream=StreamHandler(on_content_delta=_ => ()),
      )
      assert_eq(response.content, "ok")
    }
    assert_eq(connections.val, 1)
  }
}

///|
/// A peer's explicit `Connection: close` wins over otherwise valid response
/// framing. With one retry attempt, the second chat can only succeed if the
/// first socket was discarded proactively rather than checked back in.
async test "streaming chats do not retain Connection close responses" {
  @async.with_task_group() <| group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
      _ => {
        println("local TCP bind unavailable; skipping stream test")
        return
      }
    }
    let connections : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(
        (tcp, _peer) => {
          connections.val = connections.val + 1
          let conn = @http.ServerConnection::new(tcp)
          let _request = conn.read_request()
          let _ = conn.read_all()
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
            "Connection": "close",
          })
          conn.write("data: [DONE]\n\n")
          conn.end_response()
          conn.close()
        },
        max_connections=2,
      )
    }
    let url = "http://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=1,
    )
    defer client.close()
    for _ in 0..<2 {
      let response = client.chat(
        [ChatMessage(User, content="hello")],
        stream=StreamHandler(on_content_delta=_ => ()),
      )
      assert_eq(response.content, "")
    }
    assert_eq(connections.val, 2)
  }
}

///|
/// `[DONE]` alone is not enough to pool a socket: the terminating HTTP chunk
/// must also arrive. The first peer deliberately omits it, so the drain times
/// out and the next chat opens a fresh connection.
async test "streaming chats discard incomplete response framing" {
  @async.with_task_group() <| group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
      _ => {
        println("local TCP bind unavailable; skipping stream test")
        return
      }
    }
    let connections : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(
        (tcp, _peer) => {
          connections.val = connections.val + 1
          let connection_number = connections.val
          let conn = @http.ServerConnection::new(tcp)
          let _request = conn.read_request()
          let _ = conn.read_all()
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          conn.write("data: [DONE]\n\n")
          if connection_number == 1 {
            conn.flush()
            @async.sleep(1_500)
          } else {
            conn.end_response()
          }
          conn.close()
        },
        max_connections=2,
      )
    }
    let url = "http://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=1,
    )
    defer client.close()
    for _ in 0..<2 {
      let response = client.chat(
        [ChatMessage(User, content="hello")],
        stream=StreamHandler(on_content_delta=_ => ()),
      )
      assert_eq(response.content, "")
    }
    assert_eq(connections.val, 2)
  }
}

///|
/// A socket can become stale after it was validly pooled. Retrying the next
/// pre-event request must discard that socket, reconnect, and recover.
async test "streaming chat reconnects after a pooled socket becomes stale" {
  @async.with_task_group() <| group => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0")) catch {
      _ => {
        println("local TCP bind unavailable; skipping stream test")
        return
      }
    }
    let connections : Ref[Int] = { val: 0 }
    let requests : Ref[Int] = { val: 0 }
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(
        (tcp, _peer) => {
          connections.val = connections.val + 1
          let conn = @http.ServerConnection::new(tcp)
          let _request = conn.read_request()
          let _ = conn.read_all()
          requests.val = requests.val + 1
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          conn.write("data: [DONE]\n\n")
          conn.end_response()
          conn.close()
        },
        max_connections=2,
      )
    }
    let url = "http://127.0.0.1:\{server.addr.port()}/chat/completions"
    let client = @client.Client(
      api_key="test-key",
      api_url=url,
      retry_attempts=2,
      retry_backoff_ms=1,
    )
    defer client.close()
    for _ in 0..<2 {
      let response = client.chat(
        [ChatMessage(User, content="hello")],
        stream=StreamHandler(on_content_delta=_ => ()),
      )
      assert_eq(response.content, "")
    }
    assert_eq(connections.val, 2)
    assert_eq(requests.val, 2)
  }
}

///|
/// Closing is idempotent and prevents a new streaming request from opening a
/// connection. This also makes accidental use-after-close fail locally.
async test "closed client rejects new streaming chats" {
  let client = @client.Client(api_key="test-key")
  client.close()
  client.close()
  let _ = client.chat(
    [ChatMessage(User, content="hello")],
    stream=StreamHandler(on_content_delta=_ => ()),
  ) catch {
    error => {
      assert_true("\{error}".contains("DeepSeek client is closed"))
      return
    }
  }
  fail("expected closed client failure")
}

///|
async test "chat stream handler accumulates Kimi stream_options usage" {
  @async.with_task_group() <| group => {
    guard stream_test_server(group, kimi_usage=true) is Some(url) else {
      return
    }
    let client = @client.Client(
      api_key="test-key",
      model=Kimi(K27Code),
      api_url=url,
    )
    defer client.close()
    let response = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=_ => ()),
    )
    assert_eq(response.content, "Hello world")
    assert_eq(response.usage.prompt_tokens, 3)
    assert_eq(response.usage.completion_tokens, 5)
    assert_eq(response.usage.total_tokens, 8)
  }
}

///|
/// A 2xx connection that goes silent — headers sent, then neither an SSE event
/// nor a close — must not hang the client forever. The idle timeout trips;
/// because nothing was delivered the stall counts as pre-event, so the request
/// retries and the second connection serves the full stream. Without the idle
/// bound this `read_until` blocks indefinitely (the observed production hang).
async test "streaming chat retries an idle stall before any event" {
  @async.with_task_group() <| group => {
    guard bind_test_server(
        "local TCP bind unavailable; skipping idle-stall test",
      )
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
          conn.flush()
          if hits.val > 1 {
            conn.write(
              "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n",
            )
            conn.write("data: [DONE]\n\n")
          } else {
            // Hold the connection open but silent, well past the client's idle
            // timeout, without sending an event or closing it.
            @async.sleep(3_000)
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
      idle_timeout_ms=100,
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
/// Once an event has been delivered, an idle stall must surface as a failure
/// rather than retry — replaying the stream would hand the consumer duplicate
/// content. The server streams one delta, then goes silent forever; the idle
/// timeout trips but the delivered-event bail keeps the failure final, so there
/// is no second hit.
async test "streaming chat fails an idle stall after a delta without retrying" {
  @async.with_task_group() <| group => {
    guard bind_test_server(
        "local TCP bind unavailable; skipping idle-stall test",
      )
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
          conn.flush()
          // Never send [DONE]; hold the connection open and silent.
          @async.sleep(3_000)
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
      idle_timeout_ms=100,
    )
    let deltas : Array[String] = []
    let _ = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=delta => deltas.push(delta)),
    ) catch {
      error => {
        assert_true("\{error}".contains("idle"))
        assert_eq(deltas.join("|"), "partial")
        assert_eq(hits.val, 1)
        return
      }
    }
    fail("expected an idle-stall failure")
  }
}

///|
/// Regression (Codex review): a `data:` line received WITHOUT its blank-line
/// terminator, then an idle stall, is buffered-but-unflushed model output. The
/// idle path must flush it first — firing on_stream_event and delivering the
/// content — so the delivered-event bail keeps the failure final instead of
/// replaying a half-consumed completion. Exactly one hit; the delta is seen.
async test "streaming chat does not retry an idle stall after an unterminated data line" {
  @async.with_task_group() <| group => {
    guard bind_test_server(
        "local TCP bind unavailable; skipping idle-stall test",
      )
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
          // One data line, then a single newline — NO blank-line terminator —
          // then silence. The delta sits buffered in data_lines.
          conn.write(
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n",
          )
          conn.flush()
          @async.sleep(3_000)
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
      idle_timeout_ms=100,
    )
    let deltas : Array[String] = []
    let _ = client.chat(
      [ChatMessage(User, content="hello")],
      stream=StreamHandler(on_content_delta=delta => deltas.push(delta)),
    ) catch {
      error => {
        assert_true("\{error}".contains("idle"))
        assert_eq(deltas.join("|"), "partial")
        assert_eq(hits.val, 1)
        return
      }
    }
    fail("expected an idle-stall failure without retry")
  }
}

///|
async test "chat stream handler rejects EOF before done" {
  @async.with_task_group() <| group => {
    guard stream_test_server(group, finish=false) is Some(url) else { return }
    let client = @client.Client(api_key="test-key", api_url=url)
    try {
      let _ = client.chat(
        [ChatMessage(User, content="hello")],
        stream=StreamHandler(on_content_delta=_ => ()),
      )
      fail("expected truncated stream to fail")
    } catch {
      error => assert_true("\{error}".contains("ended before [DONE]"))
    }
  }
}
