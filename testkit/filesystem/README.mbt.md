# Testkit Filesystem

`bobzhang/openseek/testkit/filesystem` provides a small JSON-backed virtual
filesystem for tests, evals, and mock fixtures. It is intentionally not a
general filesystem abstraction: it is a compact way to declare text files,
materialize them under a temporary root, and compare the listed files against
disk.

The JSON convention is a flat object:

```json
{
  "src/lib.mbt": "pub fn answer() -> Int { 42 }\n",
  "README.md": "fixture\n"
}
```

Keys are slash-separated relative paths. Values are text contents. Directories
are implicit and created when the fixture is written to disk.

## API Shape

- `FileSystem(Json)`: compact fixture wrapper. Public operations validate before
  use.
- `FileSystem::from_json(json)`: validate a JSON fixture at construction time.
- `FileSystem::from_pairs(files)`: build and validate from `(path, content)`
  pairs, rejecting duplicate paths.
- `FileSystem::paths()`: return sorted fixture paths for stable tests.
- `FileSystem::get(path)`: return fixture content when present.
- `FileSystem::write_to(root)`: materialize the fixture under `root`.
- `FileSystem::mismatch_on_disk(root)`: return `""` if listed files match disk,
  otherwise a short failure reason.
- `write_text(root, path, content)`: validated helper for overwriting one text
  file under a fixture root.

## Examples

Use `FileSystem({...})` for concise fixtures:

```moonbit check
///|
test "declare a compact fixture" {
  let files = @filesystem.FileSystem({
    "src/lib.mbt": "pub fn answer() -> Int { 42 }\n",
    "README.md": "fixture\n",
  })
  assert_eq(files.paths().join("|"), "README.md|src/lib.mbt")
  assert_true(
    files.get("src/lib.mbt") is Some("pub fn answer() -> Int { 42 }\n"),
  )
}
```

Use `from_pairs` when you want invalid paths rejected immediately:

```moonbit check
///|
test "validate paths at construction time" {
  let _ = @filesystem.FileSystem::from_pairs([("../secret.txt", "nope")]) catch {
    error => {
      assert_true("\{error}".contains("must not contain `.` or `..`"))
      return
    }
  }
  fail("invalid path accepted")
}
```

Use `write_to` and `mismatch_on_disk` for native fixture tests:

```moonbit check
///|
async test "materialize and compare a fixture" {
  let root = @fs.tmpdir(prefix="openseek-testkit-readme")
  let files = @filesystem.FileSystem({
    "src/note.txt": "alpha\n",
    "docs/summary.txt": "ready\n",
  })
  files.write_to(root)
  assert_eq(files.mismatch_on_disk(root), "")

  @filesystem.write_text(root, "src/note.txt", "changed\n")
  assert_eq(files.mismatch_on_disk(root), "content mismatch in src/note.txt")
  @fs.rmdir(root, recursive=true)
}
```

## Design Notes

The flat JSON shape is deliberate. It keeps fixtures reviewable, avoids a
second tree DSL, and matches how tests and reports usually talk about files:
by path. The package only supports text files because the agent tools currently
operate on text. Extra files on disk are ignored by `mismatch_on_disk`; use
the fixture as an assertion for files that matter, and add an exact-tree helper
later if a test needs that stronger contract.
