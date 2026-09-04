# Scene mode

Phase 4 of [`PLAN.md`](PLAN.md), section 4 option (c): a retained scene graph
driven entirely by signals, with **no widget, element or render object per
node**. It renders through `dart:ui` and coexists with the classic tree.

Library: `package:flutter/reactive_scene.dart`
(`packages/flutter/lib/src/reactive_scene/`).

Everything here is additive. Nothing in the framework changed to make it work.

## 1. The model

A `SceneNode` is a plain object. It holds reactive properties, its own
`ui.Picture`, and exactly two subscribers into the signal graph, both owned by a
detached `Owner` and released by `dispose()`:

| Subscriber | Reads | On change |
| --- | --- | --- |
| an `Effect` | `x`, `y`, `rotation`, `scale`, `opacity`, `visible` | caches them into fields, asks the scene for a frame |
| a `TrackingNode` | whatever the node's picture was recorded from | marks the node **picture dirty** |

There is one dirty flag per node, not two. Moving a node changes only the
arguments the compositor is called with, and the composition walk is
unconditional, so nothing needs to remember *which* nodes moved — the write just
asks for a frame. Changing what a node *draws* marks it picture dirty, and that
flag is load-bearing: it is what stops the walk re-recording every node.

Every property has type `T Function()`, which a `Signal` satisfies directly:

```dart
final Signal<double> x = Signal<double>(0);
final RectNode ship = RectNode(
  x: x,                             // a callable Signal, no closure
  y: () => baseY.value + bob.value, // or any derived expression
  color: () => Colors.white,
  width: () => 16,
  height: () => 16,
);
final ReactiveScene scene = ReactiveScene(GroupNode(children: <SceneNode>[ship]));
```

(Passing the signal itself works because `Signal` is callable; the fork drops
Flutter's `implicit_call_tearoffs` lint, which would otherwise demand an
explicit `x.call` at every prop site. Some of this fork's own tests still write
`.call`, which is equivalent.)

### Node types

| Node | Draws | Reactive |
| --- | --- | --- |
| `RectNode` | a filled rectangle | colour, width, height |
| `CircleNode` | a filled circle | colour, radius |
| `SpriteNode` | a `ui.Image`, optional source rect, optional tint | image, source rect, tint |
| `PictureNode` | whatever a `void Function(Canvas)` draws | anything the painter reads |
| `TextNode` | one `ui.Paragraph` | string, font size, colour |
| `GroupNode` | its children, in order | — |
| `GroupNode.reactive` | its children, from a `List<SceneNode> Function()` | the list |

`GroupNode.reactive` is scene mode's `For`. Node identity is the key: when the
list signal changes, nodes that stayed are not touched, nodes that arrived are
attached, nodes that left are **disposed**. Reordering the same nodes costs one
scan of the list.

Disposal of a node that left is deferred to the start of the next frame, and
happens only if the node is still parentless then. That is what makes moving a
node from one reactive group to another inside one `batch` work: the group that
lost it puts it on the scene's orphan list, the group that gained it claims it,
and the next frame finds it has a parent and leaves it alone.

A node belongs to **at most one group**. Adding a node that already has a parent
asserts and is ignored, in both the reactive and the static form, because
composing the same node twice in a frame would hand the engine the same
`oldLayer` twice, which `dart:ui` forbids.

`PictureNode` is the escape hatch and the fast path for a crowd: fifty thousand
particles are one node whose painter reads one `Signal<Float32List>`, not fifty
thousand nodes.

## 2. Composition and retention

One walk per frame, over the whole tree. The walk reads **no signals** (only the
cached fields) and allocates nothing of its own, so it is the same cost whether
one node moved or all of them did. The one allocation per composed node is a
`ui.Offset`, which `SceneBuilder.addPicture` requires and which is why
`SceneCompositor.addPicture` takes two doubles rather than an `Offset` — sinks
that do not need one (the canvas sink) never build one. The work that scales
with what changed is the recording, and only dirty nodes record.

The walk carries an accumulated translation `(tx, ty)` and a flag saying whether
that translation is the whole story. That has two consequences.

**Translation is free.** A node that only moves pushes no layer at all: its
picture is added at `(tx, ty)`. This was measured, not assumed. The first
implementation here pushed a `SceneBuilder.pushOffset` layer per node — an
obvious way to express "this node sits here", and not something `PLAN.md` asked
for; the plan's Phase 4 sketch names `pushTransform`, `pushOpacity` and
`addPicture` only. At ten thousand nodes the offset layer cost **15,200 µs** per
frame against **2,500 µs** for adding the pictures at an offset, measured
against each other in the same session — a 6x difference, and the single largest thing in the frame. Ten thousand engine
layers per frame is the wrong shape. `SceneCompositor` therefore has no
`pushOffset`.

**Culling is two additions and four comparisons.** Set `ReactiveScene.cullRect`
and a node outside it is neither composed nor, if it has never been recorded,
recorded. Culling applies only under an unrotated, unscaled ancestor chain,
which is the case for a camera that pans.

What *is* retained, and what is not:

| Thing | Retained across frames? |
| --- | --- |
| a node's `ui.Picture` | **yes** — re-recorded only when a property the recording read changes |
| a node's `TransformEngineLayer` / `OpacityEngineLayer` | **yes**, in standalone mode: handed back as `oldLayer`, so the engine reuses its resources |
| offset layers | **do not exist**; folded into `addPicture` |
| the walk itself | **no** — O(nodes) push/add/pop calls every frame |
| the framework layer tree | **not used**; scene mode does not build `Layer` objects |

The walk not being retained is the honest limit of this design. `addRetained`,
which would let an unchanged subtree cost one call, needs a persistent
`EngineLayer` per subtree and a `_needsAddToScene`-style dirty propagation — that
is what `rendering/layer.dart` already is. Scene mode deliberately does not
rebuild that, because at roughly 0.15 µs per node per frame (§6: 1500
µs to walk ten thousand nodes) the walk is not the problem the fork exists to
solve.

## 3. Two embeddings

**Standalone** — `scene.attachToView(view)`. Takes over
`PlatformDispatcher.onBeginFrame`, `onDrawFrame` and `onPointerDataPacket`,
installs `signalFlushScheduler = scheduleFrame`, and each frame runs `onTick`
inside one `batch`, then `flushSignals()`, then composes onto a `ui.SceneBuilder`
and calls `FlutterView.render`. No `WidgetsBinding` exists. This is the "no tree"
ceiling.

The loop lives in `SceneDriver`, whose `renderFrame` is injected, so the frame
logic is testable and benchmarkable without a view.

**Embedded** — `SceneView(scene: scene)`, a `LeafRenderObjectWidget`.
`RenderSceneView` is a repaint boundary that fills its constraints (bounded
constraints are asserted: an infinite size would mean an infinite cull
rectangle) and composes the scene into `PaintingContext.canvas`. When any node
becomes dirty the scene calls `markNeedsPaint` on every view showing it — a
scene may have more than one.

`RenderSceneView.paint` does **not** flush signals. Embedded mode relies on the
signal flush `WidgetsBinding.drawFrame` already performs before the build phase:
a write made before that flush repaints in the *same* frame, and a write made
after it — from a layout callback, or from another render object's paint — is
composed one frame late. Standalone mode has no such window: `SceneDriver`
calls `flushSignals()` itself, immediately before composing.

The embedded path uses a `ui.Canvas` sink rather than per-node framework
`Layer`s. The alternative — one `PictureLayer`/`TransformLayer` per node,
mirroring the scene into the framework layer tree — would buy engine-side
retention of clean subtrees at the price of one framework object per node, a
`markNeedsAddToScene` walk up the tree per dirty node, and an
`updateSubtreeNeedsAddToScene` walk down it per frame. That is a render tree with
extra steps, and scene mode exists not to have one. An unchanged node therefore
costs one `drawPicture` of the picture it already has: it is re-added, never
re-recorded.

Neither embedding reports untracked signal reads during a frame. The walk reads
only cached fields, and re-recording happens inside the node's own tracking
scope, so `debugSignalReadOutsideTracking` stays quiet by construction rather
than by suppression.

## 4. Input, and the game loop

`ReactiveScene.hitTest(Offset)` returns the top-most node whose bounds contain
the point, walking children back to front and inverting each node's
translate/rotate/scale analytically. It is a linear scan; the source carries a
`// ponytail:` note naming the upgrade path (a uniform grid or loose quadtree
over the same bounds, with no API change).

`SceneNode.onPointerEvent` is called for the node the event lands on. There is no
capture and no gesture arena: a drag that leaves a node stops being delivered to
it, and recognising a tap is the caller's job. Standalone mode expands raw
`PointerDataPacket`s with the framework's own `PointerEventConverter`; embedded
mode arrives through `RenderSceneView.hitTestSelf` and `handleEvent`.

There is no `SceneClock`. Phase 3's `FrameClock`
(`widgets/frame_clock.dart`, with `time`, `frame` and `alpha` signals and a
fixed-timestep accumulator) already does this, and works unchanged with a scene:
its writes are inside `batch`, and the scene's dirty flags are set by the same
flush. Standalone mode's `SceneDriver.onTick` is the equivalent hook for a scene
with no binding.

## 5. What you give up

Stated plainly, because scene mode is not a general UI replacement and should
never be sold as one.

- **Semantics and accessibility.** A scene is one opaque box. `RenderSceneView`
  contributes no semantics node per scene node, and there is no plan to.
- **Focus and text input.** These are widget-layer concepts built on
  `InheritedWidget`. They do not exist below it.
- **Hit testing quality.** Axis-aligned bounds, linear scan, no capture, no
  arena, no `MouseRegion`, no hover.
- **Text.** `TextNode` is one paragraph with a string, a size and a colour. No
  `TextSpan`, no rich text, no selection, no `TextPainter` caching, no inline
  widgets, no `textScaler`.
- **Layout.** Nodes have positions, not constraints. Nothing is measured, nothing
  is intrinsic, nothing wraps.
- **The widget library.** Material and Cupertino do not apply inside a scene.
- **Lifetimes.** There is no element to hang disposal on, which is the point and
  the cost: `dispose()` is the caller's job, except for nodes removed from a
  `GroupNode.reactive` list, which the list owns.

## 6. Numbers

`dev/benchmarks/microbenchmarks/test/reactivity/b9_scene_mode_test.dart`. Apple
M1, macOS 26.5.1, debug `flutter test -j 1`, one file at a time. Median of 3
runs' medians and the min across those 3 runs, in µs per frame, 2 significant
figures. Same machine, same harness and same protocol as
[`BENCHMARKS.md`](BENCHMARKS.md), so the two sets of numbers can be divided by
each other.

*Headless* is the scene's own frame work — `flushSignals()` plus `composeFrame`
onto a real `ui.SceneBuilder` plus `build()` — that is, standalone mode with the
platform's present call removed. *Embedded* is the same scene inside a
`SceneView`, measured through `tester.pump()`, so it includes the whole framework
frame.

| Workload | Path | median (µs) | min (µs) |
| --- | --- | --- | --- |
| move 1 of 10,000 nodes | headless | 1500 | 1500 |
| move 1 of 10,000 nodes | embedded | 4700 | 4500 |
| move all 10,000, one `batch` | headless | 3200 | 3100 |
| move all 10,000, one `batch` | embedded | 7900 | 7600 |
| 50,000 particles, one `PictureNode`, re-recorded every frame | headless | 120 | 120 |
| mount + compose + dispose 10,000 nodes | headless | 39000 | 31000 |

Every row carries a liveness assertion in the test. The move rows assert
`debugRecordCount == 1` for all ten thousand nodes after the loop — not one
picture was re-recorded — and that the frame count matches the iteration count.
The particle row asserts exactly one re-record per frame; the mount row asserts,
outside the timed body, that ten thousand nodes really were built and disposed.

### Against the classic tree

Against the **best-practice** baselines in [`BENCHMARKS.md`](BENCHMARKS.md) —
`ValueListenableBuilder` for B1/B2, a `CustomPainter` driven by a `Listenable`
for B3, plain `Container` leaves for B8 — and, where it is the more interesting
comparison, against the Phase 3 leaf-binding rows from the same table.

| Scenario | Best practice | Phase 3 leaf | Scene mode | vs best practice |
| --- | --- | --- | --- | --- |
| B1, update 1 of 10,000 | 6700 µs | 8500 µs | 1500 headless / 4700 embedded | **4.5x** headless, **1.4x** embedded |
| B2, update all 10,000 | 53000 µs | 17000 µs | 3200 headless / 7900 embedded | **17x** headless, **6.7x** embedded |
| B3, 50,000 particles | 370 µs | 350 µs | 120 µs | **3.1x** |
| B8, mount 10,000 | 1000000 µs | 730000 µs | 39000 µs (mount **and** compose **and** dispose) | **26x** |

Read those honestly:

- **Mounting is where scene mode wins by an order of magnitude.** Ten thousand
  plain objects against ten thousand widget + element + render-object triples,
  with layout. 26x, and the scene-mode figure includes a full compose and the
  disposal that B8 measures as a separate row (17,000 µs on the baseline).
- **Updating all ten thousand is where the model wins.** One `batch`, one flush,
  ten thousand cached-field writes, one walk: 17x the `ValueListenableBuilder`
  baseline headless, and 5.3x Phase 3's leaf bindings, which already removed
  every rebuild. What is left after leaf bindings is the per-node layout and
  paint, and that is what scene mode removes.
- **Updating one of ten thousand is a smaller win, not a tie.** Both paths
  re-walk ten thousand somethings — the classic tree lays out and paints ten
  thousand render objects, the scene re-adds ten thousand pictures — so scene
  mode is 4.5x faster headless and 1.4x faster embedded, not the order of
  magnitude the other rows show. Neither number is O(1) in the number of
  nodes, and that is the next real problem (see below).
- **B3 is close to parity in kind, not in degree.** 120 µs against 370 µs is a
  real 3.1x, but the workload is one `drawRawPoints` of 100,000 floats either
  way; what scene mode removes is the `CustomPaint` render object and the
  repaint plumbing around it, not the drawing.
- **B1/B2/B8's classic-tree numbers are dominated by `Stack` layout and paint**,
  as `BENCHMARKS.md` already notes. Scene mode has no layout at all, which is a
  large part of why it wins, and is exactly the trade being made.

This table was refreshed 2026-09-04 on an idle machine, one file at a time,
`flutter test -j 1`, three runs each — see `BENCHMARKS.md`'s note on this
session. An earlier version of this table was measured while sharing the
machine with other agents' test runs, which inflated several rows (the
embedded rows by up to 40%, one particle-row run by nearly 3x); that is why
this table's ratios differ substantially from that earlier pass, especially
on B1/B2 embedded, which were previously read as a tie and now show a real,
if modest, win.

## 7. Open problems

1. **The walk is O(nodes) every frame.** Nothing retains an unchanged subtree.
   The fix is `SceneBuilder.addRetained` over a per-subtree `EngineLayer` with a
   dirty-propagation flag, which is `rendering/layer.dart`'s design; adopting it
   would trade the walk for one framework object per group. Worth doing when a
   scene is deep and mostly static, which a game's world usually is not.
2. **Embedded mode has no per-node engine retention.** The whole scene lands in
   one `PictureLayer`. A scene with an expensive static background and a small
   moving foreground would want the background in its own retained layer;
   today it is re-added every frame.
3. **Bounds are only known after a node has recorded once.** A node created and
   immediately culled records anyway, to learn its own size. Cheap, but not
   nothing at ten thousand.
4. **Pointer capture.** No node can claim a drag. This is the first thing a real
   game will ask for.
5. **`GroupNode.reactive` disposes removed children.** That is the right default
   for a `For`. Moving a node between two reactive groups works, because
   disposal waits for the next frame and skips a node that has been re-adopted,
   but a node removed from a scene that then stops composing is never disposed
   at all, and there is no `keepAlive` for a node meant to outlive its list.
6. **`ui.Image` lifetime.** `SpriteNode` does not own its image. Nothing here
   helps with texture atlases, which is what a real sprite pipeline needs next.
7. **No DevTools story.** A scene is invisible to the widget inspector, which is
   `PLAN.md` section 6's warning made concrete: the screen changes and nothing
   rebuilds.
