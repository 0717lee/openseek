#!/usr/bin/env bash

set -euo pipefail

target="${1:?usage: check_workspace_warnings.sh <moon-target>}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
editor_root="$repo_root/editor/"
diagnostics="$(mktemp)"
trap 'rm -f "$diagnostics"' EXIT

# `--deny-warn` is workspace-global, but editor intentionally retains warnings
# from its Monaco ports and owns that policy in editor.yml. Keep those visible
# there while rejecting warnings everywhere else in the integrated workspace.
if ! moon -C "$repo_root" check --target "$target" --output-json > "$diagnostics"; then
  echo "MoonBit $target check failed:" >&2
  jq -c 'select(.["$message_type"] == "diagnostic" and .level == "error")' \
    "$diagnostics" >&2
  exit 1
fi

if jq -e --arg editor_root "$editor_root" '
  select(
    .["$message_type"] == "diagnostic" and
    .level == "warning" and
    (
      (.path | startswith($editor_root)) |
      not
    )
  )
' "$diagnostics" >/dev/null; then
  echo "Unexpected MoonBit warnings:" >&2
  jq -c --arg editor_root "$editor_root" '
    select(
      .["$message_type"] == "diagnostic" and
      .level == "warning" and
      (
        (.path | startswith($editor_root)) |
        not
      )
    )
  ' "$diagnostics" >&2
  exit 1
fi

allowed_count="$(jq -s --arg editor_root "$editor_root" '
  map(
    select(
      .["$message_type"] == "diagnostic" and
      .level == "warning" and
      (.path | startswith($editor_root))
    )
  ) | length
' "$diagnostics")"
echo "MoonBit $target check passed; editor owns $allowed_count warnings."
