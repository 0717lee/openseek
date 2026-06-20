///|
/// Snapshot the outline for a small tree: directories are listed depth-first and
/// sorted (one nested level shown), while the README file, the hidden `.git`,
/// the vendored `node_modules`, and build output are omitted.
async test "outline lists directories, omitting files and noise" {
  @vfs.with_tmpdir(dir => {
    @fs.mkdir("\{dir}/src", recursive=true)
    @fs.mkdir("\{dir}/lib/internal", recursive=true)
    @fs.mkdir("\{dir}/node_modules/pkg", recursive=true)
    @fs.mkdir("\{dir}/_build/x", recursive=true)
    @fs.mkdir("\{dir}/.git/objects", recursive=true)
    @fs.write_file("\{dir}/README.md", "x", create_mode=CreateOrTruncate)
    inspect(
      @layout.outline(dir),
      content=(
        #|
        #|
        #|Project layout (directories; hidden, build, and vendored dirs omitted):
        #|lib/
        #|  internal/
        #|src/
      ),
    )
  })
}

///|
async test "outline is empty for an empty directory" {
  @vfs.with_tmpdir(dir => inspect(@layout.outline(dir), content=""))
}
