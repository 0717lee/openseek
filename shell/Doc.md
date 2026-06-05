# Windows Shell Support Notes

This note summarizes how `.repos/codex` handles Windows shell execution and how
that compares with OpenSeek's current `agent_tool/shell` implementation.

## Codex Approach

Codex has a shell abstraction with explicit shell kinds:

- `Zsh`
- `Bash`
- `Sh`
- `PowerShell`
- `Cmd`

The runtime converts the model's shell command string into executable argv for
the selected shell:

| Shell | Executed argv shape |
| --- | --- |
| POSIX shells | `<shell> -c/-lc <command>` |
| PowerShell | `pwsh` or `powershell` plus `-Command <command>` |
| Cmd | `cmd.exe /c <command>` |

On Windows, Codex defaults to PowerShell if available. It tries PowerShell Core
(`pwsh`) first, then Windows PowerShell (`powershell.exe`), and falls back to
`cmd.exe` if no PowerShell executable is available.

Codex also changes the tool description on Windows. The model sees PowerShell
examples such as:

- `Get-ChildItem -Force`
- `Get-ChildItem -Recurse -Filter *.py`
- `Get-ChildItem -Recurse | Select-String -Pattern TODO`
- `$env:FOO='bar'; echo $env:FOO`

This means Codex does not generally translate POSIX commands into PowerShell.
Instead, it tells the agent that the active shell is PowerShell and expects the
agent to emit PowerShell syntax.

Codex adds extra Windows handling around execution:

- Prefixes PowerShell scripts to request UTF-8 console output.
- Has Windows-specific command safety checks for read-only PowerShell commands.
- Detects dangerous Windows patterns such as URL launches and force deletes.
- Supports Windows sandboxing with restricted-token and elevated helper paths.
- Supports `cmd.exe` as a shell override/fallback, but prefers PowerShell.

## OpenSeek Current Approach

OpenSeek's shell tool is simpler but follows the same basic direction:

- On Windows, `agent_tool/shell` runs `pwsh -NoProfile -Command <cmd>`.
- On non-Windows platforms, it runs `sh -c <cmd>`.
- The Windows tool description tells callers to use PowerShell syntax.
- The non-Windows tool description tells callers to use POSIX shell syntax.
- Output is capped and long-running commands can be timed out.
- A command policy blocks MoonBit validation commands from using raw shell and
  routes them toward structured tools such as `moon_cmd`.

The relevant implementation points are:

- `PlatformShellProgram = "pwsh"` on Windows.
- `platform_shell_args(cmd) = ["-NoProfile", "-Command", cmd]` on Windows.
- `PlatformShellProgram = "sh"` elsewhere.
- `platform_shell_args(cmd) = ["-c", cmd]` elsewhere.

## Similarities

The approaches are similar in the core execution model:

- Both pass a single command string to a platform-appropriate shell.
- Both use PowerShell syntax on Windows and POSIX shell syntax elsewhere.
- Both expose shell-specific guidance to the model through the tool description.
- Both avoid trying to make one shell syntax work everywhere.

## Differences

Codex has a broader shell abstraction and more Windows fallback logic:

- Codex can represent `PowerShell` and `Cmd` separately.
- Codex can accept a model-provided shell override in the unified exec path.
- Codex falls back from `pwsh` to `powershell.exe`, then to `cmd.exe`.
- Codex has Windows-specific safe/dangerous command classification.
- Codex has a Windows sandbox implementation.
- Codex prefixes PowerShell commands for UTF-8 output.

OpenSeek currently assumes `pwsh` exists on Windows and does not have a `cmd.exe`
fallback, Windows PowerShell fallback, shell override, or Windows-specific safety
classifier. Its main policy layer is focused on preventing MoonBit command
bypasses through raw shell.

## Takeaway

OpenSeek's approach is similar to Codex at the shell-selection and prompt-guidance
level. It is not yet as complete at the Windows compatibility and safety layer.
The highest-value Codex ideas to consider porting are:

1. Fall back from `pwsh` to `powershell.exe`, then optionally `cmd.exe`.
2. Add a small shell abstraction instead of hard-coding one program per platform.
3. Prefix PowerShell commands or otherwise normalize output encoding to UTF-8.
4. Add Windows-specific safety checks if shell approvals become security-relevant.
5. Keep MoonBit command routing separate, since OpenSeek's `moon_cmd` policy is a
   project-specific strength rather than something Codex handles the same way.
