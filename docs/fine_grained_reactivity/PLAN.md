# Fine-grained reactivity in the Flutter framework

Engineering plan for `flutter_solid`, a fork of `flutter/flutter` in which
state management is handled entirely by signals, computed values, and effects,
in the SolidJS sense, and reactivity reaches down to individual render-object
properties.

All line references are verified against stable 3.47.1, revision
`6655482ec06`, and alien_signals 2.3.1. See
[`SOURCE_MAP.md`](SOURCE_MAP.md) for the full table.

## 1. Goal

**True leaf-level reactivity with excellent performance, with video-game
workloads as the explicit target.**

Concretely, the fork succeeds when all of the following hold:

1. Changing one value in a 10,000-node scene costs work proportional to the
   number of things that actually depend on that value, and nothing else. No
   ancestor rebuild, no sibling diff, no subtree walk.
2. Application state is expressed with `Signal`, `Computed`, `Effect`,
   `batch`, `untracked`, and owner scopes, plus structural control flow in the
   `Show` / `For` style. This is the whole state model, not an option
   alongside others.
3. There is **no** `SignalBuilder` and no opt-in reactive widget. Every
   `Element` tracks signal reads during `build()` by default. Leaf
   render-object widgets bind props straight to `RenderObject` setters.
4. `StatefulWidget` and `setState` keep working, purely as legacy
   compatibility, implemented on top of signals rather than beside them.
5. A game can run a fixed-timestep loop at 120 Hz with thousands of
   independently moving nodes and allocate nothing per frame in the hot path.

Explicitly out of scope: any consideration of upstreaming, RFCs, or what the
Flutter team would accept. This is a standalone fork and is free to break
whatever it needs to break. Fork maintenance against upstream stable is still
a real cost and is addressed in section 10.

## 2. Assumptions

These are stated so they can be falsified early rather than discovered late.

- **A1.** The per-element cost of installing a tracking scope around `build()`
  is negligible when the build reads no signals. If this is false, phase 2 is
  dead and reactivity must stay opt-in. Measured in phase 2 against B7.
- **A2.** alien_signals' doubly-linked graph is allocation-free in steady
  state: links are reused across re-runs, so a signal that is written every
  frame does not allocate every frame. Verified by reading `link` /
  `propagate` (`system.dart` 251, 349); confirmed empirically in phase 0.
- **A3.** Deferring effect flush from "immediately on write" to "once per
  frame, before layout" is a behaviour change users can accept, given
  `Signal.value` reads are always glitch-free and immediately consistent. The
  deferral applies to effects, not to reads.
- **A4.** The overwhelming majority of Flutter's own widget code does not
  depend on `build()` being re-executed for correctness; it depends only on
  the resulting configuration being applied. This is what makes phase 5
  (collapsing Widget and Element) conceivable at all. It is an assumption, and
  the phase-5 spike exists to test it, not to assume it.
- **A5.** The engine is not modified. Everything happens in
  `packages/flutter`, plus reading `dart:ui` for scene mode. If a phase needs
  engine changes, it stops and is re-planned; the shared `bin/cache` symlink
  depends on this.

## 3. Key findings

### A. Flutter already has scoped, out-of-band rebuild scheduling

`BuildScope` (`framework.dart` 2697) is a unit of build isolation with its own
depth-sorted dirty list (`_dirtyElements`, 2724) and an optional
`scheduleRebuild` callback (2714) that fires when the scope becomes dirty.
`LayoutBuilder` already uses it: `_LayoutBuilderElement` overrides `buildScope`
(`layout_builder.dart` 119) with its own `BuildScope(scheduleRebuild:
_scheduleRebuild)` (121) so it can build during layout, entirely outside the
normal build phase.

This means the fork does not need to invent a scheduling concept. A reactive
scope is a `BuildScope` whose `scheduleRebuild` enqueues into the signal
scheduler, and everything downstream of `BuildOwner.scheduleBuildFor` (2949)
keeps working.

### B. `InheritedWidget` is a hand-rolled, weaker signal graph

`InheritedElement._dependents` (6269) is a `HashMap<Element, Object?>`: a
subscriber set with per-subscriber metadata. `notifyClients` (6427) walks it
and calls `notifyDependent` (6385), which calls `markNeedsBuild` (5352).
`getDependencies` / `setDependencies` / `updateDependencies` (6310, 6337,
6364) exist so that `InheritedModel` can implement partial dependency, which
is a manual re-implementation of fine-grained subscription.

The signal graph subsumes all of this. An `InheritedWidget`'s value becomes a
signal; `dependOnInheritedWidgetOfExactType` becomes a signal read; aspect
based partial dependency becomes reading a `Computed` derived from the
inherited value. The dependency bookkeeping in `Element._dependencies` (5056)
and the `didChangeDependencies` (5203) protocol become redundant, and can be
kept as no-op compatibility shims.

### C. The tracking hook is one line, and flutter_solidart already proves it

`ComponentElement.performRebuild` (5823) calls `built = build()` at line 5830.
flutter_solidart's `_SignalBuilderElement` (`signal_builder.dart` 65–108) does
exactly one interesting thing: it sets the reactive system's active subscriber
around `super.build()`, with an effect callback of `markNeedsBuild`.

Moving that into `ComponentElement.performRebuild` makes every element in the
tree reactive with no user-facing opt-in. The wrapper widget then has no
reason to exist. This is the single most important change in the fork and it
is a handful of lines; the work is in the consequences, not the edit.

### D. alien_signals' scheduler is one overridable method

`ReactiveSystem` (`system.dart` 210) is an abstract class with three abstract
members: `update` (220), `notify` (228), `unwatched` (235). The Dart port has
no `createReactiveSystem` factory; you subclass. State lives on the instance,
so multiple independent systems can coexist.

`PresetReactiveSystem.notify` (`preset.dart` 357) pushes an effect and its
watching ancestors onto an intrusive singly-linked `queuedEffects` list, and
`SignalNode.set` (110) calls `flush()` (568) synchronously when
`batchDepth == 0`. Overriding `notify` to enqueue onto a frame-scheduled queue
instead of the immediate one is the entire scheduling change. Glitch-freedom
is preserved because it comes from the two-phase `pending`/`dirty` push plus
the `checkDirty` pull (453), not from when the flush happens.

The intrusive list matters for games: enqueueing an effect writes one pointer
field on an object that already exists. No allocation.

### E. Leaf reactivity does not need the widget layer at all

`RenderObject` setters are already imperative and already have precise
invalidation: `markNeedsLayout` (2676), `markNeedsPaint` (3338),
`markNeedsCompositedLayerUpdate` (3398), `markNeedsSemanticsUpdate` (3921).
`RenderOpacity.opacity` (`proxy_box.dart` 901) does its own equality check and
picks the cheapest invalidation available.

The widget and element layers exist to turn a declarative description into
calls to those setters, by re-running `build()` and diffing. A signal bound to
a setter reaches the same place with no description, no re-execution, and no
diff. This is the observation that drives phases 3 through 5: the further
reactivity reaches, the less of the widget layer has any job left.

## 4. The three-tree question

The user asked for a serious analysis of whether the Widget / Element /
RenderObject architecture should survive. It deserves one, because the answer
determines everything after phase 3.

### What each tree actually does

- **Widget** — an immutable configuration record, allocated fresh on every
  build. Its purpose is to be *compared* against the previous one.
- **Element** — the retained node. Holds identity, lifetime, parent/child
  links, the build scope, and the inherited-widget dependencies. This is the
  tree that actually persists.
- **RenderObject** — layout, painting, hit testing, semantics.

In a fine-grained system, the Widget tree's entire reason for existing (being
diffed) disappears, because nothing re-runs to produce a new one. That is the
core of the argument.

### Option (a): keep three trees, add reactivity

Signals drive `markNeedsBuild`; the existing pipeline is otherwise unchanged.

- **Cost:** widgets are still allocated on every rebuild, and rebuilds still
  re-execute whole `build()` methods. Fine-grained only in *which* elements
  rebuild, not in *how much* each does.
- **Risk:** lowest. Every existing widget, package, and test keeps working.
- **Verdict:** necessary as the substrate. Not sufficient for the goal.

### Option (b): collapse Widget and Element

The retained node is created once. Props are reactive bindings rather than
fields on a re-allocated configuration object. Component functions run exactly
once, like SolidJS components; children are *created*, not diffed. Structural
change is expressed with explicit control-flow nodes (`Show`, `For`) rather
than by re-running a build and reconciling the result.

- **Gain:** removes per-rebuild widget allocation entirely, removes
  `updateChild` (3995) and `updateChildren` (4138) from the hot path, and
  makes "rebuild" a concept that no longer exists. This is the real
  destination.
- **Cost:** it is a different framework. `Widget`, `State`,
  `StatefulWidget`, and every widget in Material and Cupertino are written
  against the re-execution model. Keys, `GlobalKey`, and element reparenting
  all assume the diff.
- **Risk:** very high. Also *irreversible* in practice: once Material is
  ported, going back is not feasible.
- **Verdict:** the long-term direction, but it must be entered on evidence
  from a spike, not on conviction.

### Option (c): scene mode, no tree at all

A signals-driven retained scene graph that writes directly to `dart:ui`:
`PictureRecorder` → `Canvas` → `Picture` → `SceneBuilder.addPicture`
(`compositing.dart` 1014) → `FlutterView.render` (`window.dart` 380). It
coexists with the classic tree by being embedded in a single `RenderObject`,
which is exactly how Flame does it today.

The difference from Flame is the interesting part. Flame owns one render
object and redraws its whole world every frame in `render()`. Scene mode keeps
per-node signal bindings and a dirty set, so an unchanged node's `Picture` is
retained and re-added rather than re-recorded, and repaint is bounded to the
dirty region.

- **Gain:** the best achievable number for the game case. No widget, no
  element, no render object, no layout protocol per sprite.
- **Cost:** everything the framework provides is gone inside the scene: hit
  testing, semantics, focus, text layout, and Material widgets do not apply.
  All of it must be re-provided, or deliberately not offered.
- **Risk:** medium, and *contained*. It is additive; nothing existing breaks.
- **Verdict:** the right answer for games specifically, and it can be built
  without betting the framework on it.

### Recommendation

Sequence **a → leaf bindings → c → b**.

- **a** first because it is the substrate everything else needs, and it is
  the only step that can be validated against the entire existing test suite.
- **leaf bindings** next (phase 3) because they capture most of the
  performance win for ordinary UI at a small fraction of option (b)'s risk. A
  signal bound to `RenderOpacity.opacity` never touches a widget or an
  element. In practice this is where the majority of real applications' frame
  time goes.
- **c** next because games are the stated target, it is additive, and it is
  the only option that removes *all* per-node framework overhead. It also
  serves as a testbed for the pure-signal programming model without risking
  the classic tree.
- **b** last, gated on a design spike, because it is the only irreversible
  step. By the time it is attempted, phases 3 and 4 will have shown how much
  of the win it actually adds on top of leaf bindings, which may turn out to
  be less than it looks from here.

The honest tradeoffs of pushing further than (a), which apply to (b) and (c)
alike:

- **Hit testing** depends on the render tree's layout results and its
  `hitTest` walk. Scene mode must implement its own spatial query; there is no
  free version.
- **Semantics and accessibility** are produced from the render tree
  (`flushSemantics`, `object.dart` 1451). A scene has none unless it builds a
  semantics tree by hand. For a game this may be acceptable; for UI it is not.
- **Focus and text input** are widget-layer concepts built on
  `InheritedWidget` and the focus tree. They do not exist below it.
- **Text layout** is the single hardest thing to leave behind. It needs the
  paragraph builder, line breaking, and font resolution, all of which arrive
  through `RenderParagraph`.
- **Material and Cupertino compatibility** is what option (b) puts at risk.
  These are enormous bodies of code written against the rebuild model.

## 5. Phases

| Phase | Deliverable | Effort | Risk | What breaks |
| --- | --- | --- | --- | --- |
| 0 | Baseline measurements + `foundation/signals.dart` | 1 week | Low | Nothing |
| 1 | Reactive scheduler; `Element` as owner; inherited on the graph; `setState` as a version signal | 2–3 weeks | Medium | Ordering-sensitive tests |
| 2 | Tracked `build()` on by default for every element | 1–2 weeks | Medium | Nothing, if A1 holds |
| 3 | Leaf prop bindings, `Show` / `For`, game loop, demos | 3–4 weeks | Medium | Nothing (additive) |
| 4 | Scene mode on `dart:ui` | 4–6 weeks | Medium | Nothing (additive) |
| 5 | Widget+Element collapse: spike, decision, migration | 2 months+ | Very high | Potentially everything |
| 6 | Optional compile step for prop ergonomics | 2 weeks | Medium | Tooling only |

### Phase 0 — Baseline and the reactive core

**Deliverable.** A measured baseline for every scenario in
[`BENCHMARKS.md`](BENCHMARKS.md) on unmodified stable, plus
`packages/flutter/lib/src/foundation/signals.dart`: a vendored, dependency-free
port of the alien_signals core with the fork's own public API on top.

alien_signals is vendored rather than depended on. `packages/flutter` cannot
take a pub dependency, the core is small, and the fork needs to modify the
scheduler anyway.

```dart
// foundation/signals.dart

/// A mutable reactive value.
///
/// Reads inside a tracked scope subscribe that scope to this signal. Writes
/// mark dependents dirty and schedule an effect flush for the current frame.
final class Signal<T> extends ReactiveNode {
  Signal(T initialValue);

  T get value;          // tracked read
  set value(T newValue);

  /// Callable form, so a signal can be passed directly wherever a reactive
  /// prop of type `T Function()` is expected.
  T call() => value;

  T get peek;           // untracked read
}

final class Computed<T> extends ReactiveNode {
  Computed(T Function(T? previous) compute);
  T get value;
  T call() => value;
  T get peek;
}

/// Runs [fn] immediately, then again whenever a signal it read changes.
/// Ownership: an effect created inside an [Owner] scope is disposed with it.
final class Effect {
  factory Effect(void Function() fn);
  void dispose();
}

/// A disposal scope. Effects and computeds created while [Owner] is active
/// are torn down when it is disposed.
final class Owner {
  static Owner? get current;
  R run<R>(R Function() body);
  void dispose();
}

/// Defers effect flush until the outermost batch ends.
R batch<R>(R Function() body);

/// Runs [body] with tracking disabled.
R untracked<R>(R Function() body);
```

**API decision: `.value`, with `call()` retained.** alien_signals 2.3.1 has
call-syntax reads (`surface.dart` 154) and no `.value`. The fork exposes
`.value` as the primary form, because `s.value++`, `s.value += dt`, and
compound assignment are the operations a game loop performs constantly, and
because a read and a write should look symmetric. `call()` is kept for one
specific reason: reactive props have type `T Function()`, so a callable signal
can be passed straight through as `Opacity(opacity: myOpacity)` instead of
`Opacity(opacity: () => myOpacity.value)`. That removes the single largest
source of boilerplate in phase 3 and is why phase 6 may never be needed.

The tradeoff, stated plainly: a callable signal means `mySignal` and
`() => mySignal.value` are interchangeable at a prop site, so a reader cannot
tell from the call site whether a prop is tracked. Since *every* prop is
tracked, this ambiguity carries no information, which is why it is acceptable
here and would not be in a library.

**Scheduling.** The fork's system subclasses `ReactiveSystem` and overrides
`notify` (the `system.dart` 228 hook) to enqueue onto a frame-scheduled queue
rather than flushing synchronously:

```dart
final class _FrameScheduledSystem extends ReactiveSystem {
  ReactiveNode? _queueHead, _queueTail;
  bool _flushScheduled = false;

  @override
  void notify(ReactiveNode node) {
    // Intrusive singly-linked enqueue: no allocation.
    if (_queueTail == null) { _queueHead = _queueTail = node; }
    else { _queueTail!.nextEffect = node; _queueTail = node; }
    if (!_flushScheduled) {
      _flushScheduled = true;
      SchedulerBinding.instance.ensureVisualUpdate();
    }
  }

  /// Drains the queue. Called once per frame from the binding, and directly
  /// by [flushSync] for tests and for effects that must run outside a frame.
  void flush() { /* ... */ }
}
```

**Verification.** Unit tests for the primitives, including diamond dependency
(glitch-freedom), cycle detection, batching, owner disposal, and an allocation
test asserting that writing a signal in steady state allocates nothing.

**What breaks.** Nothing. This phase adds a file and touches no existing code.

### Phase 1 — Wire the scheduler into the framework

**Deliverable.** Signals drive the build pipeline. Four changes:

1. **Flush point.** `WidgetsBinding.drawFrame` (`binding.dart` 1536–1597)
   gains a signal flush immediately before `buildOwner!.buildScope(rootElement!)`
   at 1571. Effects that mark elements dirty therefore land in the same frame's
   build. `_handleBuildScheduled` (1430) already ends in `ensureVisualUpdate()`
   (1459), so a signal write outside a frame schedules one through exactly the
   path a `setState` does today.

2. **`Element` becomes an `Owner`.** Effects and computeds created during an
   element's build belong to that element and are disposed in `unmount`
   (4864). `_lifecycleState` (3894) gates this: a defunct element must not run
   effects. `deactivate` (4810) / `activate` (4767) must pause and resume
   rather than dispose, because an element can be reparented via `GlobalKey`.

3. **`InheritedWidget` on the signal graph.** `InheritedElement`
   (6265) holds a `Signal` for its widget's value.
   `dependOnInheritedWidgetOfExactType` reads it. `_dependents` (6269),
   `notifyClients` (6427), and `notifyDependent` (6385) are reduced to
   compatibility shims. `didChangeDependencies` (5203) still fires, so
   existing `State` subclasses keep working.

4. **`setState` as a version signal.** `State` (916) gets a private
   `Signal<int>`; `setState` (1160) runs the callback and bumps it;
   `StatefulElement.performRebuild` (5990) reads it. `setState` then *is* a
   signal write, and needs no special path in the scheduler. This is what
   makes "legacy compatibility" true rather than aspirational.

**Deferred: items 3 and 4, no measurable benefit for the goal.** Putting
`InheritedWidget` on the signal graph and reimplementing `setState` as a
version signal were both dropped from this phase when it was implemented.
Neither moves the goal: `notifyClients` (6427) already walks only its
dependents, so moving that set onto the graph changes the bookkeeping and not
the amount of work, and `setState` already reduces to a `markNeedsBuild` that
the signal path also ends in, so routing it through a signal adds a node per
`State` and buys nothing. Both are also the two changes with the widest
blast radius across the existing test suite, which is a poor trade for a
rewrite that leaves behaviour identical. The existing `_dependents` map and
`setState` → `markNeedsBuild` path stay as they are; they remain candidates
for phase 3, where a reactive prop reading an inherited value has a reason to
want the finer granularity.

**Verification.** The full `packages/flutter/test/widgets` suite, with
particular attention to `framework_test.dart`, `inherited_test.dart`, and
`layout_builder_test.dart`.

**What breaks.** Tests that assert on exact rebuild *ordering* or on rebuild
counts, and anything that assumed a `setState` inside a frame is observable
synchronously. Expect a real number of failures here; most are the test
encoding old behaviour rather than a genuine regression, but each one has to be
read.

### Phase 2 — Tracked `build()` by default

**Deliverable.** Every `ComponentElement` tracks the signals its `build()`
reads. No opt-in, no wrapper widget.

```dart
// ComponentElement.performRebuild, framework.dart 5823
@override
void performRebuild() {
  // ...
  final Object? previousSub = _system.setActiveSub(_buildNode);
  try {
    built = build();                       // line 5830
  } finally {
    _system.setActiveSub(previousSub);
  }
  // ...
}
```

`_buildNode` is a `ReactiveNode` owned by the element whose notify callback is
`markNeedsBuild()` (5352). This is precisely what
flutter_solidart's `_SignalBuilderElement` does, applied universally.

**Per-read overhead, and why it is acceptable.** The cost decomposes into two
parts.

- *Per build, no signal read:* two field writes to swap the active subscriber,
  plus one branch. This is what assumption A1 claims is negligible, and it is
  the reason phase 2 can be default-on. It is measured against B7
  (`bench_build_material_checkbox`), which is a pure Material build with no
  signals anywhere.
- *Per signal read:* a `link` call (`system.dart` 251), which reuses the
  existing `Link` when the dependency order is unchanged from the previous
  run, and allocates only when the dependency set changes shape.

If A1 fails, the fallback is a per-element opt-in flag set by the widget type,
which loses the "no opt-in" property. That would be a real defeat, so it is
measured before anything is built on top.

**Phase asserts.** Debug builds assert on signal reads and writes in phases
where they cannot be honoured. `markNeedsPaint` (3338) already asserts
`!owner.debugDoingPaint`, and `_debugCanPerformMutations` (`object.dart` 2335)
guards render-tree mutation. The reactive system adds its own assert keyed on
`SchedulerPhase` (`scheduler/binding.dart` 160): a write during
`persistentCallbacks` that would dirty an already-laid-out element is a bug
worth reporting loudly, not silently deferring to the next frame.

**What breaks.** Nothing, if A1 holds. The change is invisible to code that
uses no signals.

#### As implemented

**One node per element, unconditionally.** `Element._trackingNode` is
allocated on the first build of every `ComponentElement`, not only on the ones
that read something: the node is what a read attaches to, so it has to exist
before the build runs. An element that reads nothing keeps a node with an
empty dependency list, which costs one object and no per-build work.
`debugTrackSignalReadsInBuild` (framework.dart) turns the tracking off in a
debug build, so the B7 A/B is reproducible without editing the framework.

**Effects created in `build` re-run per rebuild — a known divergence from
SolidJS.** In SolidJS a component body runs once, so `createEffect` in it runs
once per component instance. A Flutter `build` re-runs, and an effect created
in one belongs to that build's scope: it is disposed and re-created every
time. The per-instance equivalent is `State.initState`, which runs once per
element and which the framework now runs inside `Element._reactiveElementOwner`
— a scope detached from any enclosing build and disposed when the element
unmounts, after `State.dispose`. Phase 5 resolves the divergence properly, by
giving a component a body that runs once; until then, `initState` is the
supported place for an effect that must not be re-created.

**Writing a signal during build is reported, on the same rule as
`markNeedsBuild`.** `BuildOwner.debugCheckSignalWriteAllowed` is installed by
`WidgetsBinding` as `debugAssertSignalWriteAllowed`, is handed the signal being
written, and walks its subscriber list. The rule is the one
`Element.markNeedsBuild` already applies: dirtying an element during a build is
fine when that element is at or below `_debugCurrentBuildTarget`, because
parents build before children and this build will reach it. So the write throws
a `FlutterError` naming the offending widget only when some element that reads
the signal is an ancestor or a sibling of the build target — one that has
already built with the old value. Subscribers that are not elements, such as a
plain `Effect`, never block a write: they are queued for the next flush. Each
element's tracking node carries a debug-only `Subscriber.debugOwner` back to
its element, which is how the walk attributes a subscriber.

A signal the build target itself reads is refused once that target's own build
is running (`Element.debugDoingBuild`): the read has already happened, and the
invalidation the write queues is dropped when the build ends. Before then it is
allowed, which is what makes the mirror idiom legal — `_selected.value =
widget.selected` in `State.initState`, `State.didUpdateWidget` or
`State.didChangeDependencies`, all of which run before the build that reads it.
Writes made during layout and paint are allowed and picked up by the next
frame, and a build that runs *from* layout — a `LayoutBuilder` builder, a lazy
sliver's item builder — counts as layout for this purpose.

**Untracked reads during a frame are reported.** Not every signal read is
tracked, and an untracked read during a frame is silent: the frame is right
once and stale from then on. `debugSignalReadOutsideTracking`, installed by
`WidgetsBinding`, reports one such read per frame through
`FlutterError.reportError` when the scheduler is in `persistentCallbacks`.
Reads from event handlers, timers and effects are unaffected, as are reads
through `peek`, which say the staleness is deliberate. `State.didChangeDependencies`
is untracked on purpose — it is the inherited-widget protocol, not a build, and
the build that follows it reads the same values reactively — so both call sites
in `StatefulElement` run it inside `untracked`, which marks the reads as
deliberate and keeps them out of the report. Everything is inside `assert`, so
release builds pay nothing.

**Builders that run from layout track too.** A callback invoked by a
`RenderObjectElement` during layout is outside the tracked scope that
`ComponentElement.build` gets, so a signal read there would be silently
untracked. `Element.trackSignalReads` is the seam; two call sites use it:

- `_LayoutBuilderElement._rebuildWithConstraints` tracks the builder. The
  invalidation path is the element's own `markNeedsBuild` override, which
  schedules another layout callback.
- `SliverMultiBoxAdaptorElement._build` tracks `delegate.build(this, index)`,
  retaining dependencies across calls because the children are built one index
  at a time; `performRebuild` clears them and starts over.

A retaining run keeps the version it started with, instead of taking a fresh
one per call: `Subscriber._runVersion` is refreshed only by a full
(non-retaining) `track`, and reads use it rather than the global cycle counter.
That is what lets `_link` recognise a second read of the same signal by the
same node and reuse the existing `Link`. Without it, a signal read by every
item builder gained one edge per child built, and a scroll grew the subscriber
list without bound.

Known follow-ups, deliberately not done here:

- The sliver tracks per *adaptor*, not per index: a change to a signal read by
  one item rebuilds every materialized item. Correct, coarse.
- Its dependency list only shrinks on `performRebuild`, so a long scroll keeps
  the edges of children that have since been recycled — one per distinct
  signal, not one per read.
- `TwoDimensionalViewport` and any other `RenderObjectElement` that calls a
  user builder from layout are still untracked. `SliverChildListDelegate`
  needs nothing: it holds already-built widgets.

**Numbers.** Full table and protocol in [`BENCHMARKS.md`](BENCHMARKS.md);
2026-09-04, interleaved and in-process against the best-practice baseline,
µs per `pump()`:

| Scenario | best practice | Phase 2 signal-in-build | vs |
| --- | --- | --- | --- |
| B1, one of 10,000 sprites | 7005 | 7006 | 1.00x |
| B2, all 10,000, one batch | 33851 | 35759 | 0.95x |
| B4, text leaf at depth 50 | 318 | 322 | 0.99x |
| B5, leaf at depth 100 | 352 | 355 | 0.99x |
| B6, one of 1,000 rows | 392 | 387 | 1.01x |
| B7, Material grid, tracking **off** → **on** | 4198 | 4142 | 1.01x |

**Phase 2 is parity, and parity is the pass condition.** A
`ValueListenableBuilder` leaf and a signal-reading leaf both end in exactly one
element rebuild, so they do the same work; what Phase 2 removes is the wrapper
widget, the builder closure and the opt-in, not the rebuild. Removing the
rebuild itself is Phase 3. An earlier pass read Phase 2 as 1.4x faster on B4
and B5; that was position-in-file and does not survive interleaving.

**A1 holds as far as three runs can tell.** B7 is a true A/B on one tree with
the framework's own `debugTrackSignalReadsInBuild` toggle: tracking-on reads
1.3% *faster* on the median and 0.2% slower on the min, with a 7-8% run-to-run
spread. The sign flips between the two statistics, which is what "no effect
this harness can resolve" looks like. It is not proof of zero cost. Reactivity
stays default-on.

### Phase 3 — Leaf bindings, control flow, and the game loop

This is the phase where the goal is actually achieved for ordinary UI.

**Deliverable 1: reactive props.** Leaf and single-child render-object widgets
accept `T Function()` props in addition to plain `T`. The element registers
one effect per reactive prop, writing straight to the render object's setter:

```dart
// Prop<T> is just T Function(); the alias exists for readability.
typedef Prop<T> = T Function();

class Opacity extends SingleChildRenderObjectWidget {
  const Opacity({super.key, required this.opacity, super.child});
  final Prop<double> opacity;   // a Signal<double> satisfies this directly
  // ...
}

// In the element, replacing the updateRenderObject path (framework.dart 6845):
Effect(() => renderObject.opacity = widget.opacity());
```

The effect writes `RenderOpacity.opacity` (`proxy_box.dart` 901), which does
its own equality check and calls `markNeedsCompositedLayerUpdate` (3398) when
it can — the cheapest invalidation in the render pipeline. Nothing rebuilds.
No widget is allocated. `_performRebuild` (6845) is not entered at all.

Prototype targets, in order: `Opacity` (`basic.dart` 336), `ColoredBox`
(8379), `Padding` (2317), then `Text` (`text.dart` 497) via
`RenderParagraph.text` (`paragraph.dart` 422).

**Deliverable 2: structural control flow.** `Show` and `For` as elements, not
as widgets that rebuild:

```dart
Show(when: () => isVisible.value, child: () => HeavyThing());

For<Sprite>(
  each: () => sprites.value,
  key: (s) => s.id,
  builder: (s) => SpriteNode(s),
);
```

`Show` mounts and unmounts one child subtree on a boolean edge. `For` performs
keyed reconciliation over the *list signal only*, and does not touch children
whose keys are unchanged. This replaces `Element.updateChildren` (4138) for
reactive lists: the reconciliation runs when the list changes, rather than
whenever an ancestor rebuilds.

**Deliverable 3: the game loop.** This is the part that has to be right, or
the "video game" goal is words.

*Time as a signal.* A persistent frame callback
(`addPersistentFrameCallback`, `scheduler/binding.dart` 781) or a `Ticker`
(`ticker.dart` 78) writes a `frame` and a `time` signal once per frame. A
`Ticker` is preferable for a game world that can be paused, since `muted`
(106/119) already exists for that.

*Fixed timestep.* Simulation runs at a fixed `dt` with an accumulator, so
physics is deterministic and independent of display rate. Rendering
interpolates between the last two simulation states. This is standard, and it
matters here because it decides how many signal writes happen per frame: the
loop may run the simulation zero, one, or several times per displayed frame.

```dart
void _onFrame(Duration elapsed) {
  _accumulator += elapsed - _lastElapsed;
  _lastElapsed = elapsed;
  while (_accumulator >= _fixedDt) {
    batch(() {
      simulate(_fixedDt);   // thousands of signal writes, one flush
    });
    _accumulator -= _fixedDt;
  }
  alpha.value = _accumulator.inMicroseconds / _fixedDt.inMicroseconds;
}
```

*One flush point.* Every write in a simulation step is inside a `batch`, so
effects are queued but not run. The queue is drained once, from
`WidgetsBinding.drawFrame` immediately before the build scope at
`binding.dart` 1571 — that is, before layout
(`flushLayout`, `object.dart` 1137) and before paint (`flushPaint`, 1293).
Render-level effects therefore write their setters while the render tree is
still mutable, and the invalidation they cause is picked up by the same
frame's layout and paint passes.

*Interaction with `SchedulerPhase`.* The relevant states
(`scheduler/binding.dart` 160):

| Phase | Signal write | Behaviour |
| --- | --- | --- |
| `idle` | Legal | Queues an effect and calls `ensureVisualUpdate` (906) → `scheduleFrame` (946). |
| `transientCallbacks` | Legal, and the normal case for animations | Effects flush later in the same frame, before build. |
| `midFrameMicrotasks` | Legal | Same as above. |
| `persistentCallbacks` | Legal *before* the flush point; asserts after it | Writing after the flush, e.g. during layout, defers to the next frame. Debug builds report this. |
| `postFrameCallbacks` | Legal | Schedules the next frame. |

*No allocation in the hot path.* Enqueueing an effect writes one pointer on an
existing node (`LinkedEffect.nextEffect`, `preset.dart` 65). Links are reused
when the dependency shape is unchanged. The rules that follow: no closures
allocated per frame in the loop, no list or map churn in effect bodies, no
`Duration` arithmetic that boxes in the inner loop. B3 (50,000 particles) is
the test that catches violations.

**Deliverable 4: demos.** 10,000 sprites with one signal each; a particle
field; a 120 Hz counter in a deep tree. These are the benchmark scenarios
B1–B4 as runnable applications.

**What breaks.** Nothing. Reactive props are additive; the plain-`T`
constructors stay.

#### As implemented

**Files.** `packages/flutter/lib/src/widgets/reactive_widgets.dart` (props,
bindings, the reactive widgets, `Show`, `For`) and
`packages/flutter/lib/src/widgets/frame_clock.dart` (`FrameClock`), both
exported from `widgets.dart`. The only edit to an existing framework file is
one accessor, `Element.reactiveOwner`, which exposes the element-lifetime
`Owner` that Phase 1 already put on every element. Tests are
`test/widgets/reactive_widgets_test.dart` and
`test/widgets/reactive_frame_clock_test.dart`; the demo app is
`dev/reactive_demos`.

**Naming.** Every reactive widget is the twin of an existing Flutter widget,
with a `Reactive` prefix and the original's property names, each typed
`Prop<T>` instead of `T`: `ReactiveOpacity`, `ReactiveColoredBox`,
`ReactivePadding`, `ReactiveTransform`, `ReactiveOffset`,
`ReactiveConstrainedBox`, `ReactiveSizedBox`, `ReactiveDecoratedBox`,
`ReactiveText`, `ReactiveCustomPaint`. All keep `const` constructors. Where
two properties of the original feed one render-object setter, they collapse
into the one property the setter takes: `ReactiveSizedBox` has a `Prop<Size>`
rather than a width and a height, because `RenderConstrainedBox` takes both at
once and splitting them would mean two effects that each read both values.
`ReactiveText`'s `data` and `style` are the exception that proves the rule —
they stay separate, and are bound together as one `InlineSpan` prop, because
`RenderParagraph.text` is a span.

**One effect per binding, and the prop lives in a field.** A binding is a
property-to-setter pair. `PropBinder.bind(prop, apply)` creates an `Effect`
owned by the element's `reactiveOwner`, whose body is `apply(prop())`. The
prop closure is a mutable field of the binding rather than something the
effect captured, so replacing it does not allocate a new effect. Widgets
declare their bindings in `ReactiveRenderObjectWidget.bindProps`, which is
called on mount and on every update, and must bind the same properties in the
same order every time; a debug assert checks it.

**Rebinding is by closure identity.** `update()` compares the new prop with
the old with `identical` and, when they differ, re-runs the existing effect
(`Effect.onInvalidate`), which re-reads and re-tracks. A `Signal` passed
straight to a property is the same object on every rebuild, so the common case
costs one comparison and nothing else. A closure written at the call site,
`() => a.value * 2`, is a fresh object each time, so it rebinds — correct, and
one effect run, only when an ancestor rebuilt.

**A property is read twice when the element mounts.** `createRenderObject`
seeds the render object with `untracked(prop)`, so it is never laid out with a
placeholder value; then the binding's first effect run reads it again to
discover the dependencies. The second write is a no-op because every render
object setter compares before it invalidates. Seeding must be `untracked`:
`createRenderObject` runs outside any tracking scope, and Phase 2's
`debugSignalReadOutsideTracking` would otherwise report the read.

**Two render objects are this file's own.** `RenderReactiveColoredBox`,
because `ColoredBox`'s render object is private, and `RenderReactiveOffset`,
which paints its child at an absolute pixel offset without touching layout —
the sprite primitive. Moving a `ReactiveOffset` is one `markNeedsPaint` on one
render object; moving a `Positioned` inside a `Stack` writes parent data and
relayouts the whole stack, which is why the demo and the benchmarks move
sprites with `ReactiveOffset`.

**`Show` is a `StatelessWidget`, and needs to be nothing more.** Phase 2
already tracks every build, so a write that flips `when` rebuilds the `Show`
element and only it. `child` and `fallback` are callbacks so the branch that
is not mounted is never built. There is no custom element here at all; adding
one would buy nothing.

**`For` is a custom `RenderObjectElement` over a `RenderStack`.** Only the
list read is tracked, through `Element.trackSignalReads`; `builder` runs
outside it, so an item widget's own signals belong to the item's element. A
key that is already mounted is left completely alone: `builder` is not called,
`updateChild` is not called, and the element and render object are the same
objects as before. New keys are inflated, removed keys are deactivated, and
moved keys get `updateSlotForChild`, which moves the render object.

Two deliberate limitations. The parameter is `keyOf`, not `key`, because
`Widget.key` has that name. And the children are laid out as a `Stack`,
because a multi-child element must own a render object that lays its children
out, and there is no layout-neutral multi-child render object in Flutter: the
slot bookkeeping of a `MultiChildRenderObjectElement` belongs to its own
render object, so a `For` cannot hand its children to an ancestor's slots. A
stack is the right layout for a scene of independently positioned things,
which is what `For` is for. For a linear list, put the `For` inside the layout
you want and give the items a fixed size.

**`ReactiveCustomPaint` tracks in the render object, not the element.**
`RenderReactiveCustomPaint.paint` runs `super.paint` inside a `TrackingNode`
whose invalidation is `markNeedsPaint`, so a painter may read signals inside
`CustomPainter.paint` and a write repaints that render object and nothing
else. The node is created through a detached `Owner` so that no enclosing
build or effect scope disposes it, and it is disposed with the render object.
Because the reads happen inside a tracking scope,
`debugSignalReadOutsideTracking` does not flag them; a painter that reads with
`peek` still gets the report-free stale read it asked for. The re-arming is
tied to painting: a render object that is invalidated but then never painted
again stops observing. In practice `markNeedsPaint` is always followed by a
paint, so this has not been worth guarding.

Note that a `Float32List` mutated in place is not a change any signal can see.
The idiom, used by B3 and the particle demo, is a `Signal<int>` generation
counter beside the buffer, bumped after the mutation and read inside `paint`.

**`FrameClock`.** Built on `Ticker`, so `muted` is the pause. It exposes
`Signal<Duration> time`, `Signal<int> frame` and `Signal<double> alpha`, runs
a fixed-timestep accumulator, and calls `simulate(dt)` with `dt` in seconds.
The whole tick — every simulation step and all three clock writes — happens
inside one `batch`, so a frame that writes ten thousand signals produces
exactly one flush, at the frame's existing pre-build flush point. The default
constructor owns a bare `Ticker` and needs no widget;
`FrameClock.withVsync(vsync: ...)` takes one from a `TickerProvider`.

The hot path allocates nothing: the tick callback and the batch body are
method references held in fields rather than closures built per frame, the
accumulator is integer microseconds, and no list or map is touched. What
remains is the three signal writes per frame, which reuse their graph edges.
A `_maxCatchUp` of 250 ms bounds how much real time one frame may simulate, so
a frame delayed by a breakpoint runs the simulation slow instead of locking
up. Resuming from `paused` discards the time spent paused rather than
simulating it.

**What is not reactive, and what is unsupported.**

- Only the properties listed above are props. Everything else on a reactive
  widget — `alwaysIncludeSemantics`, `transformHitTests`, `textAlign`,
  `maxLines`, `Directionality`, `MediaQuery.textScalerOf` — is an ordinary
  field, read in `createRenderObject` and `updateRenderObject`, and changes
  only when the widget is replaced. That is deliberate: they change with the
  configuration, not with the frame.
- There is no reactive multi-child widget. `For` is the multi-child case, and
  it reconciles rather than binding props.
- `RenderTransform.transform` copies the matrix it is given, so mutating one
  matrix in place and expecting the render object to follow does not work.
  `ReactiveOffset` is the allocation-free path for the translate-only case.
- A reactive prop cannot read an `InheritedWidget`: an effect has no
  `BuildContext` and is not part of a build, so `dependOnInheritedWidgetOfExactType`
  has nothing to attach to. Inherited values reach a reactive widget the
  ordinary way, through `createRenderObject` and `updateRenderObject`.
- Hot reload re-runs `createRenderObject`/`updateRenderObject` through the
  normal reassemble path, but a binding's effect is not re-created, so a
  reloaded prop closure only takes effect if the widget is replaced. This is
  the Phase 3 instance of the hot-reload problem section 6 describes.

**Numbers.** Full table, protocol and caveats in
[`BENCHMARKS.md`](BENCHMARKS.md). Every row below was measured in the same
process as the baseline it is compared against, with the same number of render
objects per item on both sides, interleaved and rotated so that position in
the file cannot masquerade as a result (2026-09-04, idle machine,
`flutter test -j 1`, one file at a time, three process runs, median of the
three run medians, µs per `pump()`):

| Scenario | best practice | Phase 3 leaf | vs | rebuilds per write |
| --- | --- | --- | --- | --- |
| B1, one of 10,000 sprites | 7005 | 6359 | 1.10x | 0, was 1 |
| B2, all 10,000 sprites, one batch | 33851 | 16109 | **2.10x** | 0, was 10,000 |
| B3, 50,000 particles | 332 | 340 | 0.98x | 0 |
| B4, text leaf at depth 50 | 318 | 267 | **1.19x** | 0, was 1 |
| B5, leaf at depth 100 | 352 | 294 | **1.20x** | 0, was 1 |
| B6, one of 1,000 rows | 392 | 375 | 1.05x | 0, was 1 |
| B8, mount 10,000 reactive leaves | 737172 | 749281 | 0.98x | n/a |
| B8, unmount 10,000 reactive leaves | 4815 | 6673 | 0.72x | n/a |

Four of these deserve to be stated plainly rather than left to a table.

*B1 did not improve much, and the prediction in section 8 that it would gain an
order of magnitude was wrong.* Laying out and painting a `Stack` of 10,000
`Positioned` children costs 6–7 ms per frame whatever changed, so removing the
last rebuild out of ten thousand elements is barely measurable against it.
Phase 3 takes B1's rebuild count from one to zero and its wall clock 10%. B4
and B5, which have no such denominator, are where the same mechanism shows
1.19x and 1.20x.

*B2 is where the mechanism shows.* When all 10,000 sprites change, the
baseline runs 10,000 builder closures, allocates 10,000 widgets and diffs
10,000 children; the leaf variant runs 10,000 effects, each writing one field
on a render object, all in one batch and one flush. 2.10x, and it is a real
difference in what the frame does.

*Reactive leaves cost slightly more to set up and tear down than plain ones,
and the earlier claim that they cost less was a shape artefact.* An owner, an
effect and a graph edge per leaf are not free: 0.98x on mount and 0.72x on
unmount against a plain `ColoredBox` with the same render-object count. The
old "1.4x cheaper to mount" used `Container` as the baseline, which is a
`StatelessWidget` and adds a component element per node, so it measured a
missing element rather than the effect machinery.

*B3 is parity, and that is a pass.* Replacing a hand-wired
`CustomPainter`-plus-`Listenable` with one batched signal write is within a
few percent either direction of the baseline — parity, not a regression.

*The B2 ceiling row is deliberately not in this table.* One
`ReactiveCustomPaint` drawing all 10,000 positions costs 176 µs, but it does
one signal write and one repaint where every other B2 row does 10,000 writes
into 10,000 render objects. It is a different workload, so `BENCHMARKS.md`
reports it without a ratio against anything. What it says qualitatively —
almost all of the per-sprite cost is the framework's own per-node layout and
paint — is the case for Phase 4, and Phase 4's own B9 rows measure it properly,
on the same workload.

**Ergonomics: `implicit_call_tearoffs` fights the callable-signal design.**
Phase 0 made `Signal` callable so that `ReactiveOpacity(opacity: myOpacity)`
would work with no boilerplate, and it does — but the repo's
`analysis_options.yaml` enables `implicit_call_tearoffs` (line 126), which
reports passing a callable object where a function is expected and asks for an
explicit `myOpacity.call`. Every prop site in this fork's own tests,
benchmarks and demo therefore writes `.call`, which is exactly the boilerplate
the design set out to remove. Two ways out, neither taken here because both
are policy calls rather than code: remove that one lint from the fork's
`analysis_options.yaml`, or accept `.call` and let Phase 6's compile step
remove it. This is the strongest argument yet found for Phase 6 — or, more
cheaply, for deleting one line.

### Phase 4 — Scene mode

**Deliverable.** A retained scene graph driven entirely by signals, rendering
through `dart:ui` with no widget, element, or render object per node.

```dart
/// Embeds a signal-driven scene in the classic tree. One RenderObject.
class SceneView extends LeafRenderObjectWidget {
  const SceneView({super.key, required this.root});
  final SceneNode root;
}

/// A node in the retained scene. Props are reactive; there is no build().
class SpriteNode extends SceneNode {
  SpriteNode({
    required this.image,
    required this.x,        // Prop<double>
    required this.y,
    this.opacity,
  });
  // ...
}
```

Each node holds its own `Picture`, recorded through `PictureRecorder`
(`painting.dart` 8604) into a `Canvas` (6869). An effect per reactive prop
marks the node dirty. Once per frame the scene walks its dirty set, re-records
only dirty nodes, and composes with `SceneBuilder` (`compositing.dart` 259) —
`pushTransform` (657), `pushOpacity` (804), `addPicture` (1014) — then
`build()` (1073) and `FlutterView.render` (`window.dart` 380).

Transform and opacity changes do not require re-recording at all: they are
scene-builder parameters, so those props update by marking the node's
*composition* dirty rather than its picture.

The precedent is Flame, which owns a single render object and draws its world
inside it. The differences here are per-node signal bindings, a dirty set, and
picture retention, so an unchanged node costs one `addPicture` call rather
than a re-record.

**What you give up inside a scene**, restated because it is easy to forget:
hit testing (must be implemented as a spatial query over the scene),
semantics (must be built by hand or omitted), focus, and text layout. For a
game these are mostly acceptable; scene mode is not a general UI replacement
and should not be described as one.

**What breaks.** Nothing. `SceneView` is one more widget.

#### As implemented

**Files.** `packages/flutter/lib/src/reactive_scene/scene.dart` (compositors,
nodes, `ReactiveScene`, `SceneDriver`) and `scene_view.dart` (`SceneView`,
`RenderSceneView`), exported from `packages/flutter/lib/reactive_scene.dart`
as its own library rather than from `widgets.dart`: scene mode is opt-in and
does not belong in every app's import. Tests are
`packages/flutter/test/reactive_scene/`, the benchmark is
`dev/benchmarks/microbenchmarks/test/reactivity/b9_scene_mode_test.dart`, and
the design write-up with the numbers is
[`SCENE_MODE.md`](SCENE_MODE.md). No existing framework file changed.

**The API differs from the sketch above in three ways.**

*`SceneView` takes a scene, not a root node* — `SceneView(scene: scene)` over
`ReactiveScene(rootNode)`. The scene is what owns the cull rectangle, the
dirty flag, hit testing and the orphan list, and it is what a `SceneDriver`
drives; a bare root node has nowhere to put any of that. A scene may be shown
by several `SceneView`s at once.

*Props are `T Function()`, not `Prop<T>`.* Phase 3's `Prop` exists to accept
either a plain value or a reactive one at a widget boundary. A scene node has
no `const` constructor to preserve and no rebuild to skip, so the plainest
type that a callable `Signal` satisfies directly is the whole of it:
`RectNode(x: xSignal, y: () => base.value + bob.value, ...)`.

*There is no `pushOffset` and no dirty set.* Both were in the sketch by
implication and both were removed after measurement. The plan said the scene
"walks its dirty set"; the shipped walk is unconditional and O(nodes), reading
six cached fields per node and allocating nothing but the `ui.Offset` that
`SceneBuilder.addPicture` demands. Composition changes therefore keep no dirty
state at all — they only ask for a frame. What *is* retained is the half that
pays: each node's `ui.Picture`, re-recorded only when a signal the recording
read changes, plus its `TransformEngineLayer`/`OpacityEngineLayer` handed back
as `oldLayer` in standalone mode. A per-node offset layer, the obvious way to
place a node, cost 15,200 µs per frame at ten thousand nodes against 2,500 µs
for adding the pictures at an accumulated offset (the two measured against each
other in one session, under the older sequential harness — a 6x gap is far
larger than that harness's ordering bias, so the conclusion stands even though
the exact figures were not re-measured), so translation is folded
into `addPicture` and only rotation, scale and opacity push a layer.

**Two embeddings, as promised.** Standalone `scene.attachToView(view)` returns
a `SceneDriver` that owns `onBeginFrame`/`onDrawFrame`/`onPointerDataPacket`
and `signalFlushScheduler`, saving and restoring whatever held them before; it
asserts that nothing already drives frames, because standalone mode is for
applications with no `WidgetsBinding`. Embedded `SceneView` paints into
`PaintingContext.canvas` and relies on the binding's pre-build signal flush,
so a write made after that flush composes one frame late.

**What it costs, honestly** (full numbers in `SCENE_MODE.md`, all measured in
the same process as the classic-tree rows they are compared against, on the
same paint-only move workload): embedded — a whole framework frame on both
sides — scene mode is **2.64x** Phase 3's leaf bindings on moving one of ten
thousand and **5.60x** on moving all ten thousand in one batch, and its
headless path, which is what a standalone game runs, is 6.98x and 7.78x.
Mounting, composing and disposing ten thousand nodes is **19.4x** cheaper than
ten thousand widget + element + render-object triples. Moving *one* of ten
thousand is the smallest win, because both the classic tree and the scene still
re-walk ten thousand somethings rather than skipping unchanged nodes.

**Open problems**, none of which the plan anticipated: the walk is O(nodes)
every frame with nothing retaining an unchanged subtree (`addRetained` would
mean rebuilding `rendering/layer.dart`); embedded mode has no per-node engine
retention at all; a node's bounds are unknown until it has recorded once, so a
node created off-screen records anyway; there is no pointer capture, no
gesture arena and no semantics; and a scene is invisible to the widget
inspector, which is section 6's DevTools warning made concrete.

### Phase 5 — Collapsing Widget and Element

**Deliverable, first: a spike, not a migration.** Build the collapsed model for
a small vertical slice — a handful of leaf widgets plus `Show` and `For` — and
measure it against the phase-3 leaf-binding numbers on B1–B6.

The question the spike answers is narrow and quantitative: **how much does
removing widget allocation and `build()` re-execution add, on top of leaf
bindings?** If the answer is single-digit percent for realistic UI, phase 5
should not happen, and the fork's identity becomes "classic tree with
fine-grained leaves plus scene mode for games", which is a defensible place to
stop.

If the answer is large, the design is:

- One retained node type. Created once, by a component function that runs
  once. Props are bindings, not fields on a re-allocated record.
- Children are created, not diffed. Structure changes only through `Show`,
  `For`, and their relatives.
- `Key` and `GlobalKey` need a new meaning; today they exist to steer the
  diff, and there is no diff.
- Material and Cupertino must be ported. This is the bulk of the work and is
  what makes the step irreversible.

**Verification.** The spike is judged on benchmark deltas alone. The migration,
if it happens, is judged on the framework test suite, which will need
substantial rewriting.

**What breaks.** Potentially everything downstream of `Widget`. This phase
does not begin without a written decision recording the spike's numbers.

#### As implemented

**The spike was built and measured; the migration was not, and will not be.**
`packages/flutter/lib/reactive_nodes.dart` over `src/reactive_nodes/nodes.dart`
and `node_host.dart`: `RNode`, `RComponent`, the primitives (`RBox`, `ROffset`,
`RPadding`, `ROpacity`, `RRepaintBoundary`, `RText`, `RStack` + `RPositioned`),
control flow (`RShow`, `RFor`), and `NodeHost`. No existing framework file was
edited.

**Numbers**, re-derived 2026-09-04 from interleaved, in-process,
shape-matched measurements — the collapsed variants now live in B1, B2, B4, B5,
B6, B8 and B9 next to the rows they are compared against, not in a file of
their own:

| Scenario | Phase 3 leaf | Phase 5 collapsed | vs |
| --- | --- | --- | --- |
| B1, one of 10,000 sprites | 6359 | 6414 | 0.99x |
| B2, all 10,000, one batch | 16109 | 11743 | **1.37x** |
| B4, text leaf at depth 50 | 267 | 273 | 0.98x |
| B5, leaf at depth 100 | 294 | 297 | 0.99x |
| B6, one of 1,000 rows | 375 | 383 | 0.98x |
| B9, move one of 10,000 | 12695 | 11459 | 1.11x |
| B9, move all 10,000 | 42538 | 40677 | 1.05x |
| B8, mount 10,000 | 749281 | 423757 | **1.77x** |
| B8, unmount 10,000 | 6673 | 2883 | **2.31x** |

**The gate fires.** This section's bar is "single-digit percent for realistic
UI". On the four UI-shaped rows — B1, B4, B5, B6 — the answer is -2% to -1%.
The wins are confined to an all-ten-thousand-sprites batch and to mount and
teardown, and embedded scene mode is 2.38x to 5.36x better than the collapsed
model on the same workloads in the same process. **Phase 5 does not happen.**
The full write-up, including what is worth keeping from the spike
(component-once effect semantics, `RPositioned`'s rule that layout inputs are
not props, `NodeHost` as a pattern), is in
[`PHASE5_DECISION.md`](PHASE5_DECISION.md).

### Phase 6 — Optional compile step

**Deliverable.** Only if prop ergonomics prove to be a real obstacle.

Because `Signal<T>` is callable (phase 0), the common case is already
boilerplate-free: `Opacity(opacity: myOpacity)`. The remaining boilerplate is
derived expressions, `() => a.value * b.value`, which a compile step could
insert automatically.

A kernel transformer would do this. Note that
`track_widget_constructor_locations.dart`, the existing precedent for a
framework-aware kernel transform, is **not present in this checkout**: it
lives in the Dart submodule, which is not checked out. The
`--track-widget-creation` flag flow through
`packages/flutter_tools/lib/src/compile.dart` (278, 363, 776, 980) shows how
such a transformer is plumbed, but the transformer source has to be obtained
before any of this is possible.

This phase is deliberately last and deliberately optional. Explicit `() =>` is
ugly, not broken.

## 6. Cross-cutting concerns

**Hot reload.** `BuildOwner.reassemble` (3352, 3466) and
`Element.reassemble` (3767) walk the tree and rebuild everything, via
`WidgetsBinding.performReassemble` (1701) and
`foundation/binding.dart` `reassembleApplication` (719). Under a reactive
model, "rebuild everything" must also mean "dispose and re-create every
effect", or reloaded closures will keep running. Under phase 5, where
components run once, hot reload is a genuinely hard open problem: there is no
re-execution to piggyback on. SolidJS has the same problem and solves it with
a bundler-level HMR protocol that re-creates component instances.

**DevTools.** The widget inspector walks the element tree and reports rebuild
counts. Leaf bindings that never rebuild anything are invisible to it, which
looks like a bug to the user ("nothing is rebuilding, but the screen is
changing"). A signal-graph inspector view is needed eventually; before that,
at minimum a debug flag that logs signal writes and effect runs.

**Error handling.** An exception inside an effect has no build context to
attach to. Effects must report through `FlutterError.reportError` with the
owning element's diagnostics, or debugging becomes guesswork.

**Async.** Signal writes from a `Future` or `Stream` callback land in `idle`
phase and schedule a frame. This works, but a write during
`midFrameMicrotasks` is subtly different from one during `idle`, and the
distinction needs a test rather than an assumption.

**Testing.** `WidgetTester.pump` drives frames, so the frame-scheduled flush
works in tests unchanged. But `flushSync` must exist for tests that write a
signal and assert without pumping, and its existence will be abused; document
it as test-only.

**Threading.** Signals are single-isolate. Nothing here changes that, and
nothing should pretend otherwise.

## 7. Engineering risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A1 false: per-element tracking is measurable | Phase 2 dies; reactivity stays opt-in, which contradicts requirement 3 | Measure against B7 before building on phase 2 |
| Deferred flush changes observable ordering | Widespread subtle test failures | Land phase 1 alone, read every failure individually, do not batch with phase 2 |
| Effect leaks on element reparenting | Growing memory, stale writes | `GlobalKey` reparenting test as a gate on phase 1; deactivate pauses, unmount disposes |
| Signal write during layout or paint | Assert failure, or a frame of lag | Phase asserts keyed on `SchedulerPhase`; documented single flush point |
| Scene mode grows into a second framework | Unbounded scope | Scene mode explicitly does not do semantics, focus, or text; that is a feature |
| Phase 5 attempted on conviction rather than data | Irreversible loss of Material compatibility | Spike with mandatory numeric gate before any migration |
| Rebase conflicts in `framework.dart` | Ongoing tax | Section 10 |
| Hot reload semantics under phase 5 | Developer experience collapse | Treat as a gating question for phase 5, not a follow-up |

## 8. Honest performance assessment

What will actually get faster, and by how much, stated before measuring so the
predictions can be wrong on the record.

- **Large win, phase 3.** One property changing in a large tree: today this
  rebuilds an element subtree and re-allocates widgets; with a leaf binding it
  is one setter call and one `markNeedsCompositedLayerUpdate`. Order of
  magnitude on B1 and B4. This is the phase that justifies the fork.
- **Large win, phase 4.** Games. Removing three framework objects per sprite
  removes both the per-frame work and the memory that made it slow. B9.
- **Moderate win, phase 1.** Replacing `InheritedWidget` notification with the
  signal graph: `notifyClients` (6427) already walks only dependents, so the
  gain is from finer dependency granularity, not from the walk itself. B6.
- **No win, possibly a small loss, phase 2.** Adding tracking to every build
  cannot make builds faster. The goal is that the loss is unmeasurable. B7.
- **Unknown, phase 5.** Genuinely unknown, which is the entire reason it is
  behind a spike. Widget allocation is young-generation and Dart's scavenger is
  fast; removing it may matter far less than intuition suggests.
- **Nothing changes about raster time.** None of this makes the GPU faster.
  Applications that are raster-bound will see no improvement at all, and it is
  worth saying so to avoid the fork being oversold to its own author.

## 9. What is deliberately not being built

- No `SignalBuilder`, no `Observer`, no reactive wrapper widget of any kind.
- No async signals, resources, or suspense in the early phases. They are a
  library concern; the framework needs `Signal`, `Computed`, `Effect`, and
  owners.
- No new dependency injection or "provider" mechanism. Owner scopes plus
  `InheritedWidget`-on-signals cover it.
- No web-first work. Impeller and the native canvas paths come first.

## 10. Fork maintenance

Rebasing onto upstream stable tags is a permanent, recurring cost, and it is
the main reason to keep the diff small and concentrated.

- **Concentrate the diff.** New code goes in new files
  (`foundation/signals.dart`, and later `widgets/reactive.dart`,
  `rendering/scene.dart`). Edits to existing files should be as few and as
  small as possible: ideally one hook in `performRebuild`, one flush call in
  `drawFrame`, one field on `Element`.
- **`framework.dart` is the conflict hotspot.** It is where upstream is most
  active and where this fork changes most. Every edit there should be
  justifiable in one sentence.
- **Rebase, do not merge.** A linear stack of fork commits on top of an
  upstream tag stays reviewable; a merge history does not.
- **Rebase cadence: each stable tag.** Skipping releases compounds conflicts
  superlinearly.
- **The engine is not forked** (assumption A5). This is what keeps the
  `bin/cache` symlink valid and avoids a multi-hour engine build. If a phase
  requires an engine change, that is a separate decision with a very different
  cost profile, and phase 4 should be designed to avoid needing one.
- **Test drift.** Upstream adds tests that assert old rebuild semantics.
  Expect to carry a growing list of intentionally-modified tests, and keep
  that list in one place so a rebase can distinguish "we changed this on
  purpose" from "we broke this".
