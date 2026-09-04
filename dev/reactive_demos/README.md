# reactive_demos

Three interactive demos of the signal-based reactive widgets added to this
Flutter fork (`Signal`, `Effect`, `batch`, `ReactiveText`, `ReactiveOffset`,
`ReactiveCustomPaint`, `For`). Each screen runs a `FrameClock`-driven
simulation and shows the build/raster time overlay from
`lib/frame_stats_overlay.dart`.

See `docs/fine_grained_reactivity/BENCHMARKS.md` in the repo root for the
microbenchmark numbers these demos correspond to.

## Demos

- **10,000 sprites** (`lib/sprites_screen.dart`) — one `Signal<Offset>` per
  sprite, each painted by its own `ReactiveOffset`. Every simulation step
  writes all 10,000 positions inside one `batch`, so the frame is one flush;
  each sprite's render object moves without any widget rebuilding.
- **50,000 particles** (`lib/particles_screen.dart`) — one `Float32List` of
  positions and a single `ReactiveCustomPaint`. Mutating the buffer in place
  is invisible to signals, so a `Signal<int>` generation counter is bumped
  once per step and read inside `paint()`, driving one repaint of one render
  object for all 50,000 points.
- **120 Hz counter, 50 levels deep** (`lib/deep_tree_screen.dart`) — a
  `ReactiveText` leaf nested 50 `StatelessWidget` levels deep. The "ancestor
  builds" readout is itself a live `ReactiveText` bound to a signal
  incremented in every ancestor's `build()`: it proves the ancestors rebuild
  exactly once (at mount), not that they merely appeared to.

## Running

This demo is macOS-only today (no `ios`/`android`/`linux`/`windows`
platform folders). Debug-mode numbers are not meaningful for anything
performance-related — use `--profile`:

```sh
cd dev/reactive_demos
../../bin/flutter run -d macos --profile
```

## Building

```sh
cd dev/reactive_demos
../../bin/flutter build macos --debug
```
