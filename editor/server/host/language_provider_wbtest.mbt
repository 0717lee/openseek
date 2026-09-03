///|
priv struct RecordedMoonCommand {
  command : String
  root : String
  args : Array[String]
}

///|
async test "moon location providers route exact commands through the configured runner" {
  let calls : Array[RecordedMoonCommand] = []
  let definition_output =
    #|[{"path":"src/target.mbt","range":"3:2-3:8"}]
  let references_output =
    #|[{"path":"src/target.mbt","range":"3:2-3:8"},{"path":"src/main.mbt","range":"2:5-2:11"}]
  let provider = new_moon_workspace_language_provider_with_runner(
    Ref("/workspace/demo"),
    "/tools/moon",
    (command, root, args) => {
      calls.push({ command, root, args, })
      if args.length() > 1 && args[1] == "peek-def" {
        Some((0, definition_output))
      } else if args.length() > 1 && args[1] == "find-references" {
        Some((0, references_output))
      } else {
        None
      }
    },
  )
  let uri = match @server.remote_document_uri("src/main.mbt") {
    Some(uri) => uri
    None => fail("expected remote document uri")
  }
  let model = @model.TextModel(
    uri, "src/main.mbt", "moonbit", 1, "rev-1", "fn main {}\n",
  )
  defer model.dispose()
  let token = @language.CancellationToken::none()
  let definitions = provider.provide_definition(model, Position(2, 5), token)
  let references = provider.provide_references(model, Position(2, 5), token)

  assert_eq(calls.length(), 2)
  for call in calls {
    assert_eq(call.command, "/tools/moon")
    assert_eq(call.root, "/workspace/demo")
  }
  assert_eq(calls[0].args, [
    "ide", "peek-def", "--loc", "src/main.mbt:2:5", "--json",
  ])
  assert_eq(calls[1].args, [
    "ide", "find-references", "--loc", "src/main.mbt:2:5", "--json",
  ])

  assert_eq(definitions.length(), 1)
  assert_eq(
    definitions[0].uri.to_string(),
    "readonly-remote://workspace/src/target.mbt",
  )
  assert_true(definitions[0].range == Range(3, 2, 3, 8))
  assert_eq(references.length(), 2)
  assert_eq(
    references[1].uri.to_string(),
    "readonly-remote://workspace/src/main.mbt",
  )
  assert_true(references[1].range == Range(2, 5, 2, 11))
}
