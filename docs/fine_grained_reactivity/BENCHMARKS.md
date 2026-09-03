# Benchmarks

Every phase of the plan is judged by these numbers. Nothing lands without a
before/after run, and the baseline must be measured on unmodified stable
before the first framework edit (Phase 0).

## Rules

- Profile mode on a physical device. Debug-mode timings are meaningless.
- Measure on the same device, plugged in, at a fixed refresh rate, three runs,
  report the median.
- Record frame build time and frame raster time separately. A change that
  moves work from build to raster is not an improvement.
- Record steady-state heap and per-frame allocation. A reactive system that
  allocates per frame will lose on a 120 Hz target regardless of its build
  time.

## Scenarios

| ID | Scenario | What it isolates |
| --- | --- | --- |
| B1 | 10,000 sprites, one signal per sprite, one sprite mutated per frame | Update cost independent of tree size. Baseline `setState` rebuilds the list; the target is a single render-object setter. |
| B2 | 10,000 sprites, all mutated every frame | Throughput of the propagate/flush path when the dirty set is the whole graph. |
| B3 | Particle field, 50,000 particles, position written every frame in one batch | Allocation in the hot path, and batching correctness. |
| B4 | 120 Hz counter: one text leaf updated every frame in a deep tree (depth 50) | Whether tree depth still costs anything once reactivity is leaf-level. |
| B5 | Deep static tree (depth 100), single leaf signal changes | Regression guard: no ancestor may rebuild. |
| B6 | Wide list, 1,000 rows, one row's colour changes | Comparison against `InheritedWidget` dependency notification. |
| B7 | Existing `bench_build_material_checkbox` from macrobenchmarks | Compatibility cost: the reactive `Element` must not slow down ordinary Material builds. |
| B8 | Mount and unmount 10,000 nodes | Owner/effect lifecycle overhead, and the disposal path. |
| B9 | Scene mode: B1 and B3 re-run against the retained scene graph | The payoff of skipping widgets, elements, and render objects. |

B7 is the guard that matters most politically inside the fork: the whole
premise is that per-element tracking costs nothing when no signal is read.

## Running

Microbenchmarks (build and propagate cost, no device required):

```sh
cd dev/benchmarks/microbenchmarks
../../../bin/flutter run --profile -d macos lib/foundation/signals_bench.dart
```

Macrobenchmarks (frame timings on a device):

```sh
cd dev/benchmarks/macrobenchmarks
../../../bin/flutter run --profile -d <device-id>
```

New scenarios are added as `WidgetRecorder` / `WidgetBuildRecorder` subclasses
alongside the existing recorders (see `SOURCE_MAP.md` for their locations).
The existing checkbox benchmark is the template.

Framework correctness while benchmarking:

```sh
cd packages/flutter && ../../bin/flutter test test/widgets/framework_test.dart
```

## Results

Baseline is unmeasured. Fill this in from Phase 0 before any framework edit,
then add one row per phase.

| Scenario | Baseline build (ms) | Baseline raster (ms) | Fork build (ms) | Fork raster (ms) | Alloc/frame | Phase | Date |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | TBD | TBD | — | — | — | — | — |
| B2 | TBD | TBD | — | — | — | — | — |
| B3 | TBD | TBD | — | — | — | — | — |
| B4 | TBD | TBD | — | — | — | — | — |
| B5 | TBD | TBD | — | — | — | — | — |
| B6 | TBD | TBD | — | — | — | — | — |
| B7 | TBD | TBD | — | — | — | — | — |
| B8 | TBD | TBD | — | — | — | — | — |
| B9 | n/a | n/a | — | — | — | — | — |

Device, Flutter revision, and engine hash for each run go in a footnote under
the row, not in the row itself.
