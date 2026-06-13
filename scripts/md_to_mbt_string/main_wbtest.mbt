///|
test "function name from markdown basename" {
  assert_eq(function_name_from_base("base_prompt.md"), "base_prompt")
  assert_eq(function_name_from_base("flash_prompt.mbt.md"), "flash_prompt")
}

///|
test "function name rejects unsupported extension" {
  try {
    ignore(function_name_from_base("base_prompt.txt"))
    fail("expected unsupported extension to fail")
  } catch {
    _ => ()
  }
}

///|
test "function name rejects invalid MoonBit identifier" {
  try {
    ignore(function_name_from_base("Base-Prompt.md"))
    fail("expected invalid function name to fail")
  } catch {
    _ => ()
  }
}

///|
test "cli rejects unknown option-looking input path" {
  let _ = cli_command().parse(argv=["--xxy", "out.mbt"]) catch {
    error => {
      assert_true("\{error}".contains("unexpected argument '--xxy' found"))
      return
    }
  }
  fail("unknown option accepted as input path")
}

///|
test "cli accepts hyphen-leading paths after option delimiter" {
  let parsed = cli_command().parse(argv=["--", "-input.md", "-output.mbt"])
  guard parsed.values is { "input": ["-input.md", ..], "output": ["-output.mbt", ..], .. } else {
    fail("expected delimiter to allow hyphen-leading paths")
  }
}

///|
test "generated source matches dev_build output shape" {
  let source = generated_source(
    base="base_prompt.md",
    function_name="base_prompt",
    markdown="# Title\n\nbody\n",
  )
  let expected =
    #|// Generated from base_prompt.md by moon dev_build. DO NOT EDIT.
    #|///|
    #|fn base_prompt() -> String {
    #|  (
    #|    #|# Title
    #|    #|
    #|    #|body
    #|    #|
    #|  )
    #|}
    #|
  assert_eq(source, expected)
}

///|
test "generated source preserves missing final newline" {
  let source = generated_source(
    base="flash_prompt.md",
    function_name="flash_prompt",
    markdown="one\ntwo",
  )
  let expected =
    #|// Generated from flash_prompt.md by moon dev_build. DO NOT EDIT.
    #|///|
    #|fn flash_prompt() -> String {
    #|  (
    #|    #|one
    #|    #|two
    #|  )
    #|}
    #|
  assert_eq(source, expected)
}

///|
async test "output match detects unchanged generated file" {
  let path = "/tmp/openseek-md-to-mbt-output-match.mbt"
  let _ = @fs.remove(path) catch { _ => () }
  assert_false(output_matches(path, "same"))
  @fs.write_file(path, "same", create_mode=CreateOrTruncate)
  assert_true(output_matches(path, "same"))
  assert_false(output_matches(path, "different"))
  let _ = @fs.remove(path) catch { _ => () }
}
