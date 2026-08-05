# CodeMirror Reference Map

CodeMirror is a secondary reference. Use it when its smaller state/view split or
language package shape clarifies an implementation decision. Monaco remains the
main reference for viewer API shape and conformance.

The `codemirror/` gitlink is pinned at
`912443365be503d6898c3543955882e7516e4294`. Keep source citations and port
evidence tied to that revision.

CodeMirror was hydrated with:

```sh
cd codemirror
node bin/cm.js install
```

Useful packages for this project:

- `codemirror/state`: immutable state and text abstractions.
- `codemirror/view`: viewport, line rendering, DOM view model, decorations.
- `codemirror/language`: language state, syntax integration, highlighting.
- `codemirror/lint`: diagnostics and lint decorations.
- `codemirror/search`: search range handling.
- `codemirror/lsp-client`: optional protocol/client design reference.
- `codemirror/lang-javascript` and other `lang-*` packages: language package shape.

Use these as design references only. Do not import from them in product code.
