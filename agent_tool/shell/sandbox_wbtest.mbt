///|
test "sandbox trusts only narrow moon source-writing commands" {
  assert_true(mode_for("moon fmt") is TrustedSourceWrite)
  assert_true(mode_for("moon info") is TrustedSourceWrite)
  assert_true(
    mode_for("moon ide rename old new --loc main.mbt:1:8 --apply")
    is TrustedSourceWrite,
  )
  assert_true(mode_for("moon fmt && moon check") is TrustedSourceWrite)
  assert_true(mode_for("cd ./pkg && moon fmt") is TrustedSourceWrite)
  assert_true(mode_for("moon fmt >/dev/null") is TrustedSourceWrite)
  assert_true(mode_for("moon info > /tmp/log") is TrustedSourceWrite)
  assert_true(mode_for("moon test --update 2>/tmp/err") is TrustedSourceWrite)
  assert_true(mode_for("moon fmt > out.log") is TrustedSourceWrite)
  assert_true(mode_for("moon check") is TrustedSourceWrite)
  assert_true(mode_for("moon build") is TrustedSourceWrite)
  assert_true(mode_for("moon test") is TrustedSourceWrite)
  assert_true(mode_for("moon run cmd/main") is TrustedSourceWrite)
  assert_true(mode_for("moon run cmd/main -- --help") is TrustedSourceWrite)
  assert_true(mode_for("moon run cmd/main -- -u") is TrustedSourceWrite)
  assert_true(mode_for("moon run cmd/main --help") is SourceReadOnly)
  assert_true(
    mode_for("moon run -e 'fn main { println(1) }'") is SourceReadOnly,
  )
  assert_true(mode_for("moon run -e'fn main { println(1) }'") is SourceReadOnly)
  assert_true(
    mode_for("moon run --target native -e 'fn main { println(1) }'")
    is SourceReadOnly,
  )
  assert_true(mode_for("moon run -") is SourceReadOnly)
  assert_true(mode_for("moon run -- -") is SourceReadOnly)
  assert_true(mode_for("moon run --target native -") is SourceReadOnly)
  assert_true(mode_for("moon run --target native -- -") is SourceReadOnly)
  assert_true(mode_for("moon fmt --check") is SourceReadOnly)
  assert_true(mode_for("moon check --help") is SourceReadOnly)
  assert_true(mode_for("cd pkg && moon fmt") is TrustedSourceWrite)
  assert_true(mode_for("moon fmt && git diff") is SourceReadOnly)
  assert_true(mode_for("moon fmt > main.mbt") is SourceReadOnly)
  assert_true(mode_for("moon fmt 2> main.mbt") is SourceReadOnly)
  assert_true(mode_for("moon fmt 1>> main.mbt") is SourceReadOnly)
  assert_true(mode_for("cd ./pkg && moon fmt > main.mbt") is SourceReadOnly)
  assert_true(mode_for("moon fmt 2>&1") is TrustedSourceWrite)
  assert_true(mode_for("sed -i '' 's/a/b/' *.mbt") is SourceReadOnly)
}

///|
test "sandbox source write regex covers moonbit source and manifests" {
  let regex = source_write_regex("/tmp/a.b")
  // The deny regex matches source files at any depth and no longer special-cases
  // build directories; `_build`/`.mooncakes` are re-allowed by the carve-out.
  assert_true(regex.contains("\\.mbt\\.md|\\.mbt|\\.mbti"))
  assert_false(regex.contains("_build"))
  let carveout = source_write_build_carveout_regex("/tmp/a.b")
  assert_true(carveout.contains("_build|\\.mooncakes"))
  assert_true(
    is_protected_workspace_source_path("/workspace", "/workspace/moon.mod"),
  )
  assert_true(
    is_protected_workspace_source_path("/workspace", "/workspace/pkg/moon.pkg"),
  )
  assert_true(
    is_protected_workspace_source_path("/workspace", "/workspace/pkg/main.mbt"),
  )
  assert_true(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/pkg/_build.mbt",
    ),
  )
  assert_true(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/.mooncakes.mbt",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/backup-moon.mod",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/_build/wasm-gc/release/format/main.mbt",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/.mooncakes/moonbitlang/core/main.mbt",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/pkg/_build/main.mbt",
    ),
  )
  assert_false(
    is_protected_workspace_source_path(
      "/workspace", "/workspace/scripts/.mooncakes/pkg/main.mbt",
    ),
  )
  assert_true(is_under_workspace_root("C:\\repo", "C:\\repo\\main.mbt"))
  assert_true(
    is_protected_workspace_source_path("C:\\repo", "C:\\repo\\main.mbt"),
  )
  assert_true(
    is_protected_workspace_source_path("C:\\repo", "C:\\repo\\pkg\\moon.pkg"),
  )
  assert_false(
    is_protected_workspace_source_path("C:\\repo", "C:\\repo\\_build\\main.mbt"),
  )
}

///|
async test "sandbox profile is cached per normalized workspace root" {
  let profile = source_write_readonly_profile_data("/workspace").profile
  let cached = source_write_readonly_profile_data("/workspace/").profile
  assert_eq(cached, profile)
  assert_true(profile.contains("(deny file-write*"))
  assert_true(profile.contains("(allow file-write* (regex"))
  assert_false(profile.contains("(deny file-write-create"))
  assert_false(profile.contains("(literal \"/workspace\")"))
}

///|
async test "sandbox profile blocks existing directories that contain source" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-source-tree-profile-", root => {
    @fs.mkdir("\{root}/pkg")
    @fs.mkdir("\{root}/assets")
    @fs.mkdir("\{root}/.git")
    @fs.mkdir("\{root}/_build")
    @fs.write_file(
      "\{root}/pkg/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/assets/logo.txt",
      "not MoonBit source\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/_build/generated.mbt",
      "pub fn generated() -> Int { 1 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/.git/ignored.mbt",
      "not part of the workspace source tree\n",
      create_mode=CreateOrTruncate,
    )
    let profile = source_write_readonly_profile_data(root).profile
    assert_true(profile.contains("(deny file-write*"))
    assert_true(profile.contains("(literal \"\{root}/pkg\")"))
    assert_false(profile.contains("(literal \"\{root}/assets\")"))
    assert_false(profile.contains("(literal \"\{root}/.git\")"))
    assert_false(profile.contains("(literal \"\{root}/_build\")"))
  })
}

///|
async test "sandbox profile cache invalidates when source tree changes" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-profile-invalidate-", root => {
    @fs.mkdir("\{root}/assets")
    @fs.write_file(
      "\{root}/assets/logo.txt",
      "not MoonBit source\n",
      create_mode=CreateOrTruncate,
    )
    let first = source_write_readonly_profile_data(root).profile
    assert_false(first.contains("(literal \"\{root}/assets\")"))
    @async.sleep(5)
    @fs.write_file(
      "\{root}/assets/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    let second = source_write_readonly_profile_data(root).profile
    assert_true(second.contains("(literal \"\{root}/assets\")"))
  })
}

///|
async test "sandbox preblocks source-writing script snippets" {
  let root = "/workspace"
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import os; os.makedirs(\"_build/gen\", exist_ok=True); open(\"_build/gen/main.mbt\", \"w\").write(\"pub fn generated() -> Int { 1 }\\\\n\"); os.rename(\"_build/gen\", \"pkg\")'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import os; src=\"_build/gen\"; dst=\"pkg\"; os.makedirs(src, exist_ok=True); open(src + \"/main.mbt\", \"w\").write(\"pub fn generated() -> Int { 1 }\\\\n\"); os.rename(src, dst)'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "mkdir -p _build/gen && printf source > _build/gen/main.mbt && python3 -c 'import os; os.rename(\"_build/gen\", \"pkg\")'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import os; open(\"_build/generated.txt\", \"w\").write(\"asset\"); os.rename(\"_build/generated.txt\", \"asset.txt\")'",
      ),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import shutil; shutil.copyfile(\"replacement.txt\", \"main.mbt\")'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "node -e 'const fs = require(\"fs\"); fs.cpSync(\"_build/gen\", \"pkg\", { recursive: true })'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'print(open(\"main.mbt\").read())'",
      ),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import sys; sys.stdout.write(open(\"main.mbt\").read())'",
      ),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import sys; sys.stderr.write(open(\"main.mbt\").read())'",
      ),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'print(\"w\"); print(open(\"main.mbt\").read())'",
      ),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import sys; sys.stdout.buffer.write(open(\"main.mbt\", \"rb\").read())'",
      ),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'open(\"/tmp/probe.mbt\", \"w\").write(\"x\")'",
      ),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'print(\"main.mbt\".replace(\".mbt\", \".txt\"))'",
      ),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'from pathlib import Path; Path(\"main.mbt\").write_text(\"pub fn answer() -> Int { 1 }\\\\n\")' 2>/dev/null || true",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "awk 'BEGIN { print \"pub fn answer() -> Int { 43 }\" > \"main.mbt\" }' 2>/dev/null || true",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "awk -v marker=.mbt 'BEGIN { if (1 > 0) print marker }'",
      ),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "sh -c 'mkdir -p _build/gen; printf source > _build/gen/main.mbt; mv _build/gen pkg'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "bash --noprofile -c 'mkdir -p _build/gen; printf source > _build/gen/main.mbt; mv _build/gen pkg'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "bash -o pipefail -c 'mkdir -p _build/gen; printf source > _build/gen/main.mbt; mv _build/gen pkg'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "dash -c 'mkdir -p _build/gen; printf source > _build/gen/main.mbt; mv _build/gen pkg'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "ksh -c 'mkdir -p _build/gen; printf source > _build/gen/main.mbt; mv _build/gen pkg'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
  assert_true(
    direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "node -e 'const fs = require(\"fs\"); fs.mkdirSync(\"_build/gen\", { recursive: true }); fs.writeFileSync(\"_build/gen/main.mbt\", \"pub fn generated() -> Int { 1 }\\\\n\"); fs.renameSync(\"_build/gen\", \"pkg\")'",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/pkg"),
  )
}

///|
async test "sandbox preblocks command-line created source directories" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-created-dir-", root => {
    @fs.write_file(
      "\{root}/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    let target = direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "mkdir backup && cp main.mbt backup 2>/dev/null || true",
      ),
      root,
      Some(root),
    )
    assert_true(target == Some("\{root}/backup"))
  })
}

///|
async test "sandbox preblocks scripted existing source tree moves" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-script-source-dir-", root => {
    @fs.mkdir("\{root}/pkg")
    @fs.write_file(
      "\{root}/pkg/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    let target = direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import os; os.rename(\"pkg\", \"pkg.bak\")' 2>/dev/null || true",
      ),
      root,
      Some(root),
    )
    assert_true(target == Some("\{root}/pkg.bak"))
  })
}

///|
async test "sandbox keeps guarded cd cwd visible after semicolon" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-guarded-cd-", root => {
    @fs.mkdir("\{root}/pkg")
    @fs.mkdir("\{root}/pkg/sub")
    @fs.write_file(
      "\{root}/pkg/sub/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    let target = direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy("cd ./pkg && true; rm -rf sub"),
      root,
      Some(root),
    )
    assert_true(target == Some("\{root}/pkg/sub"))
  })
}

///|
async test "sandbox preblocks scripted external source tree imports" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-script-external-dir-", root => {
    let workspace = "\{root}/workspace"
    let generated = "\{root}/generated_pkg"
    let generated_file = "\{root}/generated.mbt"
    @fs.mkdir(workspace)
    @fs.mkdir(generated)
    @fs.write_file(
      "\{generated}/main.mbt",
      "pub fn generated() -> Int { 1 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      generated_file,
      "pub fn generated_file() -> Int { 1 }\n",
      create_mode=CreateOrTruncate,
    )
    let target = direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import shutil; shutil.move(\"\{generated}\", \"pkg\")'",
      ),
      workspace,
      Some(workspace),
    )
    assert_true(target == Some("\{workspace}/pkg"))
    let copy_target = direct_source_tree_operation_target_for_root(
      @shell_parse.parse_for_policy(
        "python3 -c 'import shutil; shutil.copy(\"\{generated_file}\", \"pkg\")'",
      ),
      workspace,
      Some(workspace),
    )
    assert_true(copy_target == Some("\{workspace}/pkg"))
  })
}

///|
async test "sandbox preblocks common source-writing commands" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-common-writers-", root => {
    @fs.write_file(
      "\{root}/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/replacement.txt",
      "pub fn answer() -> Int { 43 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.mkdir("\{root}/pkg")
    @fs.write_file(
      "\{root}/pkg/main.mbt",
      "pub fn package_answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.mkdir("\{root}/src")
    @fs.mkdir("\{root}/src/pkg")
    @fs.mkdir("\{root}/_build")
    @fs.write_file(
      "\{root}/src/pkg/main.mbt",
      "pub fn nested_package_answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      "\{root}/_build/main.mbt",
      "pub fn generated() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    @fs.symlink(target="main.mbt", "\{root}/out.log")
    let real_root = @fs.realpath(root)
    let main_path = "\{real_root}/main.mbt"
    let src_pkg_path = "\{real_root}/src/pkg"
    let backup_path = "\{real_root}/backup.mbt"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "cp replacement.txt main.mbt 2>/dev/null || true",
          ),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "cp replacement.txt out.log 2>/dev/null || true",
          ),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("touch main.mbt"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("touch out.log 2>/dev/null || true"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      direct_source_tree_operation_target_for_root(
        @shell_parse.parse_for_policy("touch -h out.log"),
        real_root,
        Some(real_root),
      )
      is None,
    )
    assert_true(
      direct_source_tree_operation_target_for_root(
        @shell_parse.parse_for_policy("touch --no-dereference out.log"),
        real_root,
        Some(real_root),
      )
      is None,
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("touch --no-dereference main.mbt"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("printf x | tee main.mbt >/dev/null"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("printf x | tee out.log >/dev/null"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("install replacement.txt out.log"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("install replacement.txt main.mbt"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "install -Dm644 replacement.txt main.mbt",
          ),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "install -Dm 644 replacement.txt main.mbt",
          ),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("Set-Content main.mbt value"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "Add-Content -Path out.log -Value value",
          ),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("Out-File -FilePath main.mbt"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("Tee-Object -FilePath out.log"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("Copy-Item replacement.txt out.log"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "Copy-Item _build/main.mbt src/main.mbt -ErrorAction SilentlyContinue",
          ),
          real_root,
          Some(real_root),
        ),
        "\{real_root}/src/main.mbt",
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("Move-Item main.mbt backup"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("Remove-Item main.mbt"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("Rename-Item main.mbt backup.mbt"),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "New-Item -Path main.mbt -ItemType File",
          ),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    // `-Name` is the leaf created under `-Path`, so the target is `./main.mbt`,
    // not the `.` directory.
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "New-Item -Path . -Name main.mbt -ItemType File",
          ),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    let powershell_remove_glob = "Remove-Item *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(powershell_remove_glob),
          powershell_remove_glob,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    // git apply / git am apply an EXTERNAL patch and stay pre-blocked (the only
    // remaining git pre-block; on macOS the runtime sandbox covers them too).
    for
      patch_cmd in [
        "git apply patch.diff", "git am patch.mbox", "git apply --cached patch.diff",
        "git apply --index patch.diff", "git update-index --cacheinfo 100644,abc,main.mbt",
        "git read-tree HEAD", "git fast-import",
      ] {
      assert_true(
        is_some_path(
          direct_source_tree_operation_target_for_root(
            @shell_parse.parse_for_policy(patch_cmd),
            real_root,
            Some(real_root),
          ),
          real_root,
        ),
      )
    }
    // git apply is also caught in the TooComplex text path (e.g. globbed patches).
    let git_apply_glob = "git apply *.patch"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(git_apply_glob),
          git_apply_glob,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    // Recoverable git worktree subcommands write from the object store and are no
    // longer pre-blocked (they run as trusted source writers instead).
    for
      recoverable_git in [
        "git checkout -- .", "git checkout feature/foo", "git switch feature/foo",
        "git restore main.mbt", "git reset --hard", "git clean -fd", "git rm main.mbt",
        "git stash",
      ] {
      assert_true(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(recoverable_git),
          real_root,
          Some(real_root),
        )
        is None,
      )
    }
    let find_sed_source = "find \{real_root} -name '*.mbt' -exec sed -i '' 's/42/43/' {} +"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(find_sed_source),
          find_sed_source,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let find_env_sed_source = "find \{real_root} -name '*.mbt' -exec env FOO=bar sed -i '' 's/42/43/' {} + 2>/dev/null || true"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(find_env_sed_source),
          find_env_sed_source,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let find_sed_source_case_insensitive = "find \{real_root} -iname '*.MBT' -exec sed -i '' 's/42/43/' {} +"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(find_sed_source_case_insensitive),
          find_sed_source_case_insensitive,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let find_sed_readme_glob = "find \{real_root} -name README.* -exec sed -i '' 's/42/43/' '{}' +"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(find_sed_readme_glob),
          find_sed_readme_glob,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    // `xargs sed -i` runs sed as the xargs utility, so an in-place edit reached
    // that way must be blocked even though sed is not in shell command position.
    // (These shapes parse as TooComplex via the unquoted glob; the simple
    // `find ... | xargs sed -i` form parses as Simple and is caught by the
    // source-write sandbox instead.)
    let xargs_sed_source = "echo *.mbt | xargs sed -i '' 's/42/43/g'"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(xargs_sed_source),
          xargs_sed_source,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let xargs_replace_sed = "echo *.mbt | xargs -I{} sed -i '' 's/42/43/g' {}"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(xargs_replace_sed),
          xargs_replace_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let xargs_n1_sed = "echo *.mbt | xargs -n 1 sed -i '' 's/42/43/g'"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(xargs_n1_sed),
          xargs_n1_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    // BSD/macOS `-J replstr` consumes its operand before the utility.
    let xargs_bsd_replace_sed = "echo *.mbt | xargs -J {} sed -i '' 's/42/43/g' {}"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(xargs_bsd_replace_sed),
          xargs_bsd_replace_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    // The same xargs-utility gap still applies to `git apply` (the one blocked
    // git op); recoverable git subcommands are trusted and not pre-blocked.
    let xargs_git_apply = "echo *.patch | xargs git apply"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(xargs_git_apply),
          xargs_git_apply,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    // Read-only xargs pipelines (sed is not the xargs utility, no in-place edit)
    // must not be blocked, so analysis loops keep working.
    let xargs_grep_readonly = "echo *.mbt | xargs grep -l 'sed -i'"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(xargs_grep_readonly),
        xargs_grep_readonly,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let safe_find_then_sed = "find \{real_root} -name '*.txt' -print; sed -i '' 's/42/43/' *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(safe_find_then_sed),
          safe_find_then_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let env_wrapped_sed = "env FOO=bar sed -i '' 's/42/43/' *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(env_wrapped_sed),
          env_wrapped_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let env_assignment_sed = "FOO=bar sed -i '' 's/42/43/' *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(env_assignment_sed),
          env_assignment_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let env_unset_wrapped_sed = "env -u FOO sed -i '' 's/42/43/' *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(env_unset_wrapped_sed),
          env_unset_wrapped_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let env_long_unset_wrapped_sed = "env --unset FOO sed -i '' 's/42/43/' *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(env_long_unset_wrapped_sed),
          env_long_unset_wrapped_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let command_wrapped_sed = "command sed -i '' 's/42/43/' *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(command_wrapped_sed),
          command_wrapped_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let find_sed_text = "find \{real_root} -name '*.txt' -exec sed -i '' 's/42/43/' {} +"
    assert_true(
      direct_source_tree_operation_target_for_root(
        @shell_parse.parse_for_policy(find_sed_text),
        real_root,
        Some(real_root),
      )
      is None,
    )
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(find_sed_text),
        find_sed_text,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let find_sed_text_quoted = "find \{real_root} -name '*.txt' -exec sed -i '' 's/42/43/' '{}' +"
    assert_true(
      direct_source_tree_operation_target_for_root(
        @shell_parse.parse_for_policy(find_sed_text_quoted),
        real_root,
        Some(real_root),
      )
      is None,
    )
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(find_sed_text_quoted),
        find_sed_text_quoted,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let find_sed_filter_after_exec = "find \{real_root} -exec sed -i '' 's/42/43/' '{}' + -name '*.txt'"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(find_sed_filter_after_exec),
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let broad_find_sed_text = "find \{real_root} -name '*' -exec sed -i '' 's/42/43/' '{}' +"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(broad_find_sed_text),
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let find_sed_literal_source = "find \{real_root} -name '*.txt' -exec sed -i '' 's/42/43/' main.mbt ';'"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(find_sed_literal_source),
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let find_sed_comma_quoted = "find \{real_root} -name '*.txt' -exec sed -i '' 's/42/43/' '{}' + , -exec sed -i '' 's/42/43/' '{}' +"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(find_sed_comma_quoted),
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let readonly_sed_pipeline = "sed -n '1,5p' *.mbt | grep -i answer"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(readonly_sed_pipeline),
        readonly_sed_pipeline,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let readonly_sed_file_named_i = "while true; do sed -f -i *.mbt\ndone"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(readonly_sed_file_named_i),
        readonly_sed_file_named_i,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let multiline_sed = "while true; do printf ok\nsed -i '' 's/42/43/' *.mbt\ndone"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(multiline_sed),
          multiline_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let background_sed = "sleep 1 & sed -i '' 's/42/43/' *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(background_sed),
          background_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let nested_shell_sed = "sh -c \"sed -i '' 's/42/43/' *.mbt\""
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(nested_shell_sed),
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let quoted_sed_text = "grep 'foo|sed -i' *.mbt"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(quoted_sed_text),
        quoted_sed_text,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let generated_script_with_sed = "cat > script.sh <<EOF\nsed -i 's/42/43/' f\nEOF"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(generated_script_with_sed),
        generated_script_with_sed,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let backslash_quoted_heredoc_then_copy = "cat <<\\EOF\nignored\nEOF\ncp main.mbt backup.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(backslash_quoted_heredoc_then_copy),
          backslash_quoted_heredoc_then_copy,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let generated_script_then_executed = "cat > script.sh <<EOF\ncp main.mbt backup.mbt\nEOF\nsh script.sh"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(generated_script_then_executed),
          generated_script_then_executed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let tee_generated_script_then_executed = "tee script.sh <<EOF >/dev/null\ncp main.mbt backup.mbt\nEOF\nsh script.sh"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(tee_generated_script_then_executed),
          tee_generated_script_then_executed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let pipe_tee_generated_script_then_executed = "cat <<EOF | tee script.sh >/dev/null\ncp main.mbt backup.mbt\nEOF\nsh script.sh"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(pipe_tee_generated_script_then_executed),
          pipe_tee_generated_script_then_executed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let generated_script_then_bash_with_option = "cat > script.sh <<EOF\ncp main.mbt backup.mbt\nEOF\nbash -o pipefail script.sh"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(generated_script_then_bash_with_option),
          generated_script_then_bash_with_option,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let generated_script_then_dot_sourced = "cat > script.sh <<EOF\ncp main.mbt backup.mbt\nEOF\n. script.sh"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(generated_script_then_dot_sourced),
          generated_script_then_dot_sourced,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let generated_script_then_source_sourced = "cat > script.sh <<EOF\ncp main.mbt backup.mbt\nEOF\nsource script.sh"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(generated_script_then_source_sourced),
          generated_script_then_source_sourced,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let generated_script_then_shell_c_sourced = "cat > script.sh <<EOF\nmkdir -p _build/gen\ncp main.mbt _build/gen/main.mbt\nmv _build/gen pkg\nEOF\nsh -c '. ./script.sh'"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(generated_script_then_shell_c_sourced),
          generated_script_then_shell_c_sourced,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let shell_heredoc_with_sed = "sh <<EOF\nsed -i '' 's/42/43/' *.mbt\nEOF"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(shell_heredoc_with_sed),
          shell_heredoc_with_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let python_heredoc_generated_move = "python3 <<EOF\nimport shutil\nshutil.move('_build/pkg', 'pkg')\nEOF"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(python_heredoc_generated_move),
          python_heredoc_generated_move,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let heredoc_source_redirect = "cat 2>/dev/null > main.mbt <<'EOF' || true\npub fn answer() -> Int { 43 }\nEOF"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(heredoc_source_redirect),
          heredoc_source_redirect,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let fd_duplicate_source_redirect = "printf x >& main.mbt *.txt 2>/dev/null || true"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(fd_duplicate_source_redirect),
          fd_duplicate_source_redirect,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let rm_glob_source = "rm *.mbt 2>/dev/null || true"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(rm_glob_source),
          rm_glob_source,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let grep_mv_source = "grep mv *.mbt"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(grep_mv_source),
        grep_mv_source,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let python_heredoc_source_write = "python3 - <<'PY'\nopen('main.mbt', 'w').write('pub fn answer() -> Int { 43 }\\n')\nPY"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(python_heredoc_source_write),
          python_heredoc_source_write,
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    let outside_python_heredoc_source_write = "python3 - <<'PY'\nopen('/tmp/probe.mbt', 'w').write('x')\nPY"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(outside_python_heredoc_source_write),
        outside_python_heredoc_source_write,
        real_root,
        Some("/tmp"),
      )
      is None,
    )
    let outside_python_c_source_write = "python3 -c 'open(\"/tmp/probe.mbt\", \"w\").write(\"x\")' *.txt"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(outside_python_c_source_write),
        outside_python_c_source_write,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let cd_outside_glob_sed = "cd /tmp && sed -i '' 's/42/43/' *.mbt"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(cd_outside_glob_sed),
        cd_outside_glob_sed,
        real_root,
        Some(real_root),
      )
      is None,
    )
    let cd_workspace_glob_sed = "cd \{real_root} && sed -i '' 's/42/43/' *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(cd_workspace_glob_sed),
          cd_workspace_glob_sed,
          real_root,
          Some("/tmp"),
        ),
        real_root,
      ),
    )
    let versioned_python_source_write = "python3.12 -c 'open(\"main.mbt\", \"w\").write(\"pub fn answer() -> Int { 43 }\\\\n\")'"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(versioned_python_source_write),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    let python_exe_source_write = "Python.EXE -c 'open(\"main.mbt\", \"w+\").close()' 2>/dev/null || true"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(python_exe_source_write),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    let python_create_mode_source_write = "python -c 'open(\"main.mbt\", \"x\").close()' 2>/dev/null || true"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(python_create_mode_source_write),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    let masked_versioned_python_source_write = "python3.12 -c 'open(\"main.mbt\", \"w\").write(\"pub fn answer() -> Int { 43 }\\\\n\")' 2>/dev/null || true"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(masked_versioned_python_source_write),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    let find_sed_branch = "find \{real_root} -name '*.txt' -o -exec sed -i '' 's/42/43/' {} +"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(find_sed_branch),
          find_sed_branch,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let find_sed_branch_quoted = "find \{real_root} -name '*.txt' -o -exec sed -i '' 's/42/43/' '{}' +"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(find_sed_branch_quoted),
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let find_sed_comma = "find \{real_root} -name '*.txt' -exec sed -i '' 's/42/43/' {} + , -exec sed -i '' 's/42/43/' {} +"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(find_sed_comma),
          find_sed_comma,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let grouped_sed = "{ sed -i '' 's/42/43/' *.mbt; }"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(grouped_sed),
          grouped_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let until_sed = "until sed -i '' 's/42/43/' *.mbt; do true; done"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(until_sed),
          until_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let elif_sed = "if false; then true; elif sed -i '' 's/42/43/' *.mbt; then true; fi"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(elif_sed),
          elif_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let if_env_sed = "if env FOO=bar sed -i '' 's/42/43/' *.mbt; then true; fi"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(if_env_sed),
          if_env_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let if_command_sed = "if command sed -i '' 's/42/43/' *.mbt; then true; fi"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(if_command_sed),
          if_command_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let loop_sed = "while IFS= read -r f; do sed -i '' 's/42/43/' \"$f\"; done < /tmp/files.txt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(loop_sed),
          loop_sed,
          real_root,
          Some(real_root),
        ),
        real_root,
      ),
    )
    let cd_glob_sed = "cd pkg && sed -i '' 's/42/43/' *.mbt"
    assert_true(
      is_some_path(
        dynamic_source_tree_operation_target(
          @shell_parse.parse_for_policy(cd_glob_sed),
          cd_glob_sed,
          real_root,
          Some(real_root),
        ),
        "\{real_root}/pkg",
      ),
    )
    let mkdir_or_cp_source = "mkdir gen || true; cp /tmp/generated.mbt gen 2>/dev/null || true"
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(mkdir_or_cp_source),
          real_root,
          Some(real_root),
        ),
        "\{real_root}/gen",
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "cd src && mv pkg pkg.bak 2>/dev/null || true",
          ),
          real_root,
          Some(real_root),
        ),
        src_pkg_path,
      ),
    )
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy("cp main.mbt backup.txt"),
        "cp main.mbt backup.txt",
        real_root,
        Some(real_root),
      )
      is None,
    )
    assert_true(
      direct_source_tree_operation_target_for_root(
        @shell_parse.parse_for_policy("cp main.mbt backup.txt"),
        real_root,
        Some(real_root),
      )
      is None,
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("cp main.mbt backup.mbt"),
          real_root,
          Some(real_root),
        ),
        backup_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy("mv --force pkg pkg.bak"),
          real_root,
          Some(real_root),
        ),
        "\{real_root}/pkg",
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "mv -b main.mbt backup 2>/dev/null || true",
          ),
          real_root,
          Some(real_root),
        ),
        main_path,
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "mv --no-target-directory _build/gen pkg",
          ),
          real_root,
          Some(real_root),
        ),
        "\{real_root}/pkg",
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "mkdir -p _build/gen.v1 && printf source > _build/gen.v1/main.mbt && mv _build/gen.v1 pkg.v1",
          ),
          real_root,
          Some(real_root),
        ),
        "\{real_root}/pkg.v1",
      ),
    )
    assert_true(
      is_some_path(
        direct_source_tree_operation_target_for_root(
          @shell_parse.parse_for_policy(
            "mkdir -p assets _build/gen.tmp && printf source > _build/gen.tmp/main.mbt && mv _build/gen.tmp assets/pkg.tmp",
          ),
          real_root,
          Some(real_root),
        ),
        "\{real_root}/assets/pkg.tmp",
      ),
    )
    assert_true(
      direct_source_tree_operation_target_for_root(
        @shell_parse.parse_for_policy(
          "mkdir -p assets _build && printf data > _build/logo.txt && mv _build/logo.txt assets/logo.txt",
        ),
        real_root,
        Some(real_root),
      )
      is None,
    )
  })
}

///|
fn is_some_path(value : String?, expected : String) -> Bool {
  match value {
    Some(path) => path == expected
    None => false
  }
}

///|
test "sandbox denial detection ignores masked exit code" {
  let output = {
    exit_code: Some(0),
    text: "sh: main.mbt: Operation not permitted\n",
    output_limit_reached: false,
  }
  assert_true(sandbox_denied_source_write(output, []))
  assert_true(
    agent_output_has_shell_sandbox_denial({
      output,
      source_write_sandboxed: true,
      sandbox_denial_subjects: [],
    }),
  )
  assert_false(
    agent_output_has_shell_sandbox_denial({
      output,
      source_write_sandboxed: false,
      sandbox_denial_subjects: [],
    }),
  )
  let generic = {
    exit_code: Some(0),
    text: "Permission denied\n",
    output_limit_reached: false,
  }
  assert_false(sandbox_denied_source_write(generic, []))
  let prose = {
    exit_code: Some(0),
    text: "Permission denied while reading main.mbt\n",
    output_limit_reached: false,
  }
  assert_false(sandbox_denied_source_write(prose, []))
  let quoted_prose = {
    exit_code: Some(0),
    text: "Permission denied while reading 'main.mbt'\n",
    output_limit_reached: false,
  }
  assert_false(sandbox_denied_source_write(quoted_prose, []))
  let python = {
    exit_code: Some(0),
    text: "PermissionError: [Errno 1] Operation not permitted: 'main.mbt'\n",
    output_limit_reached: false,
  }
  assert_true(sandbox_denied_source_write(python, []))
  let subject_after_denial = {
    exit_code: Some(0),
    text: "Operation not permitted: main.mbt\n",
    output_limit_reached: false,
  }
  assert_true(sandbox_denied_source_write(subject_after_denial, []))
  let permission_subject = {
    exit_code: Some(0),
    text: "Permission denied: main.mbt\n",
    output_limit_reached: false,
  }
  assert_true(sandbox_denied_source_write(permission_subject, []))
  let directory_rename_subject = {
    exit_code: Some(0),
    text: "PermissionError: [Errno 1] Operation not permitted: 'pkg'\n",
    output_limit_reached: false,
  }
  assert_false(sandbox_denied_source_write(directory_rename_subject, []))
  assert_true(sandbox_denied_source_write(directory_rename_subject, ["pkg"]))
  assert_true(
    agent_output_has_shell_sandbox_denial({
      output: directory_rename_subject,
      source_write_sandboxed: true,
      sandbox_denial_subjects: ["pkg"],
    }),
  )
  let unrelated_readonly_output = {
    exit_code: Some(0),
    text: "foo: Operation not permitted\n",
    output_limit_reached: false,
  }
  assert_false(sandbox_denied_source_write(unrelated_readonly_output, []))
  assert_false(sandbox_denied_source_write(unrelated_readonly_output, ["pkg"]))
  assert_false(
    agent_output_has_shell_sandbox_denial({
      output: unrelated_readonly_output,
      source_write_sandboxed: true,
      sandbox_denial_subjects: ["pkg"],
    }),
  )
  let moon_work = {
    exit_code: Some(0),
    text: "sh: moon.work: Operation not permitted\n",
    output_limit_reached: false,
  }
  assert_true(sandbox_denied_source_write(moon_work, []))
  assert_false(
    agent_output_has_shell_sandbox_denial({
      output: generic,
      source_write_sandboxed: true,
      sandbox_denial_subjects: [],
    }),
  )
}

///|
test "sandbox detects direct protected source write redirects" {
  let root = "/workspace"
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("printf x 2>/dev/null > main.mbt || true"),
      root,
      Some(root),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("cd ./pkg && printf x > main.mbt"),
      root,
      Some(root),
    )
    is Some("/workspace/pkg/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy(
        "cd /missing 2>/dev/null || printf x 2>/dev/null > main.mbt || true",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy(
        "cd /definitely-missing && :; printf x > main.mbt",
      ),
      root,
      Some(root),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("cd /workspace; printf x > main.mbt"),
      root,
      Some("/tmp"),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy(
        "cd /workspace; cd ./pkg && printf x > main.mbt",
      ),
      root,
      Some("/tmp"),
    )
    is Some("/workspace/pkg/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("cd ./pkg && true; printf x > main.mbt"),
      root,
      Some(root),
    )
    is Some("/workspace/pkg/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("cd /tmp && printf x > main.mbt"),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("printf x > moon.work"),
      root,
      Some(root),
    )
    is Some("/workspace/moon.work"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("printf x >| main.mbt"),
      root,
      Some(root),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy(": <> main.mbt"),
      root,
      Some(root),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy(": 4<> main.mbt"),
      root,
      Some(root),
    )
    is Some("/workspace/main.mbt"),
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("printf x > _build/out"),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("printf x > _build/main.mbt"),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("printf x > .mooncakes/pkg/main.mbt"),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("cat < main.mbt"),
      root,
      Some(root),
    )
    is None,
  )
  assert_true(
    direct_source_write_redirect_target_for_root(
      @shell_parse.parse_for_policy("printf x > /tmp/main.mbt"),
      root,
      Some(root),
    )
    is None,
  )
}

///|
fn mode_for(cmd : String) -> SourceWriteMode {
  source_write_mode_for_parse(
    @shell_parse.parse_for_policy(cmd),
    "/workspace",
    Some("/workspace"),
  )
}

///|
test "sandbox trusts recoverable git, sandboxes patch and reconfiguring git" {
  // Recoverable worktree subcommands run unsandboxed (trusted to write source):
  // every write they make comes from git's own object store.
  for
    cmd in [
      "git checkout -- main.mbt", "git checkout feature/foo", "git switch main",
      "git restore main.mbt", "git restore --source=HEAD~1 main.mbt", "git reset --hard",
      "git stash", "git stash pop", "git clean -fd", "git rm main.mbt", "cd pkg && git checkout -- main.mbt",
    ] {
    assert_true(mode_for(cmd) is TrustedSourceWrite)
  }
  // External-patch / store-feeder git, and `mv` (which moves arbitrary worktree
  // bytes onto the destination rather than reading the object store), stay
  // sandboxed.
  for
    cmd in [
      "git apply patch.diff", "git am patch.mbox", "git update-index --cacheinfo 100644,abc,main.mbt",
      "git read-tree HEAD", "git fast-import", "git mv notes.md main.mbt",
    ] {
    assert_true(mode_for(cmd) is SourceReadOnly)
  }
  // Reconfiguring global options (config/dir/exec/cwd/worktree) or a custom
  // environment could repoint git or enable a filter/merge driver, so they drop
  // git out of the trusted path.
  for
    cmd in [
      "git -c core.editor=x checkout -- .", "git -c filter.f.smudge=cmd checkout -- .",
      "git --git-dir=/tmp/x checkout -- .", "git --exec-path=/tmp checkout -- .",
      "git -C /tmp/x checkout -- .", "git --work-tree=/tmp/x checkout -- .", "FOO=bar git checkout -- .",
      "env GIT_CONFIG_COUNT=1 git checkout -- .",
    ] {
    assert_true(mode_for(cmd) is SourceReadOnly)
  }
  // Unknown / plumbing / read-only git is not granted trust (fail closed).
  for cmd in ["git status", "git diff", "git checkout-index -a", "git co -- ."] {
    assert_true(mode_for(cmd) is SourceReadOnly)
  }
}

///|
async test "sandbox scans source writes after CRLF here-documents" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-crlf-heredoc-", root => {
    @fs.write_file(
      "\{root}/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    let real_root = @fs.realpath(root)
    // CRLF line endings must not break here-document terminator matching. The
    // unquoted marker read used to keep the trailing `\r` while the closing-line
    // match stripped it, so the body never terminated and swallowed the later
    // in-place source edit.
    let crlf_heredoc_then_sed = "cat <<EOF\r\nnote\r\nEOF\r\nsed -i 's/42/43/' main.mbt\r\n"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(crlf_heredoc_then_sed),
        crlf_heredoc_then_sed,
        real_root,
        Some(real_root),
      )
      is Some(_),
    )
    // The LF form already worked; keep it as a control for the same shape.
    let lf_heredoc_then_sed = "cat <<EOF\nnote\nEOF\nsed -i 's/42/43/' main.mbt\n"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(lf_heredoc_then_sed),
        lf_heredoc_then_sed,
        real_root,
        Some(real_root),
      )
      is Some(_),
    )
  })
}

///|
async test "sandbox scans source writes after arithmetic left shifts" {
  @vfs.with_tmpdir(prefix="openseek-shell-sandbox-arith-shift-", root => {
    @fs.write_file(
      "\{root}/main.mbt",
      "pub fn answer() -> Int { 42 }\n",
      create_mode=CreateOrTruncate,
    )
    let real_root = @fs.realpath(root)
    // `$((1 << 8))` is arithmetic, not a here-document; the `<<` left shift must
    // not be read as a here-document operator whose phantom delimiter hides the
    // following in-place source edit.
    let arith_then_sed = "SHIFT=$((1 << 8))\nsed -i 's/42/43/' main.mbt\n"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(arith_then_sed),
        arith_then_sed,
        real_root,
        Some(real_root),
      )
      is Some(_),
    )
    // A bare arithmetic command with no source write stays allowed.
    let arith_only = "echo $((1 << 8))\n"
    assert_true(
      dynamic_source_tree_operation_target(
        @shell_parse.parse_for_policy(arith_only),
        arith_only,
        real_root,
        Some(real_root),
      )
      is None,
    )
  })
}
