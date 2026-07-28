# internal/viewer/contrib/hover/browser

The JS-only content-hover browser implementation. It owns mouse-target event
reduction, anchor discovery, the concrete hover controller, DOM rendering and
geometry, and the persistent scrollable content widget. The root Viewer owns
the controller lifetime, timers, provider execution, decorations, and widget
mounting.

DOM-free hover state, participants, reconciliation, and fenced-code
tokenization live in `internal/viewer/contrib/hover`. The widget builds the
Monaco-shaped row/wrapper DOM and renders Markdown through
`internal/viewer/browser/markdown` into retained `.hover-contents` targets. It
owns every returned render disposable and clears those lifetimes on content
replacement, hide, and retained-widget teardown. Browser view and scrollbar
dependencies are internal packages under `internal/viewer/**`. The emitted
stylesheet remains at `viewer/contrib/hover/hover.css`.

Marker-copy event routing and listener lifetime also stay in MoonBit: each
render registers its copy-button listener in that render's disposable set.
JavaScript is limited to the browser clipboard write and its test-observation
hook.

Exact callable types are in `pkg.generated.mbti`. Run focused tests with:

```sh
moon test internal/viewer/contrib/hover/browser --target js
```
