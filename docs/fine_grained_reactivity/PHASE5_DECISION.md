# Phase 5 decision: collapsing Widget and Element

The spike required by [`PLAN.md`](PLAN.md) §Phase 5, option (b) of §4. The
question it exists to answer is narrow and quantitative:

> How much does removing widget allocation and `build()` re-execution add, on
> top of Phase 3's leaf bindings?

**Answer, re-derived on 2026-09-04 from interleaved in-process measurements:
nothing measurable on steady-state updates in UI-shaped trees (0.98x to 1.11x,
i.e. within a couple of percent either way), 1.37x when all ten thousand
sprites change in one batch, and 1.5x to 2.3x on mounting and tearing a tree
down. Recommendation: do not do Phase 5** -- unchanged from the first pass,
but reached from different numbers. The reasoning, the numbers, and what is
worth keeping from the spike anyway are below.

## What was built

`packages/flutter/lib/reactive_nodes.dart`, over
`lib/src/reactive_nodes/nodes.dart` and `node_host.dart`. Nothing else in the
framework changed; no existing file was edited.

- `RNode` — one retained object playing the part of both a `Widget` and an
  `Element`. It owns its `RenderObject`, created once in its constructor, and
  a detached `Owner`. `bind(prop, apply)` creates one `Effect` per property
  writing straight to a render-object setter.
- `Component` = `RNode Function()`, run once by `RComponent` under the node's
  owner. There is no `build()`, so there is nothing to re-run.
- Primitives: `RBox`, `ROffset`, `RPadding`, `ROpacity`, `RRepaintBoundary`,
  `RText`, `RStack` + `RPositioned`.
- Control flow: `RShow` (mounts and disposes one of two subtrees on a boolean
  edge) and `RFor` (keyed reconciliation over a list signal, `keyOf`; an
  unchanged key's node and render object are the same objects as before).
- `NodeHost`, a `LeafRenderObjectWidget` whose `RenderNodeHost`
  (a `RenderProxyBox`) adopts the root node's render object. Layout, painting,
  hit testing and semantics therefore all keep working through the render
  tree, which is the whole difference between this and scene mode.

No keys, because there is no diff. Two render objects are reused from
Phase 3 (`RenderReactiveColoredBox` and `RenderReactiveOffset`).

## Numbers

Same protocol as the rest of [`BENCHMARKS.md`](BENCHMARKS.md): Apple M1, macOS
26.5.1, this fork's own binary, `flutter test -j 1`, one file at a time on an
idle machine, three process runs, six interleaved and rotated rounds per run
with the first two discarded, median of the three run medians, microseconds per
`pump()`. Debug-mode JIT with framework asserts on; no GPU raster.

**Every row below is measured in the same process as the row it is compared
against, and the two trees have the same number of render objects per item.**
That is the difference from the first pass. The Phase 5 variants used to live
in their own file, `b10_collapsed_nodes_test.dart`, and were compared against
Phase 3 rows measured in `b1`..`b8` -- a different process -- while inside each
file the variants ran sequentially, so a variant's position in the file was
worth up to ~2x. `b10` has been deleted and its variants folded into B1, B2,
B4, B5, B6, B8 and B9.

| Workload | best practice | Phase 3 leaf | Phase 5 collapsed | Phase 5 vs Phase 3 |
| --- | --- | --- | --- | --- |
| B1, update 1 of 10,000 sprites | 7005 | 6359 | 6414 | **0.99x** |
| B2, update all 10,000, one batch | 33851 | 16109 | 11743 | **1.37x** |
| B4, text leaf at depth 50 | 318 | 267 | 273 | **0.98x** |
| B5, leaf at depth 100 | 352 | 294 | 297 | **0.99x** |
| B6, update 1 of 1,000 rows | 392 | 375 | 383 | **0.98x** |
| B9, move 1 of 10,000 | n/a | 12695 | 11459 | **1.11x** |
| B9, move all 10,000, one batch | n/a | 42538 | 40677 | **1.05x** |
| B8, mount 10,000 | 737172 | 749281 | 423757 | **1.77x** |
| B8, unmount 10,000 | 4815 | 6673 | 2883 | **2.31x** |
| B9, mount + compose + dispose 10,000 | n/a | 812049 | 532588 | **1.52x** |

Mins and spreads for every row are in [`BENCHMARKS.md`](BENCHMARKS.md). The
spread across the three process runs is 1-14% on every row except B1, where it
is 8-36% and the Phase 3 and Phase 5 medians sit well inside each other's
noise — B1's frame is dominated by laying out and painting ten thousand
`Positioned` children whatever changed, which is also why it is the noisiest
row in the suite.

### Shapes are matched by construction now

The first pass had to correct its own B2 ratio after the fact, because Phase
3's sprite was `Positioned > ReactiveColoredBox > SizedBox` (two render
objects) and the collapsed sprite was `RPositioned > RBox` (one). That
correction is no longer needed: under the tight `Positioned` rows the
`SizedBox` was a no-op and has been deleted, so both sides are one render
object per sprite in B2 and B8, two in B1, B6 and B9, and 51 or 101 in B4 and
B5. The 1.37x measured here and the 1.3x the first pass arrived at by adding a
compensating `RPadding` agree, which is the one place the old method and the
new one confirm each other.

### B4 is not slower any more; it is a tie

The first pass reported B4 at 0.76x -- the collapsed model 24% *slower* on the
row that looks most like real UI -- and spent a section failing to explain it.
There is nothing to explain: it was position in the file. B4's three
near-identical variants read 545 / 408 / 291 us in file order under the old
harness. Interleaved, the same comparison is 267 against 273 us, a 2%
difference with a 2% run-to-run spread. The same correction applies to B5 and
B6, which are also ties.

### Liveness guards

With no build to count, the guards are: the component body must have run
exactly once at the end of the timed loop; the number of property-effect runs
must equal the number of writes (one per write for B1/B4/B5/B6, 10,000 per
frame for B2 and B9's move-all); the render object must hold the last value
written; ancestor property effects must not have run at all (B5, with a
negative check proving the counter can detect ancestor work); and
`signal.subs` must be null after disposing 10,000 nodes (B8, B9).

## Applying the PLAN gate

[`PLAN.md`](PLAN.md) §Phase 5 sets the bar: *"if the answer is single-digit
percent for realistic UI, phase 5 should not happen."*

The realistic-UI rows are the ones with a leaf changing inside an ordinary
tree: B4 (a text leaf at depth 50), B5 (a leaf at depth 100), B6 (one row of a
thousand), B1 (one sprite of ten thousand). The measured answer on all four is
**-2% to -1%** -- single-digit percent, and on the wrong side of zero. The gate
fires, and it fires cleanly: **Phase 5 should not happen.**

Where the collapsed model does win is not realistic UI:

- **1.37x when the entire graph changes in one batch** (B2). Ten thousand
  sprites all changing every frame is a game workload, and Phase 4 serves it
  better -- see below.
- **1.5x to 2.3x on structure** (B8, B9 mount/dispose). Building and tearing
  down a tree is cheaper without widget allocation and element inflation,
  which is exactly what the model predicts. It is also the part of a frame
  budget that a real application spends least time in.

## Against scene mode

The spike's second question is whether the collapsed model is the right way to
spend the remaining per-node cost, given Phase 4 already exists.

Comparing like with like -- **embedded** scene mode against the collapsed
tree, both running a whole framework frame, both measured in the same process
on the same workload:

| Workload | Phase 5 collapsed | Phase 4 scene, embedded | Scene vs collapsed |
| --- | --- | --- | --- |
| move 1 of 10,000 | 11459 | 4815 | **2.38x** |
| move all 10,000, one batch | 40677 | 7591 | **5.36x** |

And separately, the **headless** scene -- the scene's own frame work with no
framework frame around it, which is what a standalone game runs, and which is
*not* a like-for-like comparison against a `pump()`:

| Workload | Phase 5 collapsed | Phase 4 scene, headless | Scene vs collapsed |
| --- | --- | --- | --- |
| move 1 of 10,000 | 11459 | 1818 | 6.30x |
| move all 10,000, one batch | 40677 | 5471 | 7.43x |
| mount + compose + dispose 10,000 | 532588 | 41848 | 12.7x |

Scene mode beats the collapsed model on every workload either way, by 2.4x to
5.4x on the honest embedded comparison. It is additive, contained, opt-in, and
already built. Spending months to capture a fraction of a gap that an existing
feature already closes is a poor trade.

*A ratio that used to appear here has been withdrawn.* The first pass compared
B2's single-draw-call ceiling row (176 us) against the collapsed tree (11,743
us) and published "50x". Those are different workloads -- one signal write and
one repaint against ten thousand writes into ten thousand render objects -- so
the ratio compares nothing. The ceiling row is still measured and still worth
looking at for scale, and [`BENCHMARKS.md`](BENCHMARKS.md) reports it without
a ratio. The properly matched evidence for the same claim is the scene-mode
table above.

## Recommendation: do not do Phase 5

Unchanged from the first pass. The numbers behind it changed; the direction did
not. Three reasons, in order of weight.

**1. There is no win to collect on realistic UI.** Not "a small win" -- none:
0.98x to 0.99x on B4, B5 and B6, and 0.99x on B1, all inside the run-to-run
spread. The `PLAN.md` gate asks whether the answer is single-digit percent for
realistic UI. It is, and it is negative. The wins that exist are 1.37x on an
all-ten-thousand-sprites batch and 1.5-2.3x on mount and teardown, which is not
what "removing `build()` re-execution" was supposed to be worth.

**2. It attacks the wrong cost.** The collapsed model removes the widget and
the element and keeps the render object, and the render object is where nearly
all of the remaining per-node cost is. Phase 4 removes all three, is 2.4x to
5.4x faster than the collapsed model on the same embedded comparison, and
already exists.

**3. The cost is the whole of Material and Cupertino, and it is
irreversible.** A full migration means:

- **Material and Cupertino.** Tens of thousands of lines written against
  re-execution: `State`, `setState`, `didUpdateWidget`, implicit animations,
  `AnimatedBuilder`, every `builder:` parameter. Each one needs a
  runs-once equivalent. This is the bulk of the work and there is no partial
  version of it -- a `Scaffold` that still rebuilds cannot host a node subtree
  without a `NodeHost` boundary at every seam.
- **Keys and `GlobalKey`.** Both exist to steer a diff. There is no diff, so
  `Key` simply disappears (`RFor.keyOf` is a list identity, not a `Key`), and
  `GlobalKey` -- reparenting, `context` access from outside, `currentState` --
  has no replacement in this model at all. Every `Form`, `Navigator` and
  `ScaffoldMessenger` API that hands out a `GlobalKey` would need redesigning.
- **`BuildContext`.** A node has none, so `InheritedWidget`, `Theme.of`,
  `MediaQuery.of`, `Directionality`, `Localizations` and `DefaultTextStyle`
  are unreachable from inside a node. The spike passes them in explicitly
  (`RText` takes a `TextDirection`; the B4 and B5 benchmarks hand the ambient
  text style in from a `Builder`). At framework scale that means either a
  parallel context mechanism or threading every ambient value through every
  constructor.
- **Hot reload.** `PLAN.md` §6 already calls this a gating question and the
  spike does nothing to soften it: reload works today by re-running `build`,
  and there is no `build`. A reloaded component body never runs again, so a
  changed closure never takes effect. SolidJS solves this with a bundler-level
  HMR protocol that re-creates component instances; Flutter has no equivalent
  and building one is a tools project, not a framework one.
- **The inspector.** The widget inspector walks the element tree and counts
  rebuilds. A node tree has neither, so an app built this way is a single
  `NodeHost` leaf in DevTools -- the same problem `SCENE_MODE.md` records for
  scene mode, but this time for the *entire* application rather than for an
  opt-in scene.

The fork's identity therefore stays where Phase 3 and Phase 4 put it:
**the classic tree with fine-grained leaf bindings, plus scene mode for
games.** That is a defensible place to stop, and it is where the measurements
say the value is.

## What is worth keeping regardless

- **Component-once semantics for effects.** This is the real result of the
  spike, and it is not about performance. Phase 2 documented a divergence from
  SolidJS: an effect created in `build` is disposed and re-created on every
  rebuild, so it is per-*build*, not per-*instance*, and the only per-instance
  place to put one is `State.initState`. `RComponent` shows what the fix looks
  like — a body that runs once under the instance's own owner — and
  `test/reactive_nodes/nodes_test.dart` asserts it directly: two instances,
  two effect runs at creation, one run each per write, and disposing one
  instance stops only that one. A `Component`-style widget whose body runs once
  under `Element.reactiveOwner` could be offered in the classic tree with none
  of Phase 5's cost, and would close the divergence properly.
- **`RPositioned`'s rule that layout inputs are not props.** Binding a
  position that is written into a parent's parent data means relayouting the
  whole stack on every write. The node model makes this obvious by forcing the
  choice at the constructor; the same discipline applies to Phase 3's reactive
  widgets, where `ReactiveOffset` is the paint-only answer.
- **The measurement that a render object is the expensive part.** The
  collapsed model removes the widget and the element and changes nothing
  measurable on a UI-shaped update, while scene mode removes the render object
  too and is 2.4x to 5.4x faster on the same embedded comparison. Any future
  performance work should remove render objects, not the layers above them.
  That is Phase 4, and it is already built.
- **`NodeHost` as a pattern.** A `LeafRenderObjectWidget` that adopts a render
  object built outside the element tree is a cheap way to embed anything —
  a node tree, a generated subtree, a foreign layout — while keeping hit
  testing and semantics. It is 40 lines and needs no framework change.

## Status

The spike is complete and stays in the tree as a measurement artefact and as
the reference implementation of component-once semantics. It is not a
supported API, it is not exported from `widgets.dart`, and nothing else in the
framework depends on it.
