# Live DeepSeek CLI Documentation

Unlike [`tests/cram/cli.md`](../cram/cli.md), the example here makes a **real**
DeepSeek API call — there is no mocking. It lives in a separate directory so the
offline suite can run in CI without credentials, while this one is opt-in:

```bash
export DEEPSEEK=sk-...            # a real DeepSeek API key
moon cram test tests/live
```

The agent streams one JSON object per line (JSONL) to stdout. Instead of an
external tool such as `jq`, we parse that log with MoonBit itself: the published
[`bobzhang/jsonl`](https://mooncakes.io/docs/bobzhang/jsonl) package reads the
stream through `moonbitlang/async/io` and hands back typed `Json` values, so the
assertions are plain MoonBit pattern matches. The `moon run -e` script below is
the whole consumer; `grep '='` only drops `moon`'s own dependency-resolution
chatter, not any log content.

We give the cheap Flash model a trivial, self-contained task and a tiny step
budget. The script then proves two things from the real log: that the request
reached DeepSeek and came back with token accounting (`real_api_round_trip`),
and that the model invoked the `finish` tool with the requested answer
(`finished_with_DONE`).

```mooncram
$ openseek.exe --model deepseek-v4-flash --max-steps 3 "Call the finish tool immediately with the answer DONE. Use no other tool." 2>/dev/null \
>   | moon run --target native -e 'import {
>   "bobzhang/jsonl@0.1.0",
>   "moonbitlang/async",
>   "moonbitlang/async/stdio",
> }
> 
> async fn main {
>   let values = @jsonl.read_all(@stdio.stdin)
>   let mut tokens_ok = false
>   let mut finished = false
>   for value in values {
>     match value {
>       { "prompt_tokens": Number(n, ..), .. } => if n > 0.0 { tokens_ok = true }
>       _ => ()
>     }
>     match value {
>       { "answer": String(answer), .. } =>
>         if answer.contains("DONE") { finished = true }
>       _ => ()
>     }
>   }
>   println("real_api_round_trip=\{tokens_ok}")
>   println("finished_with_DONE=\{finished}")
> }' 2>/dev/null \
>   | grep '='
real_api_round_trip=true
finished_with_DONE=true
```
