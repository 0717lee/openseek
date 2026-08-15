///|
/// Open editor tabs that still name a usable file. A deleted tab remains a
/// bookmark in the editor strip, but neither Quick Open nor a composer mention
/// may offer it as a destination.
fn Model::live_editor_files(self : Model) -> Array[@pathx.Relative] {
  let paths : Array[@pathx.Relative] = []
  for path in @dock.file_paths(self.dock) {
    match self.file_panel.docs.get(path) {
      Some(doc) if doc.state is @fileeditor.TabDeleted => ()
      _ => paths.push(path)
    }
  }
  paths
}

///|
/// Build the bounded workspace-file candidate set supplied to `@composer`.
/// The shared index provides paths while open tabs remain immediately useful
/// during index refreshes.
fn Model::file_search(self : Model) -> @files.Search {
  let indexed = match self.file_panel.index {
    @fileeditor.IndexReady(files~, ..) => files
    _ => []
  }
  @files.Search(indexed, self.live_editor_files(), @dock.active_file(self.dock))
}
