// The browser shell: the console bundle openseek-api serves at `/`.
// The shared Web asset packager combines this entry with the same CSS, fonts,
// and terminal runtime used by Desktop. Console-only features can migrate here
// later without creating a second asset pipeline.

///|
fn main {
  @frontend.boot()
}
