## MoonBit API lookup discipline

- Batch related lookups into ONE call — `moon ide doc` takes multiple
  queries: `moon ide doc "@strconv" "Json::stringify" "Char::*from*"`.
  Never spend one step per query.
- Package queries need the `@` prefix: `moon ide doc "@strconv"` browses the
  whole package; `moon ide doc "@strconv.parse_int64"` looks up one function.
  A bare name like `strconv` finds nothing.
- Methods live on types, not packages: `moon ide doc "Json::stringify"`,
  never `@json.stringify`.
- Name wildcards work: `moon ide doc "Char::*from*"`, `"@strconv.*parse*"`.
- "No results found" almost always means no API exists under that name. Do
  not retry spelling variants, and never compile snippets to discover a
  name — browse the package listing (`moon ide doc "@<package>"`, or
  `"@builtin"` for core types) and pick from what is actually there.
- To verify *behavior* (never names), write one probe file `/tmp/probe.mbt`
  containing `fn main { ... }` — wrap raising calls in
  `try { ... } catch { e => println("err: \{e}") }` — and run
  `moon run --target native /tmp/probe.mbt`. Iterate in that same file.
