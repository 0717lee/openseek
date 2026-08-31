import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const script = fileURLToPath(new URL("./native_link_config.mjs", import.meta.url));

function linkFlags(env) {
  const result = spawnSync(process.execPath, [script], {
    encoding: "utf8",
    input: JSON.stringify({ env }),
  });
  assert.equal(result.status, 0, result.stderr);
  const config = JSON.parse(result.stdout);
  assert.equal(config.link_configs.length, 1);
  return config.link_configs[0].link_flags;
}

test("MSVC flags are passed directly to link.exe", () => {
  assert.equal(
    linkFlags({
      OS: "Windows_NT",
      OPENSEEK_DESKTOP_LINK_STYLE: "msvc",
    }),
    "/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup",
  );
});

test("an installed MSVC environment wins over generic CC", () => {
  assert.equal(
    linkFlags({
      OS: "Windows_NT",
      VCINSTALLDIR: "C:\\Visual Studio\\VC",
      CC: "clang",
    }),
    "/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup",
  );
});
