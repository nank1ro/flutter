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

### Phase 0 baseline (2026-09-04)

The Phase 0 harness lives in `dev/benchmarks/microbenchmarks/test/reactivity/`,
one file per scenario (`b1_single_sprite_update_test.dart` ...
`b8_mount_unmount_test.dart`, plus a `b9_scene_mode_test.dart` stub — see
below). Each file uses `testWidgets` + a `Stopwatch` around **`tester.pump()`
only** — that is the entire timed region: build, layout, and paint-record,
under the debug-mode JIT with framework asserts on. There is no on-screen GPU
raster under `flutter test`, so the "raster" and "alloc/frame" columns below
are n/a for this baseline; getting real numbers for those needs a
profile-mode run on a physical device via `dev/benchmarks/macrobenchmarks`,
out of scope for this pass. These numbers are for **relative comparison
between baseline and fork only** — they are not representative of
release/profile-mode performance.

Where a scenario names two baselines in BENCHMARKS.md's description (B1, B6),
both are measured: the "best current practice" a careful Flutter dev already
uses (`ValueListenableBuilder` per leaf), and the naive baseline the doc
calls out explicitly (`setState`-on-root / `InheritedWidget`) as the number
the fork's fine-grained update must beat.

**"Baseline" is defined as the numbers recorded at commit `36c235d` (the
`docs: fine-grained reactivity fork plan` commit), before any
`packages/flutter` edits landed.** Re-running the harness under a parent
Flutter SDK checked out elsewhere on disk is not meaningful: this workspace's
`pubspec.yaml` resolves against *this* repo's `packages/flutter`, so a
different SDK binary run against this pubspec is an ill-defined comparison.
Use this fork's own `flutter` binary for every run, baseline and fork alike;
what makes a number "baseline" is the git commit it was measured at, not
which `flutter` binary ran it.

**Machine**: Apple M1, macOS 26.5.1 (build 25F80).
**Flutter**: this fork's own binary, built from commit `36c235d`, engine
`11d79658c444477b06513d32b52c8c4ccb7276b0`, Dart 3.13.1. `packages/flutter`
at this commit only adds `src/foundation/signals.dart` (unused by the
framework yet), so behavior is stable-equivalent.

Run command (from `dev/benchmarks/microbenchmarks`), whole directory or one
file at a time:

```sh
cd dev/benchmarks/microbenchmarks
../../../bin/flutter test test/reactivity/
# or a single scenario:
../../../bin/flutter test test/reactivity/b1_single_sprite_update_test.dart
```

Each number below is the **median of 3 runs' medians**, plus the **min
across those 3 runs**, both rounded to 2 significant figures. Warmup/timed
counts vary by scenario, not a single "20 + 200" protocol: B1/B4/B5/B6
best-practice and fork rows use 20 warmup + 200 timed (their naive/legacy
baselines use 5 warmup + 50 timed); B2 uses 3 warmup + 30 timed; B3 uses 5
warmup + 60 timed; B7 uses 20 warmup + 300 timed; B8's mount/unmount uses 3
warmup + 20 timed pairs — see each file for exact counts. Run-to-run
variance was high (individual-run medians differing by tens of percent),
which is why 3 runs and a min column are reported rather than a single run.

| Scenario | Variant | median (µs/op) | min (µs/op) | pump (ms) | Baseline raster (ms) | Fork build (ms) | Fork raster (ms) | Alloc/frame | Phase | Date |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | `ValueListenableBuilder`, update 1 of 10,000 (best practice) | 8500 | 7700 | 8.5 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B1 | `setState` on root, rebuilds all 10,000 (naive) | 53000 | 42000 | 53 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B2 | `ValueListenableBuilder`, update all 10,000/frame | 74000 | 62000 | 74 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B3 | `CustomPainter`, draw 50,000 particle positions | 540 | 390 | 0.54 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B4 | `ValueListenableBuilder` leaf update, depth 50 | 1200 | 460 | 1.2 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B5 | Deep static tree (depth 100), leaf update, ancestors verified not rebuilt | 1200 | 490 | 1.2 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B6 | `ValueListenableBuilder`, update 1 of 1,000 rows (best practice) | 670 | 610 | 0.67 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B6 | `InheritedWidget`, update 1 row notifies all 1,000 dependents | 7800 | 6300 | 7.8 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B7 | 10x10 Material checkbox grid rebuild | 7900 | 5300 | 7.9 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B8 | Mount 10,000 leaf nodes | 1200000 | 970000 | 1200 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B8 | Unmount 10,000 leaf nodes | 20000 | 13000 | 20 | n/a | — | — | n/a | 0 | 2026-09-04 |
| B9 | n/a — no legacy retained-scene-graph baseline exists; compare fork against B1/B3 rows above | n/a | n/a | n/a | n/a | — | — | n/a | 0 | 2026-09-04 |

B1/B2/B6/B8's sprite/row/node lists are laid out with `mountAllInRows`
(a `Stack` of `Positioned` children), not `ListView(children: ...)`: the
latter's `Sliver` machinery only mounts elements intersecting the viewport
plus cache extent (roughly 850 of 10,000 for B1/B2/B8, a fraction of 1,000
for B6), which would have made every "N sprites/rows/nodes" scenario
actually exercise far fewer than N. Each affected test asserts
`find.byType(Positioned)` equals the full count once, so a future
regression back to partial mounting fails loudly.

Device, Flutter revision, and engine hash for each run go in a footnote under
the row, not in the row itself; see the machine/Flutter block above this
table for Phase 0.

All numbers in this section (Phase 2 and Phase 3) were measured in one idle
session on 2026-09-04; earlier concurrent-run numbers were up to 2x inflated.

### Phase 2: tracked `build()` on every element (2026-09-04)

Same harness, same machine (Apple M1, macOS 26.5.1), same fork binary. The
fork variants live in the same files as their baselines, one `testWidgets` per
variant: B1 gives each sprite its own `Signal<Color>` read in the sprite's own
build (no builder widget, no `BuildContext` dependency), B4 and B5 put a
signal-reading leaf at the bottom of the deep tree, B6 gives each row its own
signal. B7 is unchanged by design and is the A1 regression guard.

**These runs are not comparable to the Phase 0 table above**, and the Phase 0
numbers were not re-used for the comparison. Phase 0 was measured with several
benchmark files running concurrently under `flutter test`, which inflates and
destabilises every number in it (re-running the Phase 0 command here reproduces
that: B6's `ValueListenableBuilder` baseline reads ~3500 µs concurrently and
~640 µs alone). Every number below is from `flutter test -j 1` on **one file at
a time**, and each baseline was re-measured in the same session as the fork
variant it is compared against, on the same build of the framework. Median of
3 runs' medians, plus the min across those 3 runs, in µs per `pump()`.

| Scenario | Variant | median (µs/op) | min (µs/op) | vs baseline |
| --- | --- | --- | --- | --- |
| B1 | `ValueListenableBuilder`, update 1 of 10,000 (best practice) | 6700 | 6400 | — |
| B1 | `setState` on root, rebuilds all 10,000 (naive) | 54000 | 45000 | — |
| B1 | **fork**: `Signal<Color>` read in the sprite's own build | 7600 | 7300 | 0.88x best practice, 7.1x faster than naive |
| B4 | `ValueListenableBuilder` leaf update, depth 50 | 540 | 380 | — |
| B4 | **fork**: signal-reading leaf, depth 50 | 400 | 310 | 1.4x faster |
| B5 | Deep static tree (depth 100), `ValueListenableBuilder` leaf | 520 | 370 | — |
| B5 | **fork**: signal-reading leaf, ancestors verified not rebuilt | 370 | 290 | 1.4x faster |
| B6 | `ValueListenableBuilder`, update 1 of 1,000 rows (best practice) | 640 | 590 | — |
| B6 | `InheritedWidget`, update 1 row notifies all 1,000 | 7300 | 6100 | — |
| B6 | **fork**: `Signal<Color>` per row | 610 | 550 | 1.0x best practice, 12x faster than InheritedWidget |
| B7 | 10x10 Material checkbox grid, **tracking disabled** | 4612 | 3697 | — |
| B7 | 10x10 Material checkbox grid, **tracking enabled** | 4642 | 3710 | +0.7% median, +0.4% min |

**No regression detectable above the ~1% noise floor at n=3.** B7 was
measured as a true A/B on the same working tree: the
`ComponentElement.performRebuild` tracking call was swapped for a plain
`build()` for the first three runs and restored for the next three, so the only
difference between the two rows is the tracking scope. The cost of wrapping
every Material build in a tracking scope that reads no signal is +0.7% on the
median and +0.4% on the min, which is inside this harness's run-to-run spread
(the three medians on each side differ by up to 1%) — this is not proof of
zero cost, only that three runs can't distinguish it from zero. This A/B can
be reproduced directly with the framework's debug toggle
`debugTrackSignalReadsInBuild` (landing in `framework.dart` alongside this
phase's tracking work) instead of hand-editing `performRebuild`. Reactivity
stays default-on.

The same A/B on B8 (one run each): mount 10,000 nodes 1,167,107 µs untracked
against 1,185,740 µs tracked (+1.6%), unmount 19,493 µs against 19,748 µs
(+1.3%). A single run can't separate real cost from noise here — no causal
claim should be drawn from it; a 3-run B8 A/B is future work if this number
matters.

B1 and B6's headline numbers are dominated by laying out and painting a
10,000-child and 1,000-child `Stack`, not by build cost — that's why the
fork lands within noise of the best-practice baseline instead of visibly
beating it on median µs/op. The number that actually demonstrates the
fork's effect is the builder-count assertion in each test
(`expect(_spriteBuilds, timedIterations)` / `expect(_rowBuilds,
timedIterations)`): exactly one element rebuilds per write, against all
10,000/1,000 for the naive baseline. What the fork removes is the wrapper
widget, the builder closure and the opt-in, not the rebuild — both a
`ValueListenableBuilder` leaf and a signal-reading leaf end in exactly one
element rebuild, so they do the same work. Removing the rebuild itself is
Phase 3 (leaf prop bindings), and B1/B6 are the rows that should move then.
B4 and B5 are faster because the baseline's `ValueListenableBuilder` is
itself a `StatefulWidget` whose element rebuilds a child widget, where the
fork's leaf is a single `StatelessWidget`.

### Phase 3: leaf prop bindings (2026-09-04)

Same harness, same machine (Apple M1, macOS 26.5.1), same fork binary, same
protocol as Phase 2: `flutter test -j 1` on one file at a time, median of 3
runs' medians, plus the min across those 3 runs, in µs per `pump()`. Every
baseline in the table was re-measured in the same session as the fork variant
it is compared against; the Phase 0 and Phase 2 numbers were **not** re-used.

The Phase 3 variants live in the same files as their baselines. Each one binds
a `Signal` straight to a render-object setter and asserts two things: that the
render object really took the value (liveness), and that a `_BuildProbe`
`StatelessWidget` sitting above the leaf built **zero** times during the timed
loop. Only render-object elements sit between the probe and the leaf, and a
render-object element cannot be marked dirty on its own, so a probe count of
zero means nothing on the path from the root to the leaf rebuilt.

| Scenario | Variant | median (µs/op) | min (µs/op) | rebuilds/write | vs best practice |
| --- | --- | --- | --- | --- | --- |
| B1 | `ValueListenableBuilder`, update 1 of 10,000 (best practice) | 6700 | 6400 | 1 | — |
| B1 | `setState` on root, rebuilds all 10,000 (naive) | 54000 | 45000 | 10,000 | 0.12x |
| B1 | Phase 2: `Signal<Color>` read in the sprite's own build | 7600 | 7300 | 1 | 0.88x |
| B1 | **Phase 3 leaf**: `ReactiveColoredBox` bound to a `Signal<Color>` | 8500 | 7400 | **0** | 0.79x |
| B2 | `ValueListenableBuilder`, update all 10,000/frame | 53000 | 49000 | 10,000 | — |
| B2 | **Phase 3 leaf**: 10,000 `ReactiveColoredBox`, one batch | 17000 | 17000 | **0** | **3.1x** |
| B2 | **B2 ceiling**: one draw call for 10,000 positions (not the same workload) | 190 | 180 | **0** | see note¹ |
| B3 | `CustomPainter` + `Listenable` repaint, 50,000 particles | 370 | 340 | 0 | — |
| B3 | **Phase 3**: `ReactiveCustomPaint`, one batch, one repaint | 350 | 330 | **0** | ≈1x (parity) |
| B4 | `ValueListenableBuilder` leaf update, depth 50 | 540 | 380 | 1 | — |
| B4 | Phase 2: signal-reading leaf, depth 50 | 400 | 310 | 1 | 1.4x |
| B4 | **Phase 3 leaf**: `ReactiveText` bound to a `Signal<String>`, depth 50 | 290 | 250 | **0** | **1.9x** |
| B8 | Mount 10,000 plain `Container` leaves | 1000000 | 950000 | n/a | — |
| B8 | **Phase 3**: mount 10,000 `ReactiveColoredBox` leaves (owner + effect + edge each) | 730000 | 620000 | n/a | 1.4x |
| B8 | Unmount 10,000 plain `Container` leaves | 17000 | 13000 | n/a | — |
| B8 | **Phase 3**: unmount 10,000 `ReactiveColoredBox` leaves | 9200 | 8300 | n/a | 1.8x |

Refreshed 2026-09-04: median of 3 runs' medians, min across those 3 runs,
both to 2 significant figures, `flutter test -j 1` one file at a time, same
protocol as the rest of this phase.

¹ The B2 ceiling row does one signal write and one repaint for all 10,000
positions, not 10,000 writes like every other B2 row, so a ratio against the
`ValueListenableBuilder` baseline (which does 10,000 writes) compares
different workloads, not the same work done two ways — that ratio is not
reported. The number that is a fair mechanism comparison is against the B2
Phase 3 leaf row directly above it (17,000 µs): 89x, discussed below.

**Read these numbers with the following caveats, which matter more than the
numbers.**

**B1 is dominated by the `Stack`, not by the update.** Ten thousand
`Positioned` children are laid out and painted on every `pump()` regardless of
what changed, and that cost is the entire 7–8 ms. All four B1 variants land
within about 20% of each other because they are all measuring the same
`Stack`. The Phase 3 leaf variant is in fact ~12% *slower* on the median than
the Phase 2 variant, which is the honest result: removing the last remaining
rebuild out of ten thousand elements is not measurable against this
denominator, and 10,000 live `Effect`s cost a little in heap. What Phase 3
changes on B1 is the rebuild count, from 1 to 0, and nothing else. Anyone
reading B1 as "leaf bindings did not help" is reading it correctly, for this
scenario.

**B2 is where the mechanism shows.** When all 10,000 sprites change, the
baseline runs 10,000 builder closures, allocates 10,000 widgets and diffs
10,000 children; the leaf variant runs 10,000 effects, each writing one field
on a render object, all in one batch and one flush. That is 3.1x, and it is a
real difference in what the frame does, not a difference in the constant.

**The B2 ceiling row is the number to remember.** Drawing the same 10,000
positions with one `ReactiveCustomPaint` over a `Float32List` costs 190 µs
against 17,000 µs for one render object per sprite — 89x. Almost all of the
per-sprite cost is the framework's own per-node layout and paint, not the
update mechanism, and no amount of finer-grained invalidation touches it. That
is the gap Phase 4 (scene mode) exists to close, and it is now measured rather
than asserted.

**B3 is a parity result, and that is the point.** The frame is dominated by
writing 100,000 floats and one `drawRawPoints`; the invalidation mechanism is
noise next to it. The table's 350 vs 370 µs (median of 3 runs each) is not a
real win either direction — an earlier single-run measurement on the same
date read 355 vs 367 µs, the two sides swapping which one reads faster
between runs, which is what run-to-run noise at this magnitude looks like.
Read this row as parity: the fork variant replaces the
`CustomPainter`-plus-`Listenable` plumbing with one signal write inside a
batch at no measurable cost, not as a speedup. Batching correctness is
asserted separately: the painter counts its own paints and the test requires
exactly one per frame.

**B4 is the clean win.** A 50-deep tree with a text leaf: 1.9x faster than the
best-practice baseline and 1.4x faster than Phase 2's signal-reading leaf,
with zero rebuilds. There is no large denominator here to hide behind, so the
number is the mechanism.

**B8's two variants are not the same tree.** The plain baseline uses
`Container`, which is a `StatelessWidget` and therefore adds a component
element per node; the fork variant is a `ReactiveColoredBox` over a
`SizedBox`, two render-object elements and no component element, plus an
`Owner`, an `Effect` and a graph edge. The comparison is therefore "does a
reactive leaf cost more to set up and tear down than an ordinary
`Container`?", and the answer is no — it is 1.4x cheaper to mount and 1.8x
cheaper to unmount. It is *not* an isolated measurement of owner and effect
lifecycle cost; that would need two variants with identical tree shapes and is
future work.

**Still not measured here.** Raster time, steady-state heap, and per-frame
allocation, for the same reason as Phase 0 and Phase 2: `flutter test` has no
on-screen GPU raster and these are debug-mode JIT numbers with framework
asserts on. The claim that the game-loop hot path allocates nothing is made
structurally (no closures per frame, integer-microsecond accumulator, intrusive
effect queue) and is not yet backed by an allocation counter. `dev/reactive_demos`
is macOS-only today (no `ios`/`android`/`linux`/`windows` platform folders), so
the run that would settle this is a macOS profile-mode run:
`cd dev/reactive_demos && ../../bin/flutter run -d macos --profile`, using
DevTools' memory view to check per-frame allocation.
