///|
test "compact-threshold defaults to 200000" {
  let parsed = run_matches(argv=["write", "MoonBit"], env={
    "DEEPSEEK": "test-key",
  })
  assert_true(compact_threshold(parsed) is Some(200000))
}

///|
test "compact-threshold 0 disables auto-compaction" {
  let parsed = run_matches(
    argv=["--compact-threshold", "0", "write", "MoonBit"],
    env={ "DEEPSEEK": "test-key" },
  )
  assert_true(compact_threshold(parsed) is None)
}

///|
test "compact-threshold reads the environment" {
  let parsed = run_matches(argv=["write", "MoonBit"], env={
    "DEEPSEEK": "test-key",
    "OPENSEEK_COMPACT_THRESHOLD": "50000",
  })
  assert_true(compact_threshold(parsed) is Some(50000))
}

///|
test "compact-threshold rejects non-numeric values" {
  let parsed = run_matches(
    argv=["--compact-threshold", "lots", "write", "MoonBit"],
    env={ "DEEPSEEK": "test-key" },
  )
  let _ = compact_threshold(parsed) catch {
    error => {
      assert_true("\{error}".contains("--compact-threshold"))
      return
    }
  }
  fail("non-numeric --compact-threshold accepted")
}

///|
test "compact-threshold rejects explicitly empty values" {
  let parsed = run_matches(
    argv=["--compact-threshold", "", "write", "MoonBit"],
    env={ "DEEPSEEK": "test-key" },
  )
  let _ = compact_threshold(parsed) catch {
    error => {
      assert_true("\{error}".contains("--compact-threshold"))
      return
    }
  }
  fail("empty --compact-threshold accepted")
}
