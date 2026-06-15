---
name: "openseek-review"
description: "Run the local OpenSeek executable with DeepSeek to review MoonBit code changes. Use when the user asks for OpenSeek, openseek, DeepSeek-backed review, or this plugin to review code."
---

# OpenSeek Review

Use this skill to run `openseek` as an external reviewer. Prefer the bundled MCP
tool `openseek_review` when it is available. Fall back to the CLI commands below
only when MCP is unavailable or the user explicitly asks to run the executable
directly.

This MVP intentionally does not require OpenSeek to emit Codex review JSON. It
asks OpenSeek to finish with Markdown findings and returns OpenSeek's final
Markdown review report.

## Preconditions

- `openseek` must be available on `PATH`; otherwise invoke the binary by its path. After
  `moon install`, the binary is placed in Moon's bin directory, commonly `$MOON_HOME/bin`.
- `DEEPSEEK` must be set in the environment, or OpenSeek must otherwise receive an API key.
- If the target project loads `DEEPSEEK` through dotenvx, prefix review commands with
  `dotenvx run --`, or pass `use_dotenvx: true` to the MCP tool.
- The target project should be a Git repository for diff-based review targets.

If `openseek` is missing and the user wants you to install it, use the direct
git install path:

```bash
moon install https://github.com/moonbitlang/openseek cmd/openseek
```

Ask before installing dependencies or downloading from the network.

## Workflow

Resolve paths relative to this `SKILL.md`. The review prompt addendum is at `references/review-addendum.md`.
The plugin also contributes an MCP server launched with:

```bash
moon run --target native --target-dir .moon-build/openseek-review-mcp mcp/openseek_review.mbtx
```

When using MCP, call the `openseek_review` tool. Always pass the target repository
root as `dir`; the MCP server itself runs from the plugin directory so `.` is only
useful for manual testing from the target repository. Use:

- `target: "current"` for staged, unstaged, and untracked worktree changes.
- `target: "branch"` with `base_branch` for branch review.
- `target: "commit"` with `commit` for one commit.
- `openseek_bin` when `openseek` is not on `PATH`.
- `use_dotenvx: true` when the target repository's dotenvx setup supplies `DEEPSEEK`.

If you need a custom instruction, pass `task`; otherwise the wrapper builds a
standard code-review prompt from the target fields.

The CLI examples use `openseek`; replace it with the explicit Moon-installed binary
path, or prefix the command with `dotenvx run --`, when the environment requires it.

For current changes:

```bash
openseek --no-session --dir . --max-steps 200 --system-prompt-addendum-file <skill-dir>/references/review-addendum.md "Review the current code changes (staged, unstaged, and untracked files). Inspect the git diff and relevant files. Do not modify files. Finish with Markdown findings only."
```

For branch changes:

```bash
openseek --no-session --dir . --max-steps 200 --system-prompt-addendum-file <skill-dir>/references/review-addendum.md "Review the code changes against base branch main. Find the merge base if needed, inspect the diff, and relevant files. Do not modify files. Finish with Markdown findings only."
```

For one commit:

```bash
openseek --no-session --dir . --max-steps 200 --system-prompt-addendum-file <skill-dir>/references/review-addendum.md "Review the code changes introduced by commit <sha>. Inspect the commit diff and relevant files. Do not modify files. Finish with Markdown findings only."
```

Use OpenSeek's final Markdown answer as review evidence. If the CLI emits JSONL, look for the final `agent_finished` event's `answer` field first; otherwise use the last complete assistant message. Present findings first, ordered by severity. Make clear that the findings came from OpenSeek when reporting them back to the user.

If the live worktree must be protected from OpenSeek's current edit/write tools, create a disposable copy or worktree first and run `openseek` there. For the MVP, prefer the direct command above when the user explicitly wants to try the plugin quickly.

## Safety

OpenSeek currently has powerful local tools, including shell, edit, and write. The addendum tells it to review only, but that is prompt-level safety, not a hard sandbox. Use a disposable copy for higher-risk review targets.

Do not claim inline Codex `/review` integration. This plugin returns a Markdown review report; it does not populate Codex review-pane comments.
