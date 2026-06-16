///|
fn cli_command() -> @argparse.Command {
  Command(
    "md_to_mbt_string",
    about="Generate a MoonBit string source file from Markdown.",
    positionals=[
      PositionArg(
        "input",
        num_args=@argparse.ValueRange::single(),
        about="Input Markdown path.",
      ),
      PositionArg(
        "output",
        num_args=@argparse.ValueRange::single(),
        about="Output MoonBit source path.",
      ),
    ],
  )
}

///|
async fn main {
  guard cli_command().parse().values is { "input": [input, ..], "output": [output, ..], .. } else {
    fail("missing parsed arguments")
  }
  let base = input_basename(input)
  let function_name = function_name_from_base(base)
  let markdown = @fs.read_file(input).text()
  let source = generated_source(base~, function_name~, markdown~)
  if output_matches(output, source) {
    return
  }
  let tmp = "\{output}.tmp"
  @fs.write_file(tmp, source, create_mode=CreateOrTruncate)
  @fs.rename(tmp, output, replace=true)
}

///|
async fn output_matches(output : StringView, source : StringView) -> Bool {
  let current = @fs.read_file(output).text() catch { _ => return false }
  current[:] == source
}

///|
fn input_basename(input : StringView) -> StringView {
  let unix_parts = input.split("/").collect()
  let after_unix = unix_parts[unix_parts.length() - 1]
  let windows_parts = after_unix.split("\\").collect()
  windows_parts[windows_parts.length() - 1]
}

///|
fn function_name_from_base(base : StringView) -> StringView raise {
  match base {
    ([.. stem, .. ".mbt.md"] | [.. stem, .. ".md"]) if stem =~ re"^[a-z_][A-Za-z0-9_]*$" =>
      stem
    _ =>
      fail(
        "md_to_mbt_string: input must end in .md or .mbt.md with a MoonBit function name basename: \{base}",
      )
  }
}

///|
fn generated_source(
  base~ : StringView,
  function_name~ : StringView,
  markdown~ : StringView,
) -> String {
  let lines = markdown.split("\n")
  (
    $|// Generated from \{base} by moon dev_build. DO NOT EDIT.
    $|///|
    $|fn \{function_name}() -> String {
    $|  (
    $|\{out => for line in lines { out <+ "    #|\{line}\n" }}  )
    $|}
    $|
  )
}
