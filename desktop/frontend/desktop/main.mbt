// The Desktop shell: the shared Web asset packager combines this entry with
// the same CSS, fonts, and terminal runtime used by Browser, then writes the
// content-hashed distribution loaded by the proton webview. Desktop-only
// features can migrate here later without creating a second asset pipeline.

///|
fn main {
  @frontend.boot()
}
