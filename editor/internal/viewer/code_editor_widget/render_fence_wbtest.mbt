///|
test "after-next-render is one-shot generation fenced and cancellable" {
  let viewer = CodeEditorWidget()
  let calls : Array[String] = []
  viewer.after_next_render(() => {
    calls.push("first")
    viewer.after_next_render(() => calls.push("second")) |> ignore
  })
  |> ignore
  let cancelled = viewer.after_next_render(() => calls.push("cancelled"))
  cancelled.dispose()

  viewer.flush_render()
  assert_true(calls == ["first"])
  viewer.flush_render()
  assert_true(calls == ["first", "second"])
  viewer.flush_render()
  assert_true(calls == ["first", "second"])
  viewer.dispose()
}
