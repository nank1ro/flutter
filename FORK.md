# flutter_solid

A fork of `flutter/flutter` that builds fine-grained, SolidJS-style reactivity
into the framework itself.

This file is the project README for the `~/github` catalog. Flutter's own
`README.md` is left untouched so that rebases onto upstream stay clean.

## What this is

Flutter today re-runs `build()` for a whole subtree whenever a `StatefulWidget`
calls `setState`, and diffs the resulting widget tree against the element tree.
That coarse granularity is the source of most Flutter performance advice
("push state down", "use `const`", "split widgets"). This fork replaces the
model rather than working around it:

- Signals, computed values, and effects are framework primitives, living in
  `packages/flutter/lib/src/foundation/`.
- Every `Element` tracks the signals read during its `build()` **by default**.
  There is no `SignalBuilder`, no opt-in wrapper widget, no annotation.
- Leaf render-object widgets bind props straight to `RenderObject` setters, so
  changing an opacity or a colour touches one setter and marks one render
  object dirty, without any widget or element being rebuilt.
- `StatefulWidget` and `setState` keep working, as legacy compatibility only.
- A "scene mode" for games drives a retained scene graph directly from signals
  onto `dart:ui`, skipping widgets, elements, and render objects entirely.

The primary goal is leaf-level reactivity with excellent performance, with
video-game workloads (thousands of independently animating nodes at 120 Hz)
as the explicit target.

## Non-goals

- Upstreaming. This is a standalone fork; there is no RFC and no attempt to
  match what the Flutter team would accept.
- API compatibility with `package:flutter_solidart`. That package works within
  the constraints of unmodified Flutter; here those constraints are gone.
- Web/HTML renderer parity in the early phases. Impeller and the Skia canvas
  paths come first.

## Setup

The checkout is a git worktree of the Flutter SDK that already exists on this
machine, so it costs almost nothing on disk: the tracked tree is around 200 MB
and the 3.4 GB `bin/cache` directory is not tracked by git at all.

```sh
git -C /Users/ale/flutter worktree add -b fine-grained-reactivity \
    /Users/ale/github/flutter_solid stable
ln -s /Users/ale/flutter/bin/cache /Users/ale/github/flutter_solid/bin/cache
/Users/ale/github/flutter_solid/bin/flutter --version
```

`bin/cache` is a symlink into the parent SDK rather than a real download.
This is a shortcut (`ponytail:` shared engine artifacts) and is only valid
while this worktree stays on the same engine version as the SDK it branched
from. If `bin/internal/engine.version` diverges from the parent SDK, delete
the symlink and let the tool populate a real `bin/cache` for this checkout.

`.gitignore` lists `/bin/cache/` with a trailing slash, which does not match a
symlink, so the symlink is excluded locally via `.git/info/exclude` instead.
Never `git add` it.

To connect this checkout to a GitHub fork of your own (not done for you):

```sh
gh repo fork flutter/flutter --remote-name upstream
git remote add origin git@github.com:nank1ro/flutter.git   # your fork
git push -u origin fine-grained-reactivity
```

## Running the framework tests

Tests run against this checkout's own `lib/`; `bin/cache` only supplies the
Dart SDK, the tools, and the engine artifacts.

```sh
cd packages/flutter
../../bin/flutter test test/widgets/framework_test.dart
../../bin/flutter test test/widgets/inherited_test.dart
../../bin/flutter test test/widgets/layout_builder_test.dart
```

The full framework suite is `../../bin/flutter test` from `packages/flutter`,
which takes a long time; prefer targeted files while iterating.

## Where it stands

Phases 0-4 are built. **Phase 5 (collapsing `Widget` and `Element`) was
spiked, measured, and rejected** — the spike stays in the tree as a
measurement artefact and as the reference implementation of component-once
effect semantics, and nothing depends on it. The fork's identity is settled:
**the classic tree with fine-grained leaf bindings, plus scene mode for
games.**

Headline numbers, µs per frame, lower is better. Every ratio is between two
rows measured in the same process, on the same workload, with the same number
of render objects per item, under an interleaved and rotated harness. Debug
`flutter test` on an Apple M1: relative comparison only, not profile-mode
performance. Full table, protocol and caveats in
[`BENCHMARKS.md`](docs/fine_grained_reactivity/BENCHMARKS.md).

| Workload | Best practice today | Phase 2 tracked build | Phase 3 leaf binding | Phase 5 collapsed (rejected) | Phase 4 scene, embedded |
| --- | --- | --- | --- | --- | --- |
| One of 10,000 sprites changes | 7005 | 7006 | 6359 | 6414 | — |
| All 10,000 sprites change, one batch | 33851 | 35759 | **16109** | 11743 | — |
| Text leaf at depth 50 | 318 | 322 | **267** | 273 | — |
| One of 1,000 rows changes | 392 | 387 | **375** | 383 | — |
| Move one of 10,000 sprites | — | — | 12695 | 11459 | **4815** |
| Move all 10,000, one batch | — | — | 42538 | 40677 | **7591** |
| Mount + dispose 10,000 nodes | — | — | 812049 | 532588 | **41848** (headless) |

- **Phase 2 costs nothing and removes the wrapper.** Parity on every row. A
  10x10 Material checkbox grid that reads no signal at all runs at 4198 µs with
  tracking off and 4142 µs with it on — no regression the harness can resolve.
- **Phase 3 is the fork's justification.** 2.10x when the whole graph changes,
  1.19x/1.20x on a leaf in a deep tree, with the rebuild count going from one
  to zero.
- **Phase 4 is the largest effect measured.** 2.64x to 5.60x over Phase 3's
  leaf bindings on the same embedded comparison, 19.4x on mount and dispose.
- **Phase 5 is a tie on realistic UI** (0.98x-1.11x) and is not being built.
  See [`PHASE5_DECISION.md`](docs/fine_grained_reactivity/PHASE5_DECISION.md).

## Documentation

- [`docs/fine_grained_reactivity/PLAN.md`](docs/fine_grained_reactivity/PLAN.md) — the engineering plan.
- [`docs/fine_grained_reactivity/SOURCE_MAP.md`](docs/fine_grained_reactivity/SOURCE_MAP.md) — verified anchors into the Flutter and alien_signals sources.
- [`docs/fine_grained_reactivity/BENCHMARKS.md`](docs/fine_grained_reactivity/BENCHMARKS.md) — benchmark scenarios, the interleaved harness, and every number.
- [`docs/fine_grained_reactivity/SCENE_MODE.md`](docs/fine_grained_reactivity/SCENE_MODE.md) — the retained scene graph for games.
- [`docs/fine_grained_reactivity/PHASE5_DECISION.md`](docs/fine_grained_reactivity/PHASE5_DECISION.md) — why the widget/element collapse is not being built.
