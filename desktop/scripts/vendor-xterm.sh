#!/usr/bin/env bash
# Regenerate the vendored terminal emulator assets:
#   desktop/xterm.js   — @xterm/xterm + @xterm/addon-fit as one self-contained
#                        IIFE defining the `__openseek_xterm` global
#                        ({ Terminal, FitAddon, writeBase64 })
#   desktop/xterm.css  — @xterm/xterm's stylesheet, verbatim
#
# A self-contained bundle is mandatory: esm.sh-style builds import Node
# polyfills from site-absolute URLs ("/node/process.mjs"), which the
# proton:// asset scheme rejects, so upstream module builds fail to load
# inside the webview. Bundling from the npm tarball avoids that entirely.
#
# Usage: scripts/vendor-xterm.sh  (from the desktop/ directory; needs npx)
set -euo pipefail

XTERM_VERSION="5.5.0"
FIT_VERSION="0.10.0"

desktop_dir="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -sL "https://registry.npmjs.org/@xterm/xterm/-/xterm-${XTERM_VERSION}.tgz" -o "$work/xterm.tgz"
curl -sL "https://registry.npmjs.org/@xterm/addon-fit/-/addon-fit-${FIT_VERSION}.tgz" -o "$work/fit.tgz"
mkdir -p "$work/xterm" "$work/fit"
tar xzf "$work/xterm.tgz" -C "$work/xterm" --strip-components=1
tar xzf "$work/fit.tgz" -C "$work/fit" --strip-components=1

cat > "$work/entry.js" <<'EOF'
import { Terminal } from "./xterm/lib/xterm.js";
import { FitAddon } from "./fit/lib/addon-fit.js";

// Decode one base64 chunk of raw PTY bytes into the terminal; report the
// byte count through `done` once xterm has rendered it (the flow-control
// ack the OpenSeek frontend sends back to the host).
const writeBase64 = (term, b64, done) => {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  term.write(out, () => done(out.length));
};

globalThis.__openseek_xterm = { Terminal, FitAddon, writeBase64 };
EOF

npx -y esbuild "$work/entry.js" --bundle --format=iife --platform=browser \
  --minify --outfile="$desktop_dir/xterm.js"
cp "$work/xterm/css/xterm.css" "$desktop_dir/xterm.css"
echo "vendored xterm ${XTERM_VERSION} + addon-fit ${FIT_VERSION}"
