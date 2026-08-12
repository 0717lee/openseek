///|
test "path activation follows the target shell's syntax" {
  assert_eq(
    @shellenv.path_prepend_command(
      "/bin/zsh",
      "/Applications/Seek Moon/toolchain/bin",
      windows=false,
    ),
    "export PATH='/Applications/Seek Moon/toolchain/bin':\"$PATH\"\r",
  )
  assert_eq(
    @shellenv.path_prepend_command(
      "/opt/homebrew/bin/fish",
      "/tmp/it's\\moon/bin",
      windows=false,
    ),
    "set -gx PATH '/tmp/it\\'s\\\\moon/bin' $PATH\r",
  )
  assert_eq(
    @shellenv.path_prepend_command(
      "/bin/tcsh",
      "/tmp/it's moon/bin",
      windows=false,
    ),
    "setenv PATH '/tmp/it'\\''s moon/bin':\"$PATH\"\r",
  )
  assert_eq(
    @shellenv.path_prepend_command(
      "/usr/local/bin/pwsh",
      "/tmp/it's moon/bin",
      windows=false,
    ),
    "$env:Path = '/tmp/it''s moon/bin:' + $env:Path\r",
  )
  assert_eq(
    @shellenv.path_prepend_command(
      "C:/Program Files/PowerShell/pwsh.exe",
      "C:\\Users\\Moon User\\toolchain\\bin",
      windows=true,
    ),
    "$env:Path = 'C:\\Users\\Moon User\\toolchain\\bin;' + $env:Path\r",
  )
  assert_eq(
    @shellenv.path_prepend_command(
      "C:\\Windows\\System32\\cmd.exe",
      "C:\\Users\\Moon User\\toolchain\\bin",
      windows=true,
    ),
    "set \"Path=C:\\Users\\Moon User\\toolchain\\bin;%Path%\"\r",
  )
}
