///|
const TerminalEntrySource : String =
  #|import { Terminal } from "./xterm/lib/xterm.js";
  #|import { FitAddon } from "./fit/lib/addon-fit.js";
  #|
  #|// Decode one base64 chunk of raw PTY bytes into the terminal; report the
  #|// byte count through `done` once xterm has rendered it (the flow-control
  #|// acknowledgement the OpenSeek frontend sends back).
  #|const writeBase64 = (term, b64, done) => {
  #|  const bin = atob(b64);
  #|  const out = new Uint8Array(bin.length);
  #|  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  #|  term.write(out, () => done(out.length));
  #|};
  #|
  #|globalThis.__openseek_xterm = { Terminal, FitAddon, writeBase64 };
  #|

///|
priv struct TerminalAssets {
  javascript : String
  stylesheet : String
}

///|
/// Bundle the verified xterm sources into the global consumed by the MoonBit
/// frontend. The final Web build performs minification and content hashing.
async fn AssetBuilder::build_terminal(self : AssetBuilder) -> TerminalAssets {
  @packaging.write_text(self.at("work/terminal-entry.js"), TerminalEntrySource)
  @packaging.remove_path_if_exists(self.at("terminal"))
  @packaging.ensure_dir(self.at("terminal"))
  let javascript = self.at("terminal/xterm.js")
  let stylesheet = self.at("terminal/xterm.css")
  @packaging.run_checked(
    self.esbuild_binary(),
    [
      self.at("work/terminal-entry.js"),
      "--bundle",
      "--format=iife",
      "--platform=browser",
      "--target=es2020",
      "--outfile=\{javascript}",
    ],
    dir=self.workspace.dir(),
  )
  @packaging.copy_file(self.at("work/xterm/css/xterm.css"), stylesheet)
  { javascript, stylesheet }
}
