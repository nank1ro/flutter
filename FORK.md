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

## Documentation

- [`docs/fine_grained_reactivity/PLAN.md`](docs/fine_grained_reactivity/PLAN.md) — the engineering plan.
- [`docs/fine_grained_reactivity/SOURCE_MAP.md`](docs/fine_grained_reactivity/SOURCE_MAP.md) — verified anchors into the Flutter and alien_signals sources.
- [`docs/fine_grained_reactivity/BENCHMARKS.md`](docs/fine_grained_reactivity/BENCHMARKS.md) — benchmark scenarios and how to run them.
