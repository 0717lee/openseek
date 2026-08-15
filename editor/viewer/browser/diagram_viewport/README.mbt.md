# viewer/browser/diagram_viewport

Browser-only interaction for an already-rendered Markdown diagram SVG.

`DiagramViewports` borrows one DOM root and enhances every direct SVG inside a
`moonbit-viewer-markdown-diagram` wrapper marked as `diago`, `uml`, or
`mermaid`. It owns the pan, zoom, fit, resize controls and their browser
listeners until disposal; it does not parse Markdown or compile diagrams.

Callers must retain the opaque value, call `refresh` after diagram SVG nodes
may have been inserted or replaced, and call `dispose` before removing or
replacing the borrowed root. `dispose` restores the attributes, inline styles,
and direct SVG structure that the package borrowed.

The stylesheet beside this document is part of the package's presentation
contract and must be included by each browser host.
