# Desktop Package Main Packages

## Goal

Move the three desktop packaging scripts out of standalone `.mbtx` files and
into regular MoonBit main packages, while extracting the common build and file
operation logic shared by the Windows, macOS, and Linux packaging flows.

## Accepted Design

- Replace the standalone `desktop/package_linux.mbtx`,
  `desktop/package_macos.mbtx`, and `desktop/package_windows.mbtx` entry points
  with three `is-main` packages under `desktop/cmd/package_linux`,
  `desktop/cmd/package_macos`, and `desktop/cmd/package_windows`.
- Add `desktop/internal/packaging` as the shared helper package for workspace
  discovery, command execution, frontend/native/engine build steps, Lepus
  codegen staging, and simple file/directory operations.
- Keep platform-specific packaging behavior in each platform main package:
  AppImage metadata and appimagetool on Linux, signing/notarization on macOS,
  and WebView2/WSL/MoonBit toolchain/NSIS handling on Windows.
- Preserve current distribution behavior. In particular, only the Windows
  package stages the bundled MoonBit toolchain; Linux and macOS continue to
  package only the host, engine, and frontend assets.
- Keep the runtime bundled-toolchain lookup unchanged in this refactor.

## Target Files And Surfaces

- `desktop/internal/packaging/`: new internal shared package.
- `desktop/cmd/package_linux/`: new Linux packaging main package.
- `desktop/cmd/package_macos/`: new macOS packaging main package.
- `desktop/cmd/package_windows/`: new Windows packaging main package.
- `desktop/package_linux.mbtx`, `desktop/package_macos.mbtx`,
  `desktop/package_windows.mbtx`: removed or replaced by the new main package
  entry points.
- `.github/workflows/ci.yml`: update packaging commands to `moon run` the new
  main packages.
- `desktop/README.md`: update user-facing packaging commands.

## API And Interface Diff

- New internal package API:
  `openseek_desktop/internal/packaging`.
- New executable package entry points:
  `openseek_desktop/cmd/package_linux`,
  `openseek_desktop/cmd/package_macos`, and
  `openseek_desktop/cmd/package_windows`.
- Existing desktop host/runtime APIs should remain unchanged.
- Generated interfaces should only grow for the new internal packaging package
  and new main packages; existing package interfaces should not expose new
  public runtime behavior.

## Open Questions

- None for the structural refactor. Cross-platform bundled MoonBit toolchain
  support was intentionally out of scope for the first package split, and is
  now tracked in the follow-up checkpoint below.

## Next Implementation Step

Create `desktop/internal/packaging`, move shared helpers into it, then add the
three platform-specific main package directories and update references from the
old `.mbtx` entry points.

## Validation Plan

- Run `moon -C desktop check --target native`.
- Run `moon -C desktop test`.
- Run `moon -C desktop info && moon -C desktop fmt`.
- Review generated `.mbti` diffs and confirm existing runtime interfaces did
  not change unexpectedly.
- Do not run full packaging commands unless explicitly requested, because they
  may download external artifacts and require platform-specific tools.

## Follow-up: Cross-platform Bundled MoonBit Toolchain

### Goal

Distribute a bundled MoonBit toolchain on Windows, Linux, and macOS while
keeping signed/read-only application bundles immutable at runtime.

### Accepted Design

- Move the Windows-only MoonBit toolchain download and staging logic from
  `desktop/cmd/package_windows` into shared helpers in
  `desktop/internal/packaging`.
- Treat the packaged toolchain as a read-only seed. Package commands download
  and extract the platform-specific MoonBit binary archive plus matching core
  archive, but do not run `moon bundle` inside the packaged app directory.
- At runtime, copy the bundled seed into the per-user runtime directory and run
  `moon bundle --all` plus `moon bundle --target wasm-gc` only in that writable
  copy. The runtime then passes that writable directory as `MOON_HOME` to the
  engine.
- Keep platform differences in small descriptors: archive format, CDN target
  name, bundled seed relative path, executable suffix, and PATH separator.
- Preserve `OPENSEEK_DISABLE_BUNDLED_MOON` and `OPENSEEK_MOON_HOME` override
  behavior.

### Target Files And Surfaces

- `desktop/internal/packaging`: shared package-time toolchain descriptors,
  download, extraction, version validation, and staging helpers.
- `desktop/cmd/package_windows`, `desktop/cmd/package_linux`, and
  `desktop/cmd/package_macos`: call shared toolchain staging with their
  platform descriptor.
- `desktop/internal/appdirs`: bundled seed lookup, writable toolchain location,
  executable names, and PATH separator helpers.
- `desktop/internal/host`: initialize the writable copy from the bundled seed
  and run `moon bundle` there.
- `desktop/README.md`: document that all platform packages ship a MoonBit
  toolchain seed and initialize it under the per-user runtime directory.

### API And Interface Diff

- `openseek_desktop/internal/packaging` gains public internal-package helpers
  for MoonBit toolchain platform descriptors and staging.
- `openseek_desktop/internal/appdirs` gains internal-package helpers for
  bundled seed lookup and per-user writable toolchain paths.
- Existing external desktop host behavior remains unchanged except that Linux
  and macOS packages can now use the bundled MoonBit toolchain like Windows.

### Open Questions

- None for this implementation. The current macOS package remains arm64 and the
  current Linux package remains x86_64.

### Next Implementation Step

Add shared packaging helpers, update the three package commands, then switch
runtime initialization from bundle-in-place to seed-copy-then-initialize in the
per-user runtime directory.

### Validation Plan

- Run `moon -C desktop check --target native`.
- Run `moon -C desktop info`.
- Run `moon -C desktop fmt`.
- Review `.mbti` diffs for expected internal package API growth.
- Do not run full packaging commands unless explicitly requested, because they
  download large toolchain archives and require platform-specific tools.

## Follow-up: Dedicated Desktop Package Tree

### Goal

Move desktop packaging code out of the desktop app/runtime package tree and
into a dedicated `desktop/package` package subtree, while extracting Windows PE
header patching into its own internal helper package.

### Accepted Design

- Keep everything inside the existing `openseek_desktop` MoonBit module; do not
  add a nested `desktop/package/moon.mod`.
- Move shared packaging helpers from `desktop/internal/packaging` to
  `desktop/package/internal/packaging`.
- Move MoonBit toolchain staging helpers from the shared packaging package to
  `desktop/package/internal/moonbit`.
- Add `desktop/package/internal/pe` for PE header constants and Windows GUI
  subsystem patching.
- Move platform main packages from `desktop/cmd/package_linux`,
  `desktop/cmd/package_macos`, and `desktop/cmd/package_windows` to
  `desktop/package/linux`, `desktop/package/macos`, and
  `desktop/package/windows`.
- Update README and CI commands to run `package/linux`, `package/macos`, and
  `package/windows`.

### Target Files And Surfaces

- `desktop/package/internal/packaging`: workspace discovery, package-time
  command execution, frontend/native/engine build helpers, and common file
  operations.
- `desktop/package/internal/moonbit`: package-time MoonBit toolchain target
  descriptors, archive download/extraction, validation, and seed staging.
- `desktop/package/internal/pe`: Windows PE subsystem patching.
- `desktop/package/linux`, `desktop/package/macos`, and
  `desktop/package/windows`: platform-specific `is-main` packaging entry
  points.
- `.github/workflows/ci.yml` and `desktop/README.md`: packaging command paths.

### API And Interface Diff

- Remove internal package APIs at `openseek_desktop/internal/packaging`.
- Add internal package APIs at:
  - `openseek_desktop/package/internal/packaging`
  - `openseek_desktop/package/internal/moonbit`
  - `openseek_desktop/package/internal/pe`
- Replace executable package paths:
  - `openseek_desktop/cmd/package_linux` ->
    `openseek_desktop/package/linux`
  - `openseek_desktop/cmd/package_macos` ->
    `openseek_desktop/package/macos`
  - `openseek_desktop/cmd/package_windows` ->
    `openseek_desktop/package/windows`
- Existing desktop app/runtime APIs remain unchanged.

### Open Questions

- None. The PE helper should expose only the cohesive operation needed by the
  Windows packager; PE offsets and binary-format constants should stay private.

### Next Implementation Step

Move packages into the new tree, extract `package/internal/moonbit` and
`package/internal/pe`, update package imports and command references, then
validate generated interfaces.

### Validation Plan

- Run `moon -C desktop check --target native`.
- Run `moon -C desktop info`.
- Run `moon -C desktop fmt`.
- Run `git diff --check`.
- Review `.mbti` diffs for expected package path changes and no desktop
  runtime API changes.
- Do not run full packaging commands unless explicitly requested, because they
  download external artifacts and require platform-specific tools.

## Follow-up: macOS CEF Helper Bundle

### Goal

Make the macOS `libcef` bundle launch CEF subprocesses from a canonical nested
helper app and keep Proton's native binaries compatible with the package's
declared minimum macOS version.

### Accepted Design

- Keep the full Proton runtime under `Contents/Resources/proton`, preserving its
  existing internal framework/resource layout and the host rpath pointing at
  `Resources/proton/lib`.
- Add a nested helper app at
  `Contents/Frameworks/OpenSeek Desktop Helper.app` containing a copy of
  `cef_process` at `Contents/MacOS/cef_process`.
- Give the helper app its own `Info.plist`, with bundle identifier derived from
  the main bundle id as
  `community.moonbit.proton.openseek-desktop.helper`.
- Repoint the helper executable's rpath to
  `@loader_path/../../../../Resources/proton/lib`, so its `@rpath/libproton.dylib`
  resolves to the bundled runtime.
- Sign the helper executable inside-out before the main app. For ad-hoc builds,
  keep the CEF helper signing identifier as `cef_process`; for distribution
  builds, use the same identifier plus hardened runtime and timestamp.
- Pass `MACOSX_DEPLOYMENT_TARGET=12.0` to Proton runtime assembly as well as to
  the host and engine builds, so Proton artifacts built during setup inherit the
  package's deployment target.

### Target Files And Surfaces

- `desktop/package/macos/main.mbt`: package-time helper app layout, Info.plist,
  rpath patching, and signing orchestration.
- `desktop/package/macos/main_wbtest.mbt`: focused tests for derived helper
  paths/metadata if the implementation introduces testable pure helpers.
- No desktop runtime or Proton public API changes are expected.

### API And Interface Diff

- `openseek_desktop/package/macos` should not expose new public APIs in
  `pkg.generated.mbti`; new helpers should remain private to the package.
- Runtime-facing interfaces in `desktop/proton` and desktop host packages should
  remain unchanged.

### Open Questions

- Chromium 147's peer requirement validation is intentionally out of scope for
  this step. If ad-hoc builds still show a blank page after the helper app is
  present, resolve that separately through real Developer ID signing or a
  browser-side CEF command-line feature override in `libproton`.
- The current vendored/prebuilt `libproton.dylib` and `cef_process` still carry
  `LC_BUILD_VERSION` `minos 26.0` even when `MACOSX_DEPLOYMENT_TARGET=12.0` is
  forwarded into `cef setup`. Supporting macOS versions below 26 requires a
  rebuilt or replaced Proton runtime, or a separate approved Mach-O rewriting
  and signing plan.

### Next Implementation Step

Update the macOS packager to stage and sign the helper app, propagate the
deployment target into Proton runtime assembly, then validate the generated
bundle structure and Mach-O metadata.

### Validation Plan

- Run `moon -C desktop check --target native`.
- Run `moon -C desktop test package/macos`.
- Run `moon -C desktop info && moon -C desktop fmt`.
- Build the macOS bundle with `moon -C desktop run --target native package/macos`.
- Inspect the generated bundle's `Contents/Frameworks` tree, helper executable
  rpath, `LC_BUILD_VERSION`, and code signature verification.

## Follow-up: Clean Build Host Binary Path

### Goal

Make the packaging helpers consume the native host binary path produced by a
clean current MoonBit release build.

### Accepted Design

- Keep the native host package as `.` and keep the existing package command
  flow unchanged.
- Update the shared packaging helper's native host artifact path from the stale
  flat output path to the clean-build nested output path:
  `_build/native/release/build/openseek_desktop/openseek_desktop.exe`.
- Do not change runtime APIs, package public APIs, or platform-specific bundle
  layouts.

### Target Files And Surfaces

- `desktop/package/internal/packaging/packaging.mbt`: native host artifact path
  constant only.

### API And Interface Diff

- No intended `.mbti` or public API changes.

### Open Questions

- None. `moon -C desktop clean` followed by the macOS package command showed
  the clean build emits only the nested native host binary path.

### Next Implementation Step

Update the native host artifact path, rebuild the macOS package, and launch the
app to verify CEF uses the nested helper executable.

### Validation Plan

- Run `moon -C desktop run --target native package/macos`.
- Run `moon -C desktop info`.
- Run `moon -C desktop fmt`.
- Inspect the generated app bundle and launch it.
