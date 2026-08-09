///|
test "unchanged input has no hunks" {
  assert_eq(compute_unified_diff(["same"], ["same"]), [])
}

///|
test "empty document representations are canonicalized" {
  assert_eq(compute_unified_diff([], [""]), [])
  assert_eq(compute_unified_diff([""], []), [])
  assert_eq(compute_unified_diff([""], [""]), [])
}

///|
test "the line-matching algorithm is replaceable" {
  let saw_ignore_trim_whitespace = Ref(false)
  let algorithm = UnifiedDiffAlgorithm(compute_changes=(_, _, options) => {
    saw_ignore_trim_whitespace.val = options.ignore_trim_whitespace
    [
      {
        original_start_line_number: 1,
        original_end_line_number_exclusive: 2,
        modified_start_line_number: 1,
        modified_end_line_number_exclusive: 2,
      },
    ]
  })
  let hunks = compute_unified_diff(
    ["old"],
    ["new"],
    context_lines=0,
    ignore_trim_whitespace=true,
    algorithm~,
  )
  assert_true(saw_ignore_trim_whitespace.val)
  assert_eq(hunks.length(), 1)
  assert_eq(hunks[0].lines.map(line => line.kind), [Deletion, Addition])
}

///|
test "a replacement carries context and both line-number domains" {
  assert_eq(
    compute_unified_diff(
      ["before", "old", "after"],
      ["before", "new", "after"],
      context_lines=1,
    ),
    [
      {
        original_start_line_number: 1,
        original_line_count: 3,
        modified_start_line_number: 1,
        modified_line_count: 3,
        lines: [
          {
            kind: Context,
            original_line_number: Some(1),
            modified_line_number: Some(1),
            text: "before",
          },
          {
            kind: Deletion,
            original_line_number: Some(2),
            modified_line_number: None,
            text: "old",
          },
          {
            kind: Addition,
            original_line_number: None,
            modified_line_number: Some(2),
            text: "new",
          },
          {
            kind: Context,
            original_line_number: Some(3),
            modified_line_number: Some(3),
            text: "after",
          },
        ],
      },
    ],
  )
}

///|
test "nearby changes merge and distant changes remain separate" {
  let original = ["0", "old-1", "2", "3", "4", "old-2", "6"]
  let modified = ["0", "new-1", "2", "3", "4", "new-2", "6"]
  assert_eq(
    compute_unified_diff(original, modified, context_lines=1).length(),
    2,
  )
  assert_eq(
    compute_unified_diff(original, modified, context_lines=2).length(),
    1,
  )
}

///|
test "context is bounded before arithmetic can overflow" {
  let hunks = compute_unified_diff(["old"], ["new"], context_lines=0x7FFFFFFF)
  assert_eq(hunks.length(), 1)
  assert_eq(hunks[0].original_line_count, 1)
  assert_eq(hunks[0].modified_line_count, 1)
}

///|
test "a new file uses the zero anchor on its empty original side" {
  assert_eq(compute_unified_diff([""], ["one", "two"]), [
    {
      original_start_line_number: 0,
      original_line_count: 0,
      modified_start_line_number: 1,
      modified_line_count: 2,
      lines: [
        {
          kind: Addition,
          original_line_number: None,
          modified_line_number: Some(1),
          text: "one",
        },
        {
          kind: Addition,
          original_line_number: None,
          modified_line_number: Some(2),
          text: "two",
        },
      ],
    },
  ])
}

///|
test "a deleted file uses the zero anchor on its empty modified side" {
  assert_eq(compute_unified_diff(["one", "two"], []), [
    {
      original_start_line_number: 1,
      original_line_count: 2,
      modified_start_line_number: 0,
      modified_line_count: 0,
      lines: [
        {
          kind: Deletion,
          original_line_number: Some(1),
          modified_line_number: None,
          text: "one",
        },
        {
          kind: Deletion,
          original_line_number: Some(2),
          modified_line_number: None,
          text: "two",
        },
      ],
    },
  ])
}
