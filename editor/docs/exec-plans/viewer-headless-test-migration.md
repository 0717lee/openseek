# Viewer Headless Test Migration

## Goal

Reduce `tests/browser/component` from 107 Playwright tests to at most 43 by
moving model, view-model, contribution, lifecycle, and deterministic scheduling
assertions into Viewer white-box tests. Keep Playwright only for real browser
layout, DOM Range measurement, CSS, native input/focus, iframe ownership, and
native animation-frame behavior.

The current baseline is 107 component tests with approximately 183 seconds of
recorded test-body time. `moon test viewer --target js` currently runs 310
tests in approximately 1.6 seconds.

## Migration Ledger

| Existing browser coverage | Lower-layer owner | Browser evidence retained |
|---|---|---|
| async hover generation, cancellation, replacement, detach, dispose | `viewer/async_model_features_wbtest.mbt` with manual scheduler and request stamps | accepted visible hover in Viewer smoke/component |
| reveal request math, bands, cancellation, viewport scroll | `viewer/reveal_wbtest.mbt` and mounted pending-request tests | DOM Range and measured horizontal reveal in browser geometry |
| set-value identity, content events, scroll, folding, quick diff, marker refresh | `viewer/set_value_api_wbtest.mbt` plus mounted browser-data identity | root identity contrast in model-swap browser test |
| whitespace/control rendering policy | render-line and Viewer option MoonBit tests | runtime DOM/CSS switch in render-invalidation |
| cursor state and event matrices | cursor/view-model white-box suites | four native keyboard/pointer/copy bridge tests |
| definition/reference request ownership and stale-result guards | definition and references white-box suites | four context-menu/link/Peek/Markdown browser tests |
| folding state/actions and recursive toggle policy | folding contribution white-box suite | two chevron/ellipsis/keyboard/modifier tests |
| Markdown projection reconciliation and async renderer ownership | Markdown comment/document white-box and mounted suites | five comment and three document layout/diagram tests |
| render invalidation/no-op scheduling and retained ownership | view/event/render white-box and mounted suites | three DOM convergence/widget/zone tests |
| ViewZone ids, callback ordering, model/dispose lifecycle | view-zone layout/host and mounted tests | three caller-DOM/geometry/mouse tests |

No Playwright assertion is removed until its ledger destination is green or the
same browser mechanism remains asserted by one of the retained cases.

## Retained Browser Budget

- Browser geometry: 6
- Cursor input: 4
- Definition navigation: 4
- Folding and nested folding: 2
- Markdown folding: 2
- Peek references: 2
- Markdown comments: 5
- Markdown document: 3
- Render invalidation: 3
- View zones: 3
- Initial size, read API, scroll animation (2), feedback, model swap, quick
  diff, Viewer API, whitespace selection: 9

Total: at most 43 tests.

## Milestones

1. Extract reusable headless and mounted Viewer white-box harnesses.
2. Complete deterministic lower-layer coverage and remove the standalone
   async/reveal/set-value/whitespace browser specs and bundles.
3. Trim the large input/navigation/Markdown/render suites to the retained
   browser contracts above.
4. Remove dead fixtures and globals, update harness documentation, measure the
   new suite, run all gates, and delete this completed plan.

## Acceptance

- Component list is at most 43 tests.
- Two consecutive component runs pass with `--retries=0`.
- Recorded warm test-body time is at most 90 seconds.
- No timeout, retry, or worker increase.
- `moon info` produces no public interface change.
- Editor and repository integration gates pass.
