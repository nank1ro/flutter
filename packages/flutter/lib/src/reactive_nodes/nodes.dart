// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// The collapsed node model: one retained object per node, no widgets.
///
/// This is the Phase 5 spike of `docs/fine_grained_reactivity/PLAN.md`, option
/// (b) of section 4: Widget and Element are one retained [RNode]. A component
/// function runs exactly once, properties are `T Function()` bindings applied
/// by one effect each straight to a [RenderObject] setter, and children are
/// created rather than diffed. There is no `build()`, no `updateChild`, and no
/// widget allocated per update.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../widgets/reactive_props.dart' show Prop;
import '../widgets/reactive_widgets.dart' show RenderReactiveColoredBox, RenderReactiveOffset;

export '../widgets/reactive_props.dart' show Prop;
export '../widgets/reactive_widgets.dart' show RenderReactiveColoredBox, RenderReactiveOffset;

/// A component: a function that builds a node tree, run exactly once.
///
/// This is the SolidJS reading of a component, and the point where the
/// divergence Phase 2 documented disappears: an [Effect] created in the body
/// runs once per component *instance*, because the body is never re-executed.
typedef Component = RNode Function();

/// One retained node: the whole of what a `Widget` and an `Element` are in the
/// classic tree, collapsed into a single object that owns a [RenderObject].
///
/// A node is created once and lives until it is disposed. Its reactive
/// properties are bound with [bind], which creates one [Effect] per property
/// writing straight to a render-object setter; nothing rebuilds, and no
/// configuration object is allocated on a change. Structure changes only
/// through [RShow] and [RFor].
///
/// Each node owns a detached [Owner]. Everything created under it — the
/// property effects, and any effect a component body creates — is disposed
/// with the node.
///
/// A node owns its render object. Dispose a node only once its render object
/// has been removed from whatever hosts it: [dispose] disposes the render
/// object too.
abstract class RNode {
  /// Creates a node.
  RNode();

  /// The lifetime scope of everything this node creates.
  ///
  /// Detached, so that whatever scope happened to be running when the node was
  /// created — a parent's binding effect, say — does not own it. The node's
  /// parent disposes it explicitly instead.
  final Owner owner = Owner.detached();

  /// The render object this node drives.
  ///
  /// Created once, in the node's constructor, and never replaced.
  RenderBox get renderObject;

  /// The child nodes this node created and is responsible for disposing.
  @protected
  Iterable<RNode> get children => const <RNode>[];

  /// Whether [dispose] disposes [renderObject].
  ///
  /// False for a node that borrows its child's render object rather than
  /// owning one, such as [RPositioned].
  @protected
  bool get ownsRenderObject => true;

  /// Binds a reactive property to a render-object setter.
  ///
  /// The effect runs immediately, so the render object holds the property's
  /// real value before anything lays it out, and again whenever a reactive
  /// value the property read changes. The effect belongs to [owner], not to
  /// whatever scope is running, so a node created inside another node's
  /// binding is not torn down when that binding re-runs.
  @protected
  void bind<T>(Prop<T> prop, ValueSetter<T> apply) {
    owner.run<Effect>(() => Effect(() => apply(prop())));
  }

  /// Called by the parent node once this node's render object has been
  /// inserted into the parent's.
  ///
  /// This is where a node that writes its parent's parent data does so; see
  /// [RPositioned].
  @protected
  @mustCallSuper
  void didInsertIntoParent() {}

  /// Removes the render objects of [children] from [renderObject].
  ///
  /// Called by [dispose] before the children are disposed, so that a container
  /// never leaves a disposed render object parented to a live one. A node that
  /// does not parent its children's render objects — [RComponent],
  /// [RPositioned] — has nothing to do here.
  @protected
  void dropChildRenderObjects() {}

  /// Disposes this node, its children, its bindings and its render object.
  ///
  /// Precondition: [renderObject] must already have been removed from whatever
  /// hosts it — a [NodeHost], or a parent node. A child disposed as part of its
  /// parent's [dispose] satisfies this, because the parent drops its children's
  /// render objects first.
  @mustCallSuper
  void dispose() {
    assert(!_disposed, 'A node was disposed twice.');
    if (_disposed) {
      return;
    }
    assert(
      renderObject.parent == null,
      'A node was disposed while its render object was still parented. Remove it '
      'from its host first: disposing it here would leave the host pointing at a '
      'disposed render object.',
    );
    _disposed = true;
    owner.dispose();
    dropChildRenderObjects();
    for (final RNode child in children) {
      child.dispose();
    }
    if (ownsRenderObject) {
      renderObject.dispose();
    }
  }

  bool _disposed = false;
}

/// A node with one child node, whose render object it adopts.
abstract class RSingleChildNode extends RNode {
  /// Creates a node wrapping [child], and inserts the child's render object
  /// into this node's.
  RSingleChildNode({this.child}) {
    final RNode? child = this.child;
    if (child != null) {
      (renderObject as RenderObjectWithChildMixin<RenderBox>).child = child.renderObject;
      child.didInsertIntoParent();
    }
  }

  /// The child node, or null for a leaf.
  final RNode? child;

  @override
  Iterable<RNode> get children => child == null ? const <RNode>[] : <RNode>[child!];

  @override
  void dropChildRenderObjects() {
    if (child != null) {
      (renderObject as RenderObjectWithChildMixin<RenderBox>).child = null;
    }
  }
}

/// Runs a [Component] body once, under its own owner, and adopts the node it
/// returned.
///
/// This is where per-instance effect semantics come from. The body runs inside
/// [RNode.owner], so an [Effect] created directly in it runs once for this
/// instance and is disposed with it — SolidJS `createEffect` semantics, which
/// the classic tree cannot offer because `build` re-runs.
///
/// The body is *not* tracked: reading a signal directly in a component body
/// subscribes nothing, because there is nothing to re-run.
///
/// ```dart
/// RNode counter(Signal<String> value) {
///   return RComponent(() {
///     Effect(() => debugPrint('mounted or changed: ${value.value}'));
///     return RText(value);
///   });
/// }
/// ```
class RComponent extends RNode {
  /// Runs [body] once and wraps the node it returned.
  RComponent(Component body) {
    _child = owner.run<RNode>(body);
  }

  late final RNode _child;

  /// The node the component body returned.
  RNode get child => _child;

  @override
  RenderBox get renderObject => _child.renderObject;

  @override
  Iterable<RNode> get children => <RNode>[_child];

  @override
  bool get ownsRenderObject => false;
}

// ---------------------------------------------------------------------------
// Leaf and single-child primitives.
// ---------------------------------------------------------------------------

/// Fills its bounds with a reactive colour, then paints its child.
///
/// The collapsed-model twin of `ReactiveColoredBox`, and it reuses that
/// widget's render object.
class RBox extends RSingleChildNode {
  /// Creates a node that fills its bounds with [color].
  RBox({required this.color, super.child}) {
    bind<Color>(color, (Color value) => renderObject.color = value);
  }

  /// The fill colour.
  final Prop<Color> color;

  @override
  final RenderReactiveColoredBox renderObject = RenderReactiveColoredBox(
    color: const Color(0x00000000),
  );
}

/// Paints its child shifted by a reactive offset, without touching layout.
///
/// The sprite primitive: moving one of ten thousand of these marks exactly one
/// render object as needing paint.
class ROffset extends RSingleChildNode {
  /// Creates a node that paints its child at [offset].
  ROffset({required this.offset, super.child}) {
    bind<Offset>(offset, (Offset value) => renderObject.offset = value);
  }

  /// The offset, in logical pixels, to paint the child at.
  final Prop<Offset> offset;

  @override
  final RenderReactiveOffset renderObject = RenderReactiveOffset();
}

/// Insets its child by a reactive amount.
class RPadding extends RSingleChildNode {
  /// Creates a node that insets its child by [padding].
  RPadding({required this.padding, TextDirection textDirection = TextDirection.ltr, super.child})
    : renderObject = RenderPadding(padding: EdgeInsets.zero, textDirection: textDirection) {
    bind<EdgeInsetsGeometry>(padding, (EdgeInsetsGeometry value) => renderObject.padding = value);
  }

  /// The amount of space to inset the child by.
  final Prop<EdgeInsetsGeometry> padding;

  @override
  final RenderPadding renderObject;
}

/// Makes its child partially transparent, by a reactive amount.
class ROpacity extends RSingleChildNode {
  /// Creates a node that paints its child with [opacity].
  ROpacity({required this.opacity, super.child}) {
    bind<double>(opacity, (double value) => renderObject.opacity = value);
  }

  /// The fraction to multiply the child's alpha by, between 0 and 1.
  final Prop<double> opacity;

  @override
  final RenderOpacity renderObject = RenderOpacity();
}

/// Isolates its child's painting behind its own layer.
class RRepaintBoundary extends RSingleChildNode {
  /// Creates a repaint boundary around [child].
  RRepaintBoundary({super.child});

  @override
  final RenderRepaintBoundary renderObject = RenderRepaintBoundary();
}

/// A run of reactive text.
///
/// [data] and [style] are bound together as one [InlineSpan], because
/// [RenderParagraph.text] takes the whole span. Everything else — alignment,
/// direction, wrapping — is a plain constructor argument: it belongs to the
/// node's shape, which never changes, not to the frame.
///
/// There is no [Directionality] here to read: a node has no `BuildContext`,
/// which is one of the things this spike measures the cost of.
class RText extends RNode {
  /// Creates a run of text showing [data].
  RText(
    this.data, {
    this.style,
    TextDirection textDirection = TextDirection.ltr,
    TextAlign textAlign = TextAlign.start,
    bool softWrap = true,
    TextOverflow overflow = TextOverflow.clip,
    int? maxLines,
  }) : renderObject = RenderParagraph(
         const TextSpan(text: ''),
         textDirection: textDirection,
         textAlign: textAlign,
         softWrap: softWrap,
         overflow: overflow,
         maxLines: maxLines,
       ) {
    bind<InlineSpan>(_span, (InlineSpan value) => renderObject.text = value);
  }

  /// The text to display.
  final Prop<String> data;

  /// The style to display the text with.
  final Prop<TextStyle>? style;

  @override
  final RenderParagraph renderObject;

  InlineSpan _span() => TextSpan(text: data(), style: style?.call());
}

// ---------------------------------------------------------------------------
// Multi-child and positioning.
// ---------------------------------------------------------------------------

/// Stacks its children, each optionally positioned by an [RPositioned].
class RStack extends RNode {
  /// Creates a stack of [children], in paint order.
  RStack({
    required List<RNode> children,
    AlignmentGeometry alignment = AlignmentDirectional.topStart,
    TextDirection textDirection = TextDirection.ltr,
    StackFit fit = StackFit.loose,
    Clip clipBehavior = Clip.hardEdge,
  }) : _children = List<RNode>.of(children),
       renderObject = RenderStack(
         alignment: alignment,
         textDirection: textDirection,
         fit: fit,
         clipBehavior: clipBehavior,
       ) {
    for (final RNode child in _children) {
      renderObject.add(child.renderObject);
      child.didInsertIntoParent();
    }
  }

  final List<RNode> _children;

  @override
  Iterable<RNode> get children => _children;

  @override
  final RenderStack renderObject;

  @override
  void dropChildRenderObjects() {
    renderObject.removeAll();
  }
}

/// Positions its child inside an [RStack] or an [RFor].
///
/// Only legal directly under an [RStack] or an [RFor]: it writes
/// [StackParentData], which is what those two give their children. Anywhere
/// else — under an [RShow], an [RPadding], any [RSingleChildNode] — is an
/// error. Use [ROffset] to move the child of anything else.
///
/// The offsets are plain numbers rather than reactive properties, deliberately.
/// A position written into a parent's parent data is a layout input, so
/// changing it relayouts the whole stack, which is exactly what the fork tells
/// people not to do per frame; [ROffset] is the reactive, paint-only way to
/// move something. Making these props would also cost four effects per
/// positioned child for values that, in every workload measured here, never
/// change.
class RPositioned extends RNode {
  /// Creates a node that positions [child] within its parent stack.
  RPositioned({
    required this.child,
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.width,
    this.height,
  });

  /// The node being positioned. Its render object is this node's too.
  final RNode child;

  /// The distance from the left edge of the stack, if given.
  final double? left;

  /// The distance from the top edge of the stack, if given.
  final double? top;

  /// The distance from the right edge of the stack, if given.
  final double? right;

  /// The distance from the bottom edge of the stack, if given.
  final double? bottom;

  /// The child's width, if given.
  final double? width;

  /// The child's height, if given.
  final double? height;

  @override
  RenderBox get renderObject => child.renderObject;

  @override
  Iterable<RNode> get children => <RNode>[child];

  @override
  bool get ownsRenderObject => false;

  @override
  void didInsertIntoParent() {
    super.didInsertIntoParent();
    final RenderObject? parent = renderObject.parent;
    if (parent is! RenderStack) {
      throw FlutterError.fromParts(<DiagnosticsNode>[
        ErrorSummary('An RPositioned was inserted into a ${parent.runtimeType}.'),
        ErrorDescription(
          'RPositioned writes StackParentData, so it is only legal directly under an '
          'RStack or an RFor. Wrap it in an RStack, or use ROffset to move the child '
          'of anything else.',
        ),
      ]);
    }
    final parentData = renderObject.parentData! as StackParentData;
    parentData
      ..left = left
      ..top = top
      ..right = right
      ..bottom = bottom
      ..width = width
      ..height = height;
  }
}

// ---------------------------------------------------------------------------
// Structural control flow.
// ---------------------------------------------------------------------------

/// Mounts one of two subtrees, chosen by a reactive condition.
///
/// Structure is the only thing that changes by re-execution in this model, and
/// this is one of the two places it happens. When [when] flips, the mounted
/// subtree is disposed — owners, effects and render objects — and the other one
/// is created.
///
/// [when] is the only dependency. [child] and [fallback] run untracked, so a
/// signal read *in the builder* is not a dependency and changing it does not
/// re-create the subtree; the nodes the builder returns must bind their own
/// props to stay reactive.
///
/// Each branch runs under its own detached [Owner], so a bare [Effect] a
/// builder creates lives as long as the mounted branch and is disposed when the
/// branch is swapped out.
class RShow extends RNode {
  /// Creates a node that mounts [child] while [when] is true.
  RShow({required this.when, required this.child, this.fallback}) {
    bind<bool>(when, _apply);
  }

  /// Whether to mount [child].
  final Prop<bool> when;

  /// Builds the subtree mounted when [when] is true.
  final Component child;

  /// Builds the subtree mounted when [when] is false. Defaults to nothing.
  final Component? fallback;

  RNode? _mounted;
  Owner? _branchOwner;

  /// The currently mounted subtree, or null when neither branch produced one.
  RNode? get mounted => _mounted;

  @override
  final RenderProxyBox renderObject = RenderProxyBox();

  @override
  Iterable<RNode> get children => _mounted == null ? const <RNode>[] : <RNode>[_mounted!];

  @override
  void dropChildRenderObjects() {
    renderObject.child = null;
  }

  @override
  void dispose() {
    super.dispose();
    _branchOwner?.dispose();
    _branchOwner = null;
  }

  void _apply(bool visible) {
    final RNode? previous = _mounted;
    if (previous != null) {
      renderObject.child = null;
      _mounted = null;
      previous.dispose();
    }
    _branchOwner?.dispose();
    // Detached, so the branch is owned by the swap rather than by this binding
    // effect, which would dispose it on the next run.
    final branch = Owner.detached();
    _branchOwner = branch;
    // `Owner.run` does not track, so the builder's reads are not dependencies.
    final RNode? next = branch.run<RNode?>(() => visible ? child() : fallback?.call());
    if (next != null) {
      _mounted = next;
      renderObject.child = next.renderObject;
      next.didInsertIntoParent();
    }
  }
}

/// Mounts one child node per item of a reactive list, reconciled by key.
///
/// The other place structure changes. Only the list read is tracked, and a key
/// that is already mounted is left completely alone: [builder] is not called
/// for it, nothing rebuilds, and its node and render object are the same
/// objects as before. New keys are built, removed keys are disposed, and moved
/// keys have their render object moved within the stack.
///
/// Children are laid out as a stack, for the same reason `For` does it in
/// Phase 3: a multi-child node has to own a render object that lays its
/// children out, and a stack is the right layout for a scene of independently
/// positioned things.
class RFor<T> extends RNode {
  /// Creates a node that mounts one child per item of [each].
  RFor({
    required this.each,
    required this.keyOf,
    required this.builder,
    AlignmentGeometry alignment = AlignmentDirectional.topStart,
    TextDirection textDirection = TextDirection.ltr,
    StackFit fit = StackFit.loose,
    Clip clipBehavior = Clip.hardEdge,
  }) : renderObject = RenderStack(
         alignment: alignment,
         textDirection: textDirection,
         fit: fit,
         clipBehavior: clipBehavior,
       ) {
    bind<List<T>>(each, _reconcile);
  }

  /// The reactive list of items.
  final Prop<List<T>> each;

  /// The identity of an item, used to match it against a mounted child.
  ///
  /// Keys must be unique within one list, and are compared with `==`. Runs
  /// untracked, like [builder].
  final Object Function(T item) keyOf;

  /// Builds the node for an item. Called once per key, when the key first
  /// appears.
  ///
  /// Runs under the item's own detached [Owner], so a bare [Effect] the builder
  /// creates lives as long as the item and is disposed when its key leaves the
  /// list — not on the next reconcile.
  final RNode Function(T item) builder;

  @override
  final RenderStack renderObject;

  Map<Object, _ForItem> _byKey = <Object, _ForItem>{};
  List<RNode> _order = <RNode>[];

  @override
  Iterable<RNode> get children => _order;

  @override
  void dropChildRenderObjects() {
    renderObject.removeAll();
  }

  @override
  void dispose() {
    super.dispose();
    for (final _ForItem item in _byKey.values) {
      item.owner.dispose();
    }
    _byKey = const <Object, _ForItem>{};
    _order = const <RNode>[];
  }

  _ForItem _build(T item) {
    final owner = Owner.detached();
    return _ForItem(owner, owner.run<RNode>(() => builder(item)));
  }

  void _reconcile(List<T> items) {
    final Map<Object, _ForItem> previous = _byKey;
    final next = <Object, _ForItem>{};
    final order = <RNode>[];
    Object? duplicateKey;
    // Keys and builders run untracked: a signal an item reads belongs to that
    // item's own bindings, not to this node's list dependency.
    untracked<void>(() {
      for (final item in items) {
        final Object key = keyOf(item);
        if (next.containsKey(key)) {
          // A second child under a key that is already taken could never be
          // matched again, so it is skipped rather than leaked. Reported below,
          // once the node is consistent.
          duplicateKey ??= key;
          continue;
        }
        final _ForItem entry = previous.remove(key) ?? _build(item);
        next[key] = entry;
        order.add(entry.node);
      }
    });
    for (final _ForItem stale in previous.values) {
      renderObject.remove(stale.node.renderObject);
      stale.node.dispose();
      stale.owner.dispose();
    }
    RenderBox? after;
    for (final node in order) {
      final RenderBox box = node.renderObject;
      if (box.parent == null) {
        renderObject.insert(box, after: after);
        node.didInsertIntoParent();
      } else if ((box.parentData! as StackParentData).previousSibling != after) {
        renderObject.move(box, after: after);
      }
      after = box;
    }
    _byKey = next;
    _order = order;
    if (duplicateKey != null) {
      // This runs inside the list binding's effect, which turns a throw into a
      // silent report, so report deliberately and with a message worth reading.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: FlutterError(
            'RFor.keyOf produced the duplicate key $duplicateKey. Keys must be '
            'unique within one list; the duplicate item was skipped.',
          ),
          library: 'reactive nodes library',
          context: ErrorDescription('while reconciling an RFor'),
        ),
      );
    }
  }
}

/// One mounted [RFor] item: the node, and the owner its builder ran under.
class _ForItem {
  _ForItem(this.owner, this.node);

  final Owner owner;
  final RNode node;
}
