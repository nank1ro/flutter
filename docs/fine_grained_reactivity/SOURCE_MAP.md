# Source map

Anchors into the code this fork modifies. Every line number below was read out
of the working checkout, not recalled from memory.

- Flutter: stable **3.47.1**, revision **6655482ec06**, paths relative to
  `packages/flutter/lib/src/` unless stated otherwise.
- alien_signals: **2.3.1** (`medz/alien-signals-dart`, zero dependencies), at
  `~/.pub-cache/hosted/pub.dev/alien_signals-2.3.1/`.
- solidart **3.0.0-dev.2** / flutter_solidart, read for prior art only.

Line numbers drift on every rebase. When they stop matching, re-derive them
rather than trusting this table.

## Build pipeline: `widgets/framework.dart`

| Symbol | Line | Note |
| --- | --- | --- |
| `final class BuildScope` | 2697 | Unit of build isolation; one per root, plus one per `LayoutBuilder`. |
| `BuildScope({this.scheduleRebuild})` | 2697 | Constructor takes the optional out-of-band rebuild hook. |
| `BuildScope.scheduleRebuild` | 2714 | Called when the scope goes from clean to dirty. The reactive scheduler hooks here. |
| `BuildScope._dirtyElementsNeedsResorting` | 2723 | Set when an element is marked dirty during a build pass. |
| `BuildScope._dirtyElements` | 2724 | Depth-sorted dirty list. |
| `BuildScope._tryRebuild` | 2748 | Per-element guarded rebuild. |
| `BuildScope._flushDirtyElements({required Element debugBuildRoot})` | 2811 | Drains the dirty list in depth order. |
| `class BuildOwner` | 2914 | Owns the dirty list and the build phase. |
| `BuildOwner` constructor | 2922 | |
| `BuildOwner.onBuildScheduled` | 2927 | Wired to `WidgetsBinding._handleBuildScheduled`. |
| `BuildOwner.scheduleBuildFor(Element)` | 2949 | The single entry point for "this element must rebuild". |
| `BuildOwner._debugStateLockLevel` | 3011 | |
| `BuildOwner._debugBuilding` | 3018 | Guard the reactive phase asserts reuse. |
| `BuildOwner.lockState` | 3026 | |
| `BuildOwner.buildScope(Element context, [VoidCallback? callback])` | 3069 | The build pass itself. |
| `BuildOwner.finalizeTree` | 3352 | Unmounts deactivated elements; where owner disposal hooks belong. |
| `BuildOwner.reassemble(Element root)` | 3466 | Hot reload path. |
| `abstract class Element` | 3570 | Becomes the reactive owner node. |
| `Element.buildScope` getter | 3733 | `=> _parentBuildScope!` |
| `Element.reassemble` | 3767 | |
| `Element._lifecycleState` | 3894 | `active` / `inactive` / `defunct`; gates effect disposal. |
| `Element.updateChild` | 3995 | Single-child reconciliation. |
| `Element.updateChildren` | 4138 | Keyed list reconciliation; the code a reactive `For` replaces. |
| `Element.mount` | 4341 | |
| `Element.update` | 4388 | |
| `Element.inflateWidget` | 4569 | |
| `Element.deactivateChild` | 4645 | |
| `Element.activate` | 4767 | |
| `Element.deactivate` | 4810 | |
| `Element.unmount` | 4864 | Where the element's reactive owner must be disposed. |
| `Element._dependencies` | 5056 | Inherited-widget dependency set, superseded by signal links. |
| `Element.dependOnInheritedElement` | 5087 | |
| `Element.didChangeDependencies` | 5203 | |
| `Element._dirty` | 5336 | |
| `Element._inDirtyList` | 5340 | |
| `Element.markNeedsBuild()` | 5352 | The target of the per-element effect callback. |
| `Element.rebuild({bool force = false})` | 5516 | |
| `Element.performRebuild()` | 5561 | Base implementation. |
| `ComponentElement` | 5788 | |
| `ComponentElement._debugDoingBuild` | 5794 | |
| `ComponentElement.performRebuild` | 5823 | `@pragma('vm:notify-debugger-on-exception')` sits at 5822. |
| `built = build();` | 5830 | The exact call the tracking scope must wrap. |
| `StatefulElement` | 5913 | |
| `StatefulElement._state` | 5952 | |
| `StatefulElement.performRebuild` | 5990 | |
| `StatefulElement.activate` | 6024 | |
| `StatefulElement.unmount` | 6041 | |
| `StatefulElement.didChangeDependencies` | 6130 | |
| `State` | 916 | |
| `State.setState` | 1160 | Reimplemented as a version-signal bump. |
| `InheritedElement` | 6265 | |
| `InheritedElement._dependents` (`HashMap<Element, Object?>`) | 6269 | The hand-rolled dependency graph the signal graph replaces. |
| `InheritedElement.getDependencies` | 6310 | |
| `InheritedElement.setDependencies` | 6337 | |
| `InheritedElement.updateDependencies` | 6364 | |
| `InheritedElement.notifyDependent` | 6385 | |
| `InheritedElement.notifyClients` | 6427 | |
| `RenderObjectElement` | 6624 | |
| `RenderObjectElement.mount` | 6797 | `createRenderObject` at 6803. |
| `RenderObjectElement.update` | 6819 | |
| `RenderObjectElement.performRebuild` | 6836 | |
| `RenderObjectElement._performRebuild` | 6845 | Calls `updateRenderObject`; the seam for leaf prop bindings. |
| `RenderObjectElement.unmount` | 6869 | |
| `RootElementMixin` | 7041 | |
| `RootElementMixin.assignOwner` | 7052 | Sets `_parentBuildScope = BuildScope()`. |
| `LeafRenderObjectElement` | 7067 | |
| `SingleChildRenderObjectElement` | 7105 | |
| `MultiChildRenderObjectElement` | 7175 | |
| `MultiChildRenderObjectElement.update` | 7303 | `updateChildren` at 7308. |

## Nested build scopes: `widgets/layout_builder.dart`

| Symbol | Line | Note |
| --- | --- | --- |
| `_LayoutBuilderElement<LayoutInfoType>` | 109 | The existing precedent for a non-root build scope. |
| `buildScope` override | 119 | |
| `_buildScope = BuildScope(scheduleRebuild: _scheduleRebuild)` | 121 | Shows how an out-of-band scheduler plugs in. |
| `_scheduleRebuild` | 128 | |
| `performRebuild` | 201 | |
| `_rebuildWithConstraints` | 225 | Builds during layout, outside the normal build phase. |

## Frame plumbing: `widgets/binding.dart`, `foundation/binding.dart`

| Symbol | Line | Note |
| --- | --- | --- |
| `_buildOwner = BuildOwner()` | 476 | |
| `onBuildScheduled = _handleBuildScheduled` | 477 | |
| `buildOwner` getter | 838 | |
| `_handleBuildScheduled` | 1430 | Ends with `ensureVisualUpdate()` at 1459. |
| `drawFrame` | 1536–1597 | `buildOwner!.buildScope(rootElement!)` 1571, `super.drawFrame()` 1573, `finalizeTree()` 1578. The effect flush point goes immediately before 1571. |
| `performReassemble` | 1701 | |
| `foundation/binding.dart` `reassembleApplication` | 719 | |
| `foundation/binding.dart` `performReassemble` | 735 | |

## Scheduler: `scheduler/binding.dart`, `scheduler/ticker.dart`

| Symbol | Line | Note |
| --- | --- | --- |
| `enum SchedulerPhase` | 160 | `idle`, `transientCallbacks`, `midFrameMicrotasks`, `persistentCallbacks`, `postFrameCallbacks`. Signal writes are legal in any phase; the flush point is phase-dependent. |
| `addPersistentFrameCallback` | 781 | How the game loop's `frame`/`time` signal is driven. |
| `addPostFrameCallback(cb, {String debugLabel = 'callback'})` | 818 | |
| `ensureVisualUpdate` | 906 | Called when a signal write dirties anything. |
| `scheduleFrame` | 946 | |
| `scheduleWarmUpFrame` | 1037 | |
| `handleBeginFrame` | 1226 | |
| `handleDrawFrame` | 1338 | |
| `ticker.dart` `Ticker` | 78 | |
| `Ticker.muted` | 106, 119 | |
| `Ticker.start` | 185 | |

## Render pipeline: `rendering/binding.dart`, `rendering/object.dart`

| Symbol | Line | Note |
| --- | --- | --- |
| `binding.dart` `rootPipelineOwner` | 324 | |
| `binding.dart` `_handlePersistentFrameCallback` | 557 | |
| `binding.dart` `drawFrame` | 691 | |
| `object.dart` `debugDoingLayout` | 1126 | |
| `object.dart` `flushLayout` | 1137 | |
| `object.dart` `flushCompositingBits` | 1239 | |
| `object.dart` `debugDoingPaint` | 1283 | |
| `object.dart` `flushPaint` | 1293 | |
| `object.dart` `flushSemantics` | 1451 | |
| `object.dart` `_debugCanPerformMutations` | 2335 | Constrains when a render-level effect may write. |
| `object.dart` `markNeedsLayout` | 2676 | |
| `object.dart` `markNeedsPaint` | 3338 | Asserts `!owner.debugDoingPaint`; a paint-phase signal write would trip this. |
| `object.dart` `markNeedsCompositedLayerUpdate` | 3398 | The cheapest invalidation; the target for opacity/transform bindings. |
| `object.dart` `markNeedsSemanticsUpdate` | 3921 | |

## Leaf-binding examples

| Symbol | Line | Note |
| --- | --- | --- |
| `rendering/proxy_box.dart` `RenderOpacity.opacity` setter | 901 | Prototype target: bind a signal here, not to a widget. |
| `rendering/paragraph.dart` `RenderParagraph.text` setter | 422 | |
| `widgets/basic.dart` `Opacity` | 336 | `updateRenderObject` at 372. |
| `widgets/basic.dart` `Padding` | 2317 | |
| `widgets/basic.dart` `ColoredBox` | 8379 | |
| `widgets/text.dart` `Text` | 497 | `build` at 716. |
| `foundation/change_notifier.dart` `ChangeNotifier` | 139 | The listener model being superseded. |
| `foundation/change_notifier.dart` `ValueNotifier` | 542 | |
| `widgets/transitions.dart` `ListenableBuilder` | 1132 | Note the file: it is not in `basic.dart`. |

## dart:ui, for scene mode (`engine/src/flutter/lib/ui/`)

| Symbol | Line | Note |
| --- | --- | --- |
| `platform_dispatcher.dart` `onBeginFrame` | 423 | |
| `platform_dispatcher.dart` `onDrawFrame` | 440 | |
| `platform_dispatcher.dart` `scheduleFrame` | 881 | |
| `window.dart` `FlutterView.render(Scene scene, {Size? size})` | 380 | The bottom of scene mode. |
| `compositing.dart` `SceneBuilder` | 259 | |
| `compositing.dart` `pushTransform` | 657 | |
| `compositing.dart` `pushOpacity` | 804 | |
| `compositing.dart` `addPicture` | 1014 | |
| `compositing.dart` `build` | 1073 | |
| `painting.dart` `Canvas` | 6869 | |
| `painting.dart` `Picture` | 8436 | |
| `painting.dart` `PictureRecorder` | 8604 | |

## Tooling and benchmarks

| Item | Where | Note |
| --- | --- | --- |
| `--track-widget-creation` flag flow | `packages/flutter_tools/lib/src/compile.dart` 278, 363, 776, 980 | |
| `track_widget_constructor_locations.dart` | **absent** | The kernel transformer lives in the Dart submodule, which is not checked out here. Any compile-step phase must first obtain it. |
| `WidgetRecorder` | `dev/benchmarks/macrobenchmarks/lib/src/web/recorder.dart` 373 | |
| `WidgetBuildRecorder` | same file, 476 | |
| `bench_build_material_checkbox.dart` | `dev/benchmarks/macrobenchmarks/` | Existing build-cost benchmark to diff against. |
| microbenchmarks | `dev/benchmarks/microbenchmarks` | |
| Framework tests | `packages/flutter/test/widgets/{framework,inherited,layout_builder}_test.dart` | |

`flutter test` run from `packages/flutter` resolves against the checkout's own
`lib/` through its `package_config`, so framework edits take effect with no
build step. `bin/cache` only supplies the Dart SDK, the tools, and engine
artifacts.

No reactive primitive exists in `packages/flutter/lib` today: every `Signal`
hit in that tree is `PointerSignal*` from the gesture system, so the name
`Signal` is free at the framework level.

## alien_signals 2.3.1

`lib/src/system.dart` — the graph core:

| Symbol | Line | Note |
| --- | --- | --- |
| `ReactiveFlags` extension type | 9 | `none 0`, `mutable 1`, `watching 2`, `recursedCheck 4`, `recursed 8`, `dirty 16`, `pending 32`. |
| `ReactiveNode { flags; Link? deps, depsTail, subs, subsTail }` | 69 | Four pointers per node; no collections. |
| `Link { version; dep; sub; prevSub, nextSub, prevDep, nextDep }` | 112 | Doubly-linked in both directions; links are reused across re-runs. |
| `abstract class ReactiveSystem` | 210 | Subclass it. There is no `createReactiveSystem` function in the Dart port. |
| `bool update(ReactiveNode)` | 220 | Abstract. |
| `void notify(ReactiveNode)` | 228 | Abstract. **This is the override that makes the fork's scheduler frame-driven.** |
| `void unwatched(ReactiveNode)` | 235 | Abstract. |
| `link` | 251 | |
| `unlink` | 305 | |
| `propagate(Link, [bool innerWrite = false])` | 349 | Cycle guard via `recursedCheck` / `recursed`, lines 359–380. |
| `shallowPropagate` | 427 | |
| `checkDirty(Link, ReactiveNode)` | 453 | The pull half of the glitch-free two-phase algorithm. |

Multiple independent systems can coexist, since state lives on the subclass
rather than in globals.

`lib/src/preset.dart` — the default system:

| Symbol | Line | Note |
| --- | --- | --- |
| `const system = PresetReactiveSystem()` | 39 | |
| `hasChildEffect = 64` | 56 | Extra flag beyond the core set. |
| `LinkedEffect { nextEffect }` | 65 | The effect queue is an intrusive singly-linked list: no allocation to enqueue. |
| `SignalNode<T> { currentValue; pendingValue }` | 88 | `set` 110, `get` 130, `didUpdate` 151. |
| `ComputedNode` | 165 | |
| `EffectScopeNode` | 249 | |
| `EffectNode<T> extends LinkedEffect { fn; cleanup; runEffect() }` | 267 | |
| `PresetReactiveSystem` | 324 | `update` 338, `notify` 357, `unwatched` 389. |
| `getActiveSub` / `setActiveSub` | 416–467 | The active-subscriber swap the tracked `build()` performs. |
| `getBatchDepth` / `startBatch` / `endBatch` | 416–467 | |
| `run(EffectNode)` | 516 | |
| `flush()` | 568 | Drains the queued-effects list synchronously. |

Two behaviours matter for this fork. First, `SignalNode.set` (line 110)
propagates and then calls `flush()` immediately when `batchDepth == 0`, so out
of the box every write runs its effects synchronously. Second, `notify` (357)
pushes the effect and its watching ancestors onto the `queuedEffects` list.
Overriding `notify` to enqueue onto a frame-scheduled queue instead is the
whole of the scheduling change.

`lib/src/surface.dart` — the public API, deliberately small:

| Symbol | Line | Note |
| --- | --- | --- |
| `signal<T>(T initialValue)` | 154 | Returns `WritableSignal<T> { T call(); void set(T) }`. In 2.3.1 there is **no** `.value` getter and **no** `count(1)` write shorthand. |
| `computed<T>(T Function(T?))` | 190 | |
| `effect(fn)` | 226 | Returns `Effect { void call() }`, where calling it stops the effect. |
| `effectScope(fn)` | 280 | |

There are no `batch()` or `untracked()` helpers in 2.3.1; only `startBatch` /
`endBatch`. The fork's own API layer supplies both.

## Prior art: solidart / flutter_solidart

solidart 3.0.0-dev.2 wraps alien's single global preset system
(`packages/solidart/lib/src/core/alien.dart`, `reactive_system.dart`), and its
effects run synchronously. flutter_solidart's `SignalBuilder` is implemented by
`_SignalBuilderElement` (`signal_builder.dart` lines 65–108): it sets the
active subscriber around `super.build()`, and its effect callback is
`markNeedsBuild`.

That is exactly the mechanism this fork moves into
`ComponentElement.performRebuild` for every element, which is what removes the
need for the wrapper widget.
