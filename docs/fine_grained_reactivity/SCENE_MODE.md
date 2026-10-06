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
against each other in the same session under the older sequential harness — a
6x difference, far larger than that harness's ordering bias, and the single
largest thing in the frame. Ten thousand engine
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
rebuild that, because at roughly 0.18 µs per node per frame (§6: 1818
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

`dev/benchmarks/microbenchmarks/test/reactivity/b9_scene_mode_test.dart`. Same
machine, harness and protocol as [`BENCHMARKS.md`](BENCHMARKS.md): Apple M1,
macOS 26.5.1, debug `flutter test -j 1`, one file at a time, three process
runs, six interleaved and rotated rounds per run with the first two discarded.
Median of the three run medians, min across their mins, and the spread across
the three run medians, in microseconds per frame.

**Every comparison on this page is now in-process.** The classic-tree rows
below are not carried over from another file: they are variants of the same
`b9` scenario, interleaved with the scene rows, on the *same workload* -- a
paint-only move of one or of all ten thousand sprites, `ReactiveOffset` in the
classic tree and `ROffset` in the collapsed one, two render objects per sprite
in each. Neither classic variant has a `RepaintBoundary` per sprite, because
the scene has no per-node retention either; that keeps the three models
comparable and makes these classic numbers higher than B1's, which does have
one.

*Headless* is the scene's own frame work -- `flushSignals()` plus
`composeFrame` onto a real `ui.SceneBuilder` plus `build()` -- that is,
standalone mode with the platform's present call removed. It has no framework
frame around it and is therefore **not** comparable with the classic rows;
*embedded* -- the same scene inside a `SceneView`, measured through
`tester.pump()` -- is, because it includes the whole framework frame. Both are
reported because headless is what a standalone game actually runs.

| Workload | Path | median (us) | min (us) | spread |
| --- | --- | --- | --- | --- |
| move 1 of 10,000 nodes | headless | 1818 | 1476 | 24% |
| move 1 of 10,000 nodes | embedded | 4815 | 4432 | 5% |
| move all 10,000, one `batch` | headless | 5471 | 3909 | 18% |
| move all 10,000, one `batch` | embedded | 7591 | 6690 | 4% |
| 50,000 particles, one `PictureNode`, re-recorded every frame | headless | 117 | 115 | 0% |
| mount + compose + dispose 10,000 nodes | headless | 41848 | 36233 | 2% |

Every row carries a liveness assertion in the test. The move rows assert
`debugRecordCount == 1` for all ten thousand nodes after the loop -- not one
picture was re-recorded -- and that the compose count matches the iteration
count. The particle row asserts exactly one re-record per frame; the mount row
asserts, outside the timed body, that ten thousand nodes really were built and
disposed.

### Against the classic tree

| Workload | Phase 3 leaf | Phase 5 collapsed | Scene embedded | Scene headless |
| --- | --- | --- | --- | --- |
| move 1 of 10,000 | 12695 | 11459 | 4815 (**2.64x** / 2.38x) | 1818 (6.98x / 6.30x)† |
| move all 10,000, one batch | 42538 | 40677 | 7591 (**5.60x** / 5.36x) | 5471 (7.78x / 7.43x)† |
| 50,000 particles | 234 | n/a‡ | not measured | 117 (2.00x)† |
| mount + compose + dispose 10,000 | 812049 | 532588 | not measured | 41848 (19.4x / 12.7x)† |

Ratios are "against Phase 3 leaf / against Phase 5 collapsed".
† Headless against a full framework frame is an unequal comparison; it is the
ceiling, not the like-for-like number. The like-for-like number is the
embedded column.
‡ `RCustomPaint` was removed from the Phase 5 spike, so there is no collapsed
particle variant.

Read those honestly:

- **Mounting is where scene mode wins by an order of magnitude.** Ten thousand
  plain objects against ten thousand widget + element + render-object triples,
  with layout: 19.4x against Phase 3, and still 12.7x against the collapsed
  node model, which has already removed the widget and the element. What is
  left after both is the render object, and that is what scene mode removes.
- **Updating all ten thousand is the clearest steady-state win.** 5.60x
  embedded against Phase 3's leaf bindings, which had already removed every
  rebuild.
- **Updating one of ten thousand is a smaller win, not a tie.** 2.64x embedded.
  Both paths re-walk ten thousand somethings -- the classic tree lays out and
  paints ten thousand render objects, the scene re-adds ten thousand pictures
  -- so neither is O(1) in the number of nodes, and that is the next real
  problem (see below).
- **The particle row is 2.0x, and the workload is one `drawRawPoints` of
  100,000 floats either way.** What scene mode removes there is the
  `CustomPaint` render object and the repaint plumbing around it, not the
  drawing.
- **Scene mode beats the collapsed node model on every row**, by 2.4x to 12.7x
  headless-to-embedded caveats aside. That comparison is one of the two
  reasons [`PHASE5_DECISION.md`](PHASE5_DECISION.md) still says not to build
  Phase 5.

**Supersedes the earlier table.** A previous revision of this section compared
scene rows measured in `b9` against classic rows measured in `b1`, `b3` and
`b8` -- different processes -- and both sides ran their variants sequentially
in file order, which is worth up to ~2x on its own. Those ratios (4.5x / 1.4x
on move-one, 17x / 6.7x on move-all, 3.1x on particles, 26x on mount) are
withdrawn. The direction of every one of them survived; the magnitudes did
not.

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
