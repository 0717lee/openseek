///| TextModel-owned tokenization state, size policy, and scheduler epochs.

///|
priv struct ModelTokenizationCountingTokenizer {
  calls : Ref[Int]
}

///|
impl @syntax.LineTokenizer for ModelTokenizationCountingTokenizer with fn initial_state(
  _self,
) {
  TokenizerState("model-tokenization")
}

///|
impl @syntax.LineTokenizer for ModelTokenizationCountingTokenizer with fn tokenize_line(
  self,
  _line_text,
  state,
) {
  self.calls.val += 1
  ([], state)
}

///|
fn tokenization_model(text : String, language_id : String) -> TextModel {
  TextModel(
    try! @base_common.Uri::from(
      scheme="inmemory",
      authority="tokenization-model",
      path="/model.mbt",
    ),
    "model.mbt",
    language_id,
    1,
    "",
    text,
  )
}

///|
fn tokenization_model_with_resolver(
  text : String,
  language_id : String,
  resolve_support : (String) -> InternalTokenizationSupportAdapter?,
) -> (TextModel, Array[String]) {
  let reported : Array[String] = []
  let model = new_text_model(
    try! @base_common.Uri::from(
      scheme="inmemory",
      authority="tokenization-model",
      path="/model.mbt",
    ),
    "model.mbt",
    language_id,
    1,
    "",
    text,
    Some(resolve_support),
    Some(message => reported.push(message)),
  )
  (model, reported)
}

///|
test "set_value updates shared token state and token_count stays passive" {
  let calls = Ref(0)
  let language_id = "text-model-live-token-state"
  let registration = @syntax.tokenization_registry.register(language_id, ModelTokenizationCountingTokenizer::{
    calls,
  })
  let model = tokenization_model("old\nvalue", language_id)
  assert_eq(model.tokenization_state.snapshot.val.get_value(), "old\nvalue")
  assert_eq(model.tokenization.token_count(), 2)
  assert_eq(calls.val, 0)

  model.set_value(
    (
      #|new
      #|value
      #|now
    ),
  )
  assert_eq(
    model.tokenization_state.snapshot.val.get_value(),
    (
      #|new
      #|value
      #|now
    ),
  )
  assert_eq(model.tokenization_state.snapshot.val.line_count(), 3)
  assert_eq(model.tokenization.get_line_tokens(3).get_line_content(), "now")
  assert_eq(model.tokenization.token_count(), 3)
  assert_eq(calls.val, 0)

  let view = model.on_before_attached()
  view.set_visible_lines([{ start_line_number: 1, end_line_number: 2 }], true)
  assert_eq(calls.val, 2)
  let before_count = calls.val
  assert_eq(model.tokenization.token_count(), 3)
  assert_eq(calls.val, before_count)
  model.on_before_detached(view)
  model.dispose()
  registration.dispose()
}

///|
test "model listener ownership includes token-part listeners through disposal" {
  let model = tokenization_model("one", "text-model-token-listeners")
  assert_false(model.has_listeners())
  let first = model.on_did_change_tokens(_ => ())
  assert_true(model.has_listeners())
  first.dispose()
  assert_false(model.has_listeners())

  let live_at_disposal = model.on_did_change_tokens(_ => ())
  assert_true(model.has_listeners())
  model.dispose()
  assert_false(model.has_listeners())
  live_at_disposal.dispose()
  let after_disposal = model.on_did_change_tokens(_ => ())
  assert_false(model.has_listeners())
  after_disposal.dispose()
  assert_false(model.has_listeners())
}

///|
test "TextModel disposal marks disposed between token part and registered resources" {
  let trace : Array[String] = []
  let is_disposing = Ref(false)
  let tokenization_disposed = Ref(false)
  let is_disposed = Ref(false)

  run_text_model_dispose_sequence(
    set_disposing=value => {
      trace.push(
        "disposing=\{value}:\{is_disposing.val}:\{tokenization_disposed.val}:\{is_disposed.val}",
      )
      is_disposing.val = value
    },
    fire_will_dispose=() => {
      trace.push(
        "willDispose:\{is_disposing.val}:\{tokenization_disposed.val}:\{is_disposed.val}",
      )
    },
    dispose_tokenization=() => {
      trace.push(
        "tokenization.dispose:\{is_disposing.val}:\{tokenization_disposed.val}:\{is_disposed.val}",
      )
      tokenization_disposed.val = true
    },
    set_disposed=() => {
      trace.push(
        "isDisposed=true:\{is_disposing.val}:\{tokenization_disposed.val}:\{is_disposed.val}",
      )
      is_disposed.val = true
    },
    dispose_registered_resources=() => {
      trace.push(
        "super.dispose:\{is_disposing.val}:\{tokenization_disposed.val}:\{is_disposed.val}",
      )
    },
  )

  assert_eq(
    trace.join(","),
    "disposing=true:false:false:false,willDispose:true:false:false,tokenization.dispose:true:false:false,isDisposed=true:true:true:false,super.dispose:true:true:true,disposing=false:true:true:true",
  )
  assert_false(is_disposing.val)
}

///|
priv suberror ModelProductionTokenizationError {
  InitialStateFailure
}

///|
test "TextModel reports a failing tokenizer and remains live for later reset" {
  let attempts = Ref(0)
  let tokenizer_calls = Ref(0)
  let (model, reported) = tokenization_model_with_resolver(
    "one\ntwo",
    "text-model-production-error-reporter",
    _ => {
      Some(
        InternalTokenizationSupportAdapter(
          initial_state=() => {
            attempts.val += 1
            if attempts.val == 1 {
              raise ModelProductionTokenizationError::InitialStateFailure
            }
            TokenizerState("healthy")
          },
          tokenize_encoded=(text, _has_eol, _state) => {
            tokenizer_calls.val += 1
            {
              tokens: [0, tag_to_metadata(Plain)],
              end_state: TokenizerState(text),
            }
          },
        ),
      )
    },
  )
  assert_eq(reported.length(), 1)
  assert_true(reported[0].contains("InitialStateFailure"))
  assert_eq(model.get_value(), "one\ntwo")
  assert_eq(tokenizer_calls.val, 0)

  // A later production flush reacquires support after the reported failure;
  // an attached visible range can then tokenize normally.
  model.set_value("still\nlive")
  let view = model.on_before_attached()
  view.set_visible_lines([{ start_line_number: 1, end_line_number: 2 }], true)
  // One successful reset probes support and then seeds the state store, so
  // the initial-state callback runs twice after the first reported failure.
  assert_eq(attempts.val, 3)
  assert_eq(tokenizer_calls.val, 2)
  assert_eq(model.get_value(), "still\nlive")
  model.on_before_detached(view)
  model.dispose()
}
