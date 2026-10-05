// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// @docImport 'basic.dart';
/// @docImport 'reactive_widgets.dart';
library;

import 'package:flutter/foundation.dart';

import 'framework.dart';

/// A reactive property written as a closure: anything that produces a `T`
/// when called.
///
/// A property that can follow a reactive value is declared as a
/// [ReadonlySignal], which a [Signal], a [Computed] and a const
/// [ReadonlySignal.fixed] all satisfy. [Prop] remains for properties that take
/// a closure directly.
typedef Prop<T> = T Function();

/// The accessor behind a bound property, or null if it never changes.
///
///  * a [FixedSignal] never changes, so it needs no subscription: null;
///  * any other [ReadonlySignal], such as a [Signal] or a [Computed], has its
///    `call` torn off;
///  * a [Prop] is returned as it is.
Prop<T>? propOf<T>(Object value) {
  if (value is FixedSignal<T>) {
    return null;
  }
  if (value is ReadonlySignal<T>) {
    return value.call;
  }
  return value as Prop<T>;
}

/// Reads [value] now, without subscribing to anything it touches.
///
/// This is how a reactive property seeds its render object from
/// [RenderObjectWidget.createRenderObject], which runs outside any tracking
/// scope: the binding's own first run is what discovers the dependencies.
T readProp<T>(Object value) {
  final Prop<T>? prop = propOf<T>(value);
  return prop == null ? (value as FixedSignal<T>).value : untracked<T>(prop);
}

// -----------------------------------------------------------------------------
// The binding machinery.
// -----------------------------------------------------------------------------

/// One property of one widget, bound to one render object setter.
///
/// A binding holds an [Effect] only while the property it was given is
/// reactive. A static value needs no subscription, so it is written straight
/// through and any effect left over from a previous reactive value is
/// disposed. The prop closure lives in a field rather than being captured by
/// the effect, so that replacing it when the widget updates re-runs the
/// existing effect instead of allocating a new one. [_apply] is never
/// replaced: it writes to the element's render object, which does not change
/// for the element's lifetime.
final class _PropBinding<T> {
  _PropBinding(this._apply);

  final ValueSetter<T> _apply;

  /// The accessor this binding reads, or null while the bound value is static.
  Prop<T>? _prop;

  /// The effect that re-reads [_prop], or null while the bound value is
  /// static.
  Effect? _effect;

  void _run() => _apply(_prop!());

  /// Points this binding at [value], anything [propOf] recognises.
  ///
  /// An equal prop closure is ignored, which is the case that matters: a
  /// [Signal] passed straight to a property tears off `call` on the same
  /// object every time, and two such tear-offs are equal, though not
  /// identical, so an update that changes nothing else costs one comparison.
  void _set(Owner owner, Object value) {
    final Prop<T>? prop = propOf<T>(value);
    if (prop == null) {
      _effect?.dispose();
      _effect = null;
      _prop = null;
      _apply(readProp<T>(value));
      return;
    }
    if (_effect == null) {
      _prop = prop;
      // The effect runs on construction, which is what reads the prop and
      // writes the render object for the first time.
      owner.run<void>(() => _effect = Effect(_run));
      return;
    }
    if (prop == _prop) {
      return;
    }
    _prop = prop;
    // Not `onInvalidate`: this happens outside the effect flush, and re-arming
    // an effect that is already queued would corrupt the queue.
    _effect!.rerun();
  }
}

/// Collects the properties of a [ReactiveRenderObjectWidget].
///
/// One binder belongs to one element and is reused for its whole life. Each
/// call to [bind] matches up with the call made at the same position last
/// time, which is why [ReactiveRenderObjectWidget.bindProps] must always bind
/// the same properties in the same order. Whether a given property is
/// currently reactive may change freely: that is a property of the value, not
/// of the slot.
final class PropBinder {
  PropBinder._(this.context, this._owner);

  /// The element whose properties are being bound.
  ///
  /// A [ReactiveRenderObjectWidget.bindProps] implementation may read an
  /// inherited widget from here: binding happens from `mount`, `update` and
  /// `performRebuild`, so the dependency is registered exactly as one read
  /// during a build would be, and a change to the inherited widget marks the
  /// element dirty, which rebinds.
  final BuildContext context;

  final Owner _owner;
  final List<_PropBinding<Object?>> _bindings = <_PropBinding<Object?>>[];
  int _cursor = 0;

  /// Binds [value] to [apply].
  ///
  /// [value] is anything [propOf] recognises. A [FixedSignal] is handed to
  /// [apply] immediately and costs no subscription. A reactive value
  /// gets an [Effect] owned by the element: it reads the accessor and hands
  /// the result to [apply], and re-runs whenever anything the accessor read
  /// changes. On later passes the existing effect is pointed at the new value,
  /// or disposed if the new value is static.
  void bind<T>(Object value, ValueSetter<T> apply) {
    if (_cursor < _bindings.length) {
      final _PropBinding<Object?> existing = _bindings[_cursor];
      if (existing is! _PropBinding<T>) {
        throw FlutterError(
          '${context.widget.runtimeType}.bindProps bound a property of type $T at position '
          '$_cursor, but bound a ${existing.runtimeType} there when this element mounted. '
          'bindProps must bind the same properties, of the same types, in the same order, every '
          'time it is called.',
        );
      }
      _cursor += 1;
      existing._set(_owner, value);
      return;
    }
    final binding = _PropBinding<T>(apply);
    _bindings.add(binding);
    _cursor += 1;
    binding._set(_owner, value);
  }
}

/// A render-object widget whose properties may be bound to reactive values
/// instead of being copied out of the widget on every rebuild.
///
/// Implementations describe their bindings in [bindProps]. For every property
/// that is reactive the element creates one [Effect] when it mounts; from then
/// on a write to that [Signal] runs that effect and nothing else. The widget
/// is never rebuilt, no element in the tree is marked dirty, and the only
/// invalidation is whatever the render object's own setter decides to do,
/// typically [RenderObject.markNeedsPaint].
///
/// A widget whose properties are all fixed values costs nothing: it reports
/// [hasReactiveProps] as false, [bindProps] is never called, no binder and no
/// effect are allocated, and the values reach the render object through
/// [RenderObjectWidget.updateRenderObject] exactly as they always have.
///
/// This is a mixin rather than a base class because the element shapes (leaf,
/// single-child) already have their own base classes.
///
/// A reactive property is read twice when the element mounts: once by
/// [RenderObjectWidget.createRenderObject], which seeds the render object with
/// the current value so that it is never laid out with a placeholder, and once
/// by the binding's effect, whose first run is what discovers the
/// dependencies. The second write is a no-op, because every render object
/// setter compares before it invalidates. Seed the render object with
/// [readProp]: a read made from `createRenderObject` is outside any tracking
/// scope, and would otherwise be reported as a silently untracked read during
/// a frame.
mixin ReactiveRenderObjectWidget on RenderObjectWidget {
  /// Whether any property of this widget is currently reactive.
  ///
  /// A widget with [ReadonlySignal] properties should report whether any of
  /// them is something other than a [FixedSignal], so that the all-fixed case
  /// allocates nothing:
  ///
  /// ```dart
  /// abstract class FadeBox extends SingleChildRenderObjectWidget
  ///     with ReactiveRenderObjectWidget {
  ///   const FadeBox({super.key, super.child});
  ///
  ///   ReadonlySignal<double> get opacity;
  ///
  ///   @override
  ///   bool get hasReactiveProps => opacity is! FixedSignal<double>;
  /// }
  /// ```
  ///
  /// Defaults to true, which is right for a widget whose properties are
  /// declared as [Prop] and therefore always reactive.
  bool get hasReactiveProps => true;

  /// Binds every property of this widget that can be reactive to a setter on
  /// [renderObject].
  ///
  /// Called when the element mounts, when the widget is updated, and when an
  /// inherited widget read from [PropBinder.context] changes. Must call
  /// [PropBinder.bind] for the same properties, of the same types, in the same
  /// order, every time.
  void bindProps(PropBinder binder, covariant RenderObject renderObject);
}

mixin _ReactivePropsElement on RenderObjectElement {
  PropBinder? _binder;

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    _bindProps();
  }

  @override
  void update(covariant RenderObjectWidget newWidget) {
    super.update(newWidget);
    _bindProps();
  }

  @override
  void performRebuild() {
    super.performRebuild(); // calls updateRenderObject, clears the dirty flag
    // An inherited widget this element depends on changed, so anything
    // bindProps read from the element's context has to be read again.
    _bindProps();
  }

  void _bindProps() {
    final reactiveWidget = widget as ReactiveRenderObjectWidget;
    if (_binder == null && !reactiveWidget.hasReactiveProps) {
      // Nothing reactive now, and nothing was ever bound: no binder, no
      // bindings, no effects. This is the whole cost of making a widget whose
      // properties are usually fixed values bindable.
      return;
    }
    final PropBinder binder = _binder ??= PropBinder._(this, reactiveOwner);
    // Zero on the first pass, when there is nothing to compare against.
    final int expected = binder._bindings.length;
    binder._cursor = 0;
    reactiveWidget.bindProps(binder, renderObject);
    assert(
      expected == 0 || binder._cursor == expected,
      '${widget.runtimeType}.bindProps bound ${binder._cursor} properties, but bound $expected '
      'when this element mounted. bindProps must bind the same properties in the same order '
      'every time it is called.',
    );
  }
}

/// The element of a [ReactiveLeafRenderObjectWidget].
class ReactiveLeafRenderObjectElement extends LeafRenderObjectElement with _ReactivePropsElement {
  /// Creates an element that uses the given widget as its configuration.
  ReactiveLeafRenderObjectElement(super.widget);
}

/// The element of a [ReactiveSingleChildRenderObjectWidget].
class ReactiveSingleChildRenderObjectElement extends SingleChildRenderObjectElement
    with _ReactivePropsElement {
  /// Creates an element that uses the given widget as its configuration.
  ReactiveSingleChildRenderObjectElement(super.widget);
}

/// A [LeafRenderObjectWidget] with reactive properties.
abstract class ReactiveLeafRenderObjectWidget extends LeafRenderObjectWidget
    with ReactiveRenderObjectWidget {
  /// Abstract const constructor.
  const ReactiveLeafRenderObjectWidget({super.key});

  @override
  ReactiveLeafRenderObjectElement createElement() => ReactiveLeafRenderObjectElement(this);
}

/// A [SingleChildRenderObjectWidget] with reactive properties.
abstract class ReactiveSingleChildRenderObjectWidget extends SingleChildRenderObjectWidget
    with ReactiveRenderObjectWidget {
  /// Abstract const constructor.
  const ReactiveSingleChildRenderObjectWidget({super.key, super.child});

  @override
  ReactiveSingleChildRenderObjectElement createElement() =>
      ReactiveSingleChildRenderObjectElement(this);
}
