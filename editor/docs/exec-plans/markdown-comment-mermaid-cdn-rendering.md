# Markdown Comment Mermaid CDN Rendering

Status: active

## Goal

Render exact lowercase `mermaid` fenced code blocks in whole-line Markdown
comments through Mermaid's official browser ESM implementation. Load the pinned
module lazily from
`https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.esm.min.mjs`;
do not add an npm dependency, bundle Mermaid, or introduce a MoonBit Mermaid
renderer.

Existing Diago behavior remains package-owned and synchronous. Hover, agent
feedback, unlabelled code, differently cased fences, and other languages remain
unchanged.

## Ownership and Interface

- `internal/viewer/markdown` remains multi-target and FFI-free. The
  Markdown-comment caller emits a safe tokenized fallback inside a marked
  diagram wrapper for exact `mermaid` fences.
- `internal/viewer/browser/markdown` owns the CDN import, official API adapter,
  asynchronous DOM lifetime, and theme rerendering. Its internal options gain
  an optional Mermaid theme; absence disables all Mermaid work.
- The root Markdown-comment contribution supplies the initial Viewer theme and
  forwards later theme changes to each retained renderer. Public Viewer,
  provider, and service interfaces do not change.
- Successful asynchronous commits notify the existing size callback. ViewZone
  height remains owned exclusively by the generation- and zone-checked
  Markdown-comment measurement path.

## Runtime Contract

- Load the CDN module only when a marked Mermaid wrapper exists. Cache the
  in-flight module promise, clear it after rejection, serialize
  `initialize(theme) + render`, and allocate process-unique diagram ids.
- Use `startOnLoad=false`, `securityLevel=strict`, and
  `suppressErrorRendering=true`; protect theme configuration from source
  frontmatter. Map Viewer `light` to Mermaid `default` and every other Viewer
  theme to Mermaid `dark`.
- Keep the safe tokenized code visible until `render` succeeds. Commit only
  while the renderer, wrapper, and per-render epoch are current, then install
  the returned SVG and invoke `bindFunctions`. Loading, CSP, syntax, stale
  promise, and disposal failures leave the fallback or last successful SVG
  intact and never create an unhandled rejection.
- Hosts must permit jsDelivr module scripts and Mermaid's inline SVG styling.
  Dynamic `import()` has no SRI parameter; the exact CDN version is the v1
  reproducibility boundary. Offline and blocked-CDN behavior is graceful
  source fallback.

## Tests and Gates

- Browser-Markdown whitebox tests cover the opt-in boundary, exact language
  match, escaped source fallback, success/failure/retry, multiple ids,
  asynchronous freshness, target reuse, size notification, theme rerender, and
  idempotent disposal.
- Mounted Viewer tests cover same-key replacement, model swap/detach, disposal,
  and light/dark rerender without replacing the retained ViewZone target.
- The direct public-Viewer Playwright scenario intercepts the exact CDN URL
  with a deterministic ESM fixture. It proves SVG replacement, invalid-source
  fallback, multiple diagrams, late completion, theme changes, measured and
  offscreen geometry, and unchanged Diago behavior without depending on public
  network access. A separately gated live-CDN smoke is diagnostic, not a
  required CI gate.
- Product docs describe the CDN/CSP/fallback contract. Production and test
  builds retain the absolute CDN import and contain neither a bare `mermaid`
  import nor a Mermaid bundle/chunk/npm dependency.
- Run focused JS and browser tests throughout. Final validation is
  `MOON_WORK=off moon info --target all`, `MOON_WORK=off moon fmt`,
  `MOON_WORK=off just check`, `MOON_WORK=off just test`,
  `MOON_WORK=off just build`, `MOON_WORK=off just test-browser`, and
  `git diff --check`.

## Completion

Review generated interfaces for the expected internal browser-Markdown change
and no public Viewer change. Move lasting ownership/contracts into architecture,
package, and harness documentation; summarize the landed work in
`docs/exec-plans/HISTORY.md`; delete this detailed plan.
