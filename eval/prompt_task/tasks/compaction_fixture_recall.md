You are evaluating context retention. A previous transcript has already been
seeded into this session. Do not inspect files yet.

Reply only: ready for compaction.

--COMPACT--

Recover the benchmark decision from the earlier conversation context. Look for
these exact labels:

- `BENCHMARK_DECISION_ID`
- `BENCHMARK_REQUIRED_FIX`
- `BENCHMARK_ANSWER_FILE`

Write a JSON object to the path named by `BENCHMARK_ANSWER_FILE`. If that label
is absent, write to `{{WORKSPACE}}/.openseek-compaction-answer.json`.

The JSON object must include:

- `decision_id`: the exact `BENCHMARK_DECISION_ID` value
- `required_fix`: the exact `BENCHMARK_REQUIRED_FIX` value

After writing the file, finish with a short confirmation.
