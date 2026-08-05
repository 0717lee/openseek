# Readonly MoonBit Viewer

The source checkout has two main parts. The reusable viewer is developed as a
module in the OpenSeek monorepo; the reference shell is repository-only:

- `viewer`: the reusable MoonBit readonly viewer. It is Monaco-shaped in API
  and behavior where that helps embedders, but it stays MoonBit-owned and does
  not import Monaco, VS Code, or CodeMirror code.
- `internal/shell`: the reference app/backend used to see the viewer working
  against a real workspace. It demonstrates one host composition and must use
  the viewer through public APIs; it is not an external import surface.

```d2
direction: down

embedder: your MoonBit app

repo: this repository {
  viewer: viewer — reusable workspace module {
    facade: Viewer facade
    common: viewer/common — DOM-free
    browser: browser runtime + contributions
  }
  shell: internal/shell — reference only {
    workbench: browser workbench
    server: host backend
  }
}

embedder -> repo.viewer.facade: imports moonbitlang/editor in the workspace
repo.shell.workbench -> repo.viewer.facade: embeds via public API
repo.shell.workbench <-> repo.shell.server: readonly remote protocol
```

Monaco/VS Code is the primary design reference. CodeMirror is a secondary
reference when its simpler state/view split is useful. Both submodules are
reference-only.

## Browser Runtime

Whole-line Markdown comments render exact lowercase `d2` and `diago` fences
synchronously with the bundled Diago compiler. Exact lowercase `mermaid`
fences use Mermaid's official browser implementation. The web build downloads
the pinned `mermaid@11.16.0` npm archive, verifies its SHA-256 digest, and
stages the minified ESM entry, relative chunks, and license under
`web/dist/mermaid/`. Mermaid remains a lazy runtime import, but it is loaded
from that same-origin directory rather than a public CDN.

Diago's generated inline SVG can contain active HTML and is not a sanitization
boundary. Embedders must trust every viewer Markdown source that can contain
`d2` or `diago` fences, including workspace comments, hover-provider results,
and agent-feedback bodies. Embedders that enable Mermaid rendering must stage
the generated `mermaid/` tree at the document resource base, allow same-origin
module scripts in their CSP, and permit the inline styles used inside Mermaid
SVG output. A clean build needs registry access once; the verified archive is
cached under `target/vendor-mermaid/cache/`, so later builds can reuse it
offline. If the local asset is missing or blocked, or if a diagram is invalid,
the viewer keeps the safe tokenized source code visible.

## Repository Development

In the OpenSeek monorepo this directory is a member of the root workspace, while
the local `moon.work` keeps the commands below scoped to the editor and its
server. From the repository root, the equivalent integration entry points are
`just editor-build`, `just editor-test`, and `just editor-test-browser`.

```sh
just
```

Open `http://127.0.0.1:5173/`. The dev server is the internal host/backend
shell: it serves `web/dist` and talks to the browser workbench over the readonly
remote protocol WebSocket.

`just` builds the browser assets and server, then runs the server module on its
default Wasm target and serves the current checkout. To opt into the native
target, run `just TARGET=native dev`. Use
`just ROOT=<workspace> PORT=<port> dev` to override the starting workspace or
port, or `just list` to show every recipe.

`ROOT` selects only the starting workspace. The workbench's **Open
Repository…** picker may switch the running server without a restart, with its
reach controlled separately by `BROWSE_ROOT` and the listener bind:

- on a loopback bind such as `HOST=127.0.0.1`, an empty `BROWSE_ROOT` permits
  browsing the host filesystem;
- on a non-loopback bind, including plain `just dev` with its `0.0.0.0`
  default, an empty `BROWSE_ROOT` disables repository browsing; and
- an explicit `BROWSE_ROOT=<directory>` permits only that realpathed directory
  and its descendants, on either kind of bind.

The reference server has no authentication and exposes the active workspace's
source files. Use non-loopback binds only on a trusted network, and grant the
smallest practical `BROWSE_ROOT` when repository switching is required.

The browser suites additionally require Node.js 18 or newer, the locked npm
dependencies, and a Playwright-managed Chromium installation:

```sh
npm ci
npx playwright install chromium
```

On Linux, use `npx playwright install --with-deps chromium` when Chromium's
system dependencies are not installed yet.

## Validation

```sh
moon check --target all --warn-list +73
moon fmt --check
just test
just build
just test-browser-smoke
```

Current architecture lives in [docs/architecture.md](docs/architecture.md).
Browser harness behavior lives in [docs/harness.md](docs/harness.md).
