///|
/// Count the non-overlapping occurrences of `needle` in `content`. An empty
/// `needle` counts as zero rather than matching every position.
pub fn count_occurrences(content : String, needle : String) -> Int {
  if needle == "" {
    return 0
  }
  let pieces = content.split(needle).collect()
  pieces.length() - 1
}

///|
/// Count the lines of `content` (split on `\n`) that contain every string in
/// `needles`. With an empty `needles` every line qualifies.
pub fn count_lines_containing_all(
  content : String,
  needles : Array[String],
) -> Int {
  for line in content.split("\n"); count = 0 {
    for needle in needles {
      if !line.contains(needle) {
        break
      }
    } nobreak {
      continue count + 1
    }
  } nobreak {
    count
  }
}
