///|
fn test_model() -> @model.TextModel {
  TextModel(
    try! @base_common.Uri::from(
      scheme="inmemory",
      authority="model",
      path="/language-test.mbt",
    ),
    "language-test.mbt",
    "moonbit",
    7,
    "rev-7",
    (
      #|fn main {
      #|  value
      #|}
      #|
    ),
  )
}

///|
async test "language handle prebinds logging and forwards the exact capability" {
  let memory = @log.MemoryLogger()
  let languages = Languages()
  languages.set_language_configuration("moonbit", {
    comments: None,
    folding_rules: Some({ off_side: true, markers: None, }),
  })
  languages.register_hover_provider(LanguageId("moonbit"), TestHoverProvider::{
  })
  |> ignore
  languages.register_hover_provider(LanguageId("moonbit"), FailingHoverProvider::{
  })
  |> ignore
  let handle = languages.language_handle(
    @log.LogService(logger=memory).log_handle(),
  )
  assert_true(
    handle.get_language_configuration("moonbit").folding_rules
    is Some({ off_side: true, markers: None, }),
  )
  assert_hover_text(handle.hover_at(test_model(), 3), "provider hover")
  let entries = memory.entries()
  assert_eq(entries.length(), 1)
  assert_true(entries[0].category == "language.hover")
}

///|
test "token providers dispose only the active registration" {
  let languages = Languages()
  let first = languages.set_tokens_provider(
    "toy-dispose",
    @plain_tokenizer.PlainTokenizer(),
  )
  let second = languages.set_tokens_provider(
    "toy-dispose",
    @plain_tokenizer.PlainTokenizer(),
  )
  first.dispose()
  assert_true(@syntax.tokenization_registry.get("toy-dispose") is Some(_))
  second.dispose()
  assert_true(@syntax.tokenization_registry.get("toy-dispose") is None)
}

///|
priv struct TestHoverProvider {}

///|
impl @language.HoverProvider for TestHoverProvider with fn provide_hover(
  _self,
  model,
  position,
  _token,
) {
  let offset = model.get_offset_at(position)
  Some({
    range: model.snapshot.range_of(OffsetRange(offset, offset + 1)),
    contents: [PlainText("provider hover")],
  })
}

///|
fn assert_hover_text(hover : @language.Hover?, expected : String) -> Unit raise {
  match hover {
    Some(hover) =>
      match hover.contents[0] {
        PlainText(text) => assert_eq(text, expected)
        Markdown(_) => fail("expected plaintext hover")
      }
    None => fail("expected hover")
  }
}

///|
priv suberror TestProviderError {
  TestProviderError
}

///|
priv struct FailingHoverProvider {}

///|
impl @language.HoverProvider for FailingHoverProvider with fn provide_hover(
  _self,
  _model,
  _position,
  _token,
) {
  raise TestProviderError
}
