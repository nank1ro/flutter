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
| B9 | Scene mode: move-one, move-all, particles and mount/dispose, each against the matched Phase 3 leaf and Phase 5 collapsed variants in the same process | The payoff of skipping widgets, elements, and render objects. |

B7 is the guard that matters most politically inside the fork: the whole
premise is that per-element tracking costs nothing when no signal is read.

## Running

The B1-B9 harness (build, layout and paint-record cost, no device required).
One file per scenario, every variant of that scenario inside it, run one file
at a time with `-j 1`:

```sh
cd dev/benchmarks/microbenchmarks
../../../bin/flutter test -j 1 test/reactivity/b1_single_sprite_update_test.dart
```

The signal-core microbenchmark (no widgets):

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

All numbers below come from one measurement pass on 2026-09-04. They replace
every earlier per-phase table in this document; see **History** at the end for
why the earlier numbers are not comparable and are not reproduced.

### Methodology

**The harness.** `dev/benchmarks/microbenchmarks/test/reactivity/` holds one
file per scenario, B1-B9, over a shared harness in
`reactivity_bench_common.dart`. Every variant of a scenario -- the
best-practice baseline, the naive baseline, Phase 2's signal-in-build, Phase
3's leaf binding, Phase 5's collapsed node tree, and Phase 4's scene where it
applies -- lives in that one file and runs in that one process.

**Variants are interleaved, not sequential.** A variant is a function that
mounts its own tree, runs its own warmup and timed iterations, drops the tree
again, and returns the median of the timed iterations. `runInterleaved` runs
every variant once per round for **R = 6 rounds**, starting round `r` at
variant `r % n` and wrapping, and **discards the first D = 2 rounds**. What is
reported per process run is the median across the remaining rounds, the min
across them, and the raw per-round values.

This is the correction that made the pass necessary. The Dart VM's JIT warms
up across a file, and the old harness ran each variant once, in file order:
position in the file was worth up to ~2x. B4's three near-identical variants
read 545 / 408 / 291 us purely in that order, and the old "B4 collapsed is
0.76x, i.e. slower" result reverses to parity once the order is controlled.
The drift is still visible in the raw rounds -- B4's first round runs ~2.5x
its last -- but it now falls on every variant equally.

**Protocol.** Apple M1, macOS 26.5.1, this fork's own binary, debug-mode JIT
with framework asserts on. `../../../bin/flutter test -j 1`, **one file at a
time**, **3 process runs per file**, on an otherwise idle machine (no other
test run in flight; an editor and two agent sessions were resident). Reported
below: the **median of the 3 process runs' medians**, the **min across their
mins**, and the **spread**, `(max - min) / min` over the three run medians.

```sh
cd dev/benchmarks/microbenchmarks
../../../bin/flutter test -j 1 test/reactivity/b1_single_sprite_update_test.dart
```

**Shape matching.** Variants of a scenario have the same number of render
objects per sprite / row / node, so a ratio is a ratio of mechanisms and not
of tree sizes. Under the tight `Positioned` rows of `mountAllInRows` a child
needs no `SizedBox` of its own, so the no-op `SizedBox` that used to sit under
the reactive leaves is gone. Per-scenario counts:

| Scenario | Classic shape | Collapsed shape | Render objects per item |
| --- | --- | --- | --- |
| B1 | `Positioned > RepaintBoundary > (Reactive)ColoredBox` | `RPositioned > RRepaintBoundary > RBox` | 2 |
| B2 | `Positioned > (Reactive)ColoredBox` | `RPositioned > RBox` | 1 |
| B3 | one `(Reactive)CustomPaint` | n/a (`RCustomPaint` was removed) | 1 |
| B4 | 50 x `Padding` + text leaf | 50 x `RPadding` + `RText` | 51 |
| B5 | 100 x counting widget wrapping `Padding` + text leaf | 100 x `RPadding` + `RText` | 101 |
| B6 | `Positioned > RepaintBoundary > (Reactive)ColoredBox` | `RPositioned > RRepaintBoundary > RBox` | 2 |
| B7 | 10x10 Material checkbox grid, identical in both variants | n/a | identical |
| B8 | `Positioned > (Reactive)ColoredBox` | `RPositioned > RBox` | 1 |
| B9 | `Positioned > ReactiveOffset > ColoredBox` | `RPositioned > ROffset > RBox` | 2 (scene: none) |

Element counts cannot be matched and are the mechanism, not the shape: a
`ValueListenableBuilder` adds a `StatefulElement` per item, Phase 2 a
`StatelessElement`, Phase 3 and Phase 5 none. The collapsed variants also add
one `NodeHost` render object for the whole tree, and B9's scene has no render
objects at all, which is the point of it.

**Liveness.** Every variant asserts that it did the work it claims. Classic
variants count builds (`expect(buildCount, kTimed)`) or assert a `_BuildProbe`
above the leaf built **zero** times; leaf and collapsed variants additionally
assert the render object holds the last value written; collapsed variants
assert the component body ran exactly once and that property effects ran once
per write; B5 asserts no ancestor rebuilt or re-ran its binding, with two
negative checks proving both counters can detect ancestor work; B8 asserts
`signal.subs` is null after teardown; B9 asserts `debugRecordCount == 1` for
all ten thousand scene nodes after a move loop.

**What is still not measured.** Raster time, steady-state heap, and per-frame
allocation. `flutter test` has no on-screen GPU raster and these are debug-mode
JIT numbers with framework asserts on. They are for **relative comparison
between variants measured in the same process**, and are not representative of
release or profile mode.

### The table

Median and min in microseconds per `pump()` (per composed frame for the scene's
headless rows). "vs" is against the row marked `--` in the same scenario, and
every ratio on this page is computed from two rows of this table.

| Scenario | Variant | median | min | spread | vs |
| --- | --- | --- | --- | --- | --- |
| B1 | `ValueListenableBuilder`, 1 of 10,000 (best practice) | 7005 | 5546 | 24% | -- |
| B1 | `setState` on root, rebuilds all 10,000 (naive) | 42163 | 40732 | 1% | 0.17x |
| B1 | Phase 2: `Signal<Color>` read in the sprite's build | 7006 | 5279 | 36% | 1.00x |
| B1 | Phase 3 leaf: `ReactiveColoredBox` bound to the signal | 6359 | 5547 | 8% | 1.10x |
| B1 | Phase 5 collapsed: `RBox` | 6414 | 4619 | 25% | 1.09x |
| B2 | `ValueListenableBuilder`, all 10,000/frame (best practice) | 33851 | 33408 | 1% | -- |
| B2 | Phase 2: signal per sprite, one batch | 35759 | 34534 | 4% | 0.95x |
| B2 | Phase 3 leaf: 10,000 `ReactiveColoredBox`, one batch | 16109 | 15508 | 3% | 2.10x |
| B2 | Phase 5 collapsed: 10,000 `RBox`, one batch | 11743 | 11036 | 5% | 2.88x |
| B2 | **ceiling, different workload**: one `ReactiveCustomPaint`, one write | 176 | 170 | 7% | no ratio¹ |
| B3 | `CustomPainter` + `Listenable`, 50,000 particles (best practice) | 332 | 313 | 1% | -- |
| B3 | Phase 3: `ReactiveCustomPaint`, one batch | 340 | 329 | 2% | 0.98x |
| B4 | `ValueListenableBuilder` leaf, depth 50 (best practice) | 318 | 284 | 1% | -- |
| B4 | Phase 2: signal-reading leaf | 322 | 300 | 1% | 0.99x |
| B4 | Phase 3 leaf: `ReactiveText` | 267 | 253 | 2% | 1.19x |
| B4 | Phase 5 collapsed: `RText` | 273 | 230 | 2% | 1.16x |
| B5 | `ValueListenableBuilder` leaf, depth 100 (best practice) | 352 | 310 | 1% | -- |
| B5 | Phase 2: signal-reading leaf | 355 | 310 | 2% | 0.99x |
| B5 | Phase 3 leaf: `ReactiveText` | 294 | 275 | 3% | 1.20x |
| B5 | Phase 5 collapsed: `RText` | 297 | 250 | 1% | 1.19x |
| B6 | `ValueListenableBuilder`, 1 of 1,000 rows (best practice) | 392 | 363 | 6% | -- |
| B6 | `InheritedWidget`, 1 row notifies all 1,000 (naive) | 4214 | 3992 | 0% | 0.09x |
| B6 | Phase 2: `Signal<Color>` per row | 387 | 350 | 10% | 1.01x |
| B6 | Phase 3 leaf: `ReactiveColoredBox` | 375 | 350 | 6% | 1.05x |
| B6 | Phase 5 collapsed: `RBox` | 383 | 362 | 3% | 1.02x |
| B7 | Material checkbox grid, tracking **off** | 4198 | 3992 | 7% | -- |
| B7 | Material checkbox grid, tracking **on** | 4142 | 4000 | 8% | 1.01x² |
| B8 | Mount 10,000 plain `ColoredBox` leaves | 737172 | 730751 | 1% | -- |
| B8 | Mount 10,000 `ReactiveColoredBox` leaves (Phase 3) | 749281 | 715866 | 2% | 0.98x |
| B8 | Mount 10,000 `RBox` nodes (Phase 5) | 423757 | 368600 | 5% | 1.74x |
| B8 | Unmount 10,000 plain `ColoredBox` leaves | 4815 | 4512 | 7% | -- |
| B8 | Unmount 10,000 `ReactiveColoredBox` leaves (Phase 3) | 6673 | 5856 | 12% | 0.72x |
| B8 | Unmount 10,000 `RBox` nodes (Phase 5) | 2883 | 2144 | 6% | 1.67x |
| B9 move 1 of 10,000 | Phase 3 leaf: `ReactiveOffset` | 12695 | 11451 | 3% | -- |
| B9 move 1 of 10,000 | Phase 5 collapsed: `ROffset` | 11459 | 10378 | 14% | 1.11x |
| B9 move 1 of 10,000 | Phase 4 scene, **embedded** | 4815 | 4432 | 5% | 2.64x |
| B9 move 1 of 10,000 | Phase 4 scene, **headless**³ | 1818 | 1476 | 24% | 6.98x |
| B9 move all 10,000 | Phase 3 leaf: `ReactiveOffset`, one batch | 42538 | 38496 | 5% | -- |
| B9 move all 10,000 | Phase 5 collapsed: `ROffset`, one batch | 40677 | 35604 | 5% | 1.05x |
| B9 move all 10,000 | Phase 4 scene, **embedded** | 7591 | 6690 | 4% | 5.60x |
| B9 move all 10,000 | Phase 4 scene, **headless**³ | 5471 | 3909 | 18% | 7.78x |
| B9 particles | Phase 3: `ReactiveCustomPaint`, 50,000 points | 234 | 228 | 2% | -- |
| B9 particles | Phase 4 scene, **headless**³: one `PictureNode` | 117 | 115 | 0% | 2.00x |
| B9 mount+dispose | Phase 3: 10,000 `ReactiveOffset` leaves | 812049 | 784277 | 4% | -- |
| B9 mount+dispose | Phase 5: 10,000 `ROffset` nodes | 532588 | 512580 | 1% | 1.52x |
| B9 mount+dispose | Phase 4 scene, **headless**³ | 41848 | 36233 | 2% | 19.4x |

¹ The B2 ceiling row does **one** signal write and one repaint for all 10,000
positions, where every other B2 row does 10,000 writes into 10,000 render
objects. It is a different workload, so no ratio against any other row is
reported -- not against the baseline, and not against the Phase 3 or Phase 5
rows either. What it is good for is scale: one draw call for the same pixels
costs 176 us where ten thousand render objects cost 11,743-33,851 us, which
says the per-node cost is the framework's own layout and paint and not the
update mechanism. That observation is the case for Phase 4, and Phase 4's own
rows in B9 measure it properly, on the same workload.

² B7's two rows are the same tree and the same workload; the only difference
is `debugTrackSignalReadsInBuild`. Tracking-on reads 1.3% *faster* on the
median and 0.2% slower on the min -- the sign flips between the two statistics,
which is what "no effect the harness can resolve" looks like. **No regression
detectable above the ~7% run-to-run spread at n=3.** This is not proof of zero
cost; it is proof that three runs cannot distinguish it from zero.

³ Headless scene rows are the scene's own frame work only -- `flushSignals`
plus `composeFrame` onto a real `ui.SceneBuilder` -- with no framework frame
around them. They are **not** comparable with the classic rows, which include
a whole `pump()`. The row that is comparable is the embedded one. Both are
reported because headless is what standalone game mode actually runs.

### What the table says

**Phase 2 is parity, everywhere.** 0.95x to 1.01x against the best-practice
baseline on B1, B2, B4, B5 and B6. Both a `ValueListenableBuilder` leaf and a
signal-reading leaf end in exactly one element rebuild, so they do the same
work; what Phase 2 removes is the wrapper widget, the builder closure and the
opt-in, not the rebuild. The earlier claim that Phase 2 was 1.4x faster on
B4/B5 was a position artefact and does not survive interleaving.

**Phase 3 wins where there is no large denominator, and wins big when
everything changes.** 1.19x/1.20x on B4/B5 (a text leaf in a deep tree, with
zero rebuilds), and 2.10x on B2, where the baseline runs 10,000 builder
closures and allocates 10,000 widgets while the leaf variant runs 10,000
effects that each write one render-object field. On B1 and B6, where the frame
is dominated by laying out and painting 10,000 (or 1,000) `Positioned`
children whatever changed, it is 1.10x and 1.05x -- real but small. B3 is
parity, which is a pass: the frame is 100,000 floats and one `drawRawPoints`,
and the invalidation mechanism is noise beside it.

**Phase 3 leaves cost slightly more to mount and tear down than plain ones.**
0.98x mount and 0.72x unmount against a plain `ColoredBox` -- an owner, an
effect and a graph edge per leaf are not free. The earlier "1.4x cheaper to
mount, 1.8x cheaper to unmount" was a shape artefact: the old baseline used
`Container`, a `StatelessWidget` that adds a component element per node, so it
was measuring one extra element and not the effect machinery. With the shapes
matched, leaf bindings cost about 2% on mount and about 39% on unmount.

**Phase 5 is parity on steady-state UI-shaped updates and a real win on
structure.** 0.98x-1.11x on B1, B4, B5, B6 and B9's move rows; 1.37x on B2's
all-at-once batch (11,743 against 16,109); 1.77x mount, 2.31x unmount, 1.52x
mount-and-dispose (1.74x mount and 1.67x unmount vs plain ColoredBox). See [`PHASE5_DECISION.md`](PHASE5_DECISION.md).

**Scene mode is the largest effect measured here, and it already exists.**
Embedded -- a like-for-like comparison, whole framework frame on both sides --
it is 2.64x Phase 3 on moving one of ten thousand and 5.60x on moving all ten
thousand, and 19.4x on mounting and disposing ten thousand. Removing the
render object is worth more than removing the widget and the element.

## History

Earlier revisions of this document published per-phase tables (Phase 0, Phase
2, Phase 3), and `SCENE_MODE.md` and `PHASE5_DECISION.md` published tables
derived from them. **Every ratio in those tables was confounded by
position-in-file** and they are superseded by the single table above. Two
faults:

- Within a file, variants ran sequentially in one process, so a variant's
  position in the file was worth up to ~2x on its own. B4's three
  near-identical variants read 545 / 408 / 291 us in file order.
- Comparisons *between* files -- the Phase 5 spike lived in its own
  `b10_collapsed_nodes_test.dart` and was compared against Phase 3 rows
  measured in `b1`..`b8` -- were comparisons between different processes.

`b10_collapsed_nodes_test.dart` has been deleted; its variants are folded into
B1, B2, B4, B5, B6, B8 and B9, which is why every Phase 5 ratio on this page
is now in-process. Some conclusions survived the correction (Phase 3's B2 win,
scene mode's advantage, the Phase 5 recommendation); several did not (Phase
2's B4/B5 "1.4x", Phase 3's B8 mount/unmount "win", Phase 5's B4 "0.76x
slower").
