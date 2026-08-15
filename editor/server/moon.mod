name = "moonbitlang/editor-server"

version = "0.1.0"

license = "Apache-2.0"

description = "Remote-workspace server host for the readonly MoonBit editor."

// The host serves files, spawns processes, and opens sockets, so native is
// its home backend. It also built and ran on wasm until moonbitlang/async
// 0.20.5, whose wasm backend declares a `thread_pool/make_open_stat_job`
// host import no moonrun provides — every wasm program linking `async/fs`
// then fails to instantiate. Restore `native+wasm` once async ships a fix.

supported_targets = "native"

preferred_target = "native"

warnings = "+prefer_readonly_array"

import {
  "moonbitlang/editor@0.4.4",
  "moonbitlang/async@0.20.4",
}
