# Custom API URL

## Goal

Expose the already-supported DeepSeek client `api_url` override through the
OpenSeek CLI and TUI entry points, so users can point OpenSeek at a compatible
custom endpoint without changing application code.

## Accepted Design

- Add `--api-url` to `cmd/openseek` and `cmd/tui`.
- Add `OPENSEEK_API_URL` as the environment variable for the same setting.
- Treat an empty value as "use the default DeepSeek endpoint" by passing no
  `api_url` override.
- Pass a non-empty value unchanged to the existing `@agent` `api_url?` optional
  argument.
- Forward `OPENSEEK_API_URL` from TUI configuration into spawned engine
  processes.
- Keep the current typed DeepSeek model enum unchanged; this change does not add
  arbitrary model names.
- Keep the request schema unchanged; only the transport endpoint becomes
  configurable.

## Target Files And Surfaces

- `cmd/openseek/main.mbt`: parse `--api-url` / `OPENSEEK_API_URL`, pass it to
  one-shot and durable session runs, and cover parsing in tests.
- `cmd/openseek/serve.mbt`: pass the same parsed endpoint into serve-mode turns.
- `cmd/openseek/README.md`: document CLI usage and environment variable.
- `cmd/tui/main.mbt`: parse the endpoint setting into TUI config.
- `cmd/tui/state.mbt`: store the endpoint override in `AppConfig`.
- `cmd/tui/loop.mbt`: forward `OPENSEEK_API_URL` to spawned engines.
- TUI tests around config/env propagation.

## API And Interface Diff

- New CLI flag: `--api-url <url>`.
- New environment variable: `OPENSEEK_API_URL`.
- `agent/pkg.generated.mbti` should remain unchanged because `api_url?` already
  exists on the public agent APIs.
- `cmd/*` generated interfaces should not expose new public library APIs.

## Open Questions

- None for this implementation. Supporting arbitrary model strings is explicitly
  out of scope.

## Next Implementation Step

Create the small parsing helper for optional API URLs, wire it through
`cmd/openseek`, then mirror the same config field through the TUI engine
environment.

## Validation Plan

- Run targeted tests for `cmd/openseek` and `cmd/tui` where practical.
- Run `moon check`.
- Run `moon test`.
- Run `moon info && moon fmt`.
- Review generated `.mbti` diffs and ensure only expected files changed.
