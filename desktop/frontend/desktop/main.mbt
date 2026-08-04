// The desktop shell: the bundle the host serves to its own window as
// `frontend.js` (packaging copies `desktop.js` into the asset dir). It
// shares everything with the browser shell today; desktop-only features
// will migrate here as the core splits.

///|
fn main {
  @frontend.boot(desktop=true)
}
