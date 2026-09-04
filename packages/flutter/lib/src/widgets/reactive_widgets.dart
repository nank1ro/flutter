// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// @docImport 'package:flutter/material.dart';
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'basic.dart';
import 'framework.dart';
import 'image.dart';
import 'localizations.dart';
import 'media_query.dart';
import 'text.dart';

/// A reactive property: anything that produces a `T` when called.
///
/// [Signal] and [Computed] are callable, so either can be passed straight to a
/// property of this type. Everything else is a closure:
///
/// ```dart
/// final Signal<double> opacity = Signal<double>(1);
/// ReactiveOpacity(opacity: opacity, child: child);              // a signal
/// ReactiveOpacity(opacity: () => opacity.value / 2, child: child); // derived
/// ```
///
/// A property is read inside an [Effect], so every reactive value it touches
/// becomes a dependency of the binding that writes the render object.
typedef Prop<T> = T Function();

// -----------------------------------------------------------------------------
// The binding machinery.
// -----------------------------------------------------------------------------

/// One reactive property bound to one render object setter.
///
/// The prop closure lives in a field rather than being captured by the effect,
/// so that replacing it when the widget updates re-runs the existing effect
/// instead of allocating a new one. [_apply] is not replaced: it writes to the
/// element's render object, which does not change for the element's lifetime.
final class _PropBinding<T> {
  _PropBinding(this._prop, this._apply);

  Prop<T> _prop;
  final ValueSetter<T> _apply;
  late final Effect _effect;

  void _start() {
    _effect = Effect(_run);
  }

  void _run() => _apply(_prop());

  /// Points this binding at a new prop closure, re-reading it immediately.
  ///
  /// Equal closures are ignored, which is the case that matters: a [Signal]
  /// passed straight to a property tears off `call` on the same object every
  /// time, and two such tear-offs are equal — though not identical — so an
  /// update that changes nothing else costs one comparison.
  void _rebind(Prop<T> prop) {
    if (prop == _prop) {
      return;
    }
    _prop = prop;
    // Not `onInvalidate`: this happens outside the effect flush, and re-arming
    // an effect that is already queued would corrupt the queue.
    _effect.rerun();
  }
}

/// Collects the reactive properties of a [ReactiveRenderObjectWidget].
///
/// One binder belongs to one element and is reused for its whole life. Each
/// call to [bind] matches up with the call made at the same position last
/// time, which is why [ReactiveRenderObjectWidget.bindProps] must always bind
/// the same properties in the same order.
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

  /// Binds [prop] to [apply].
  ///
  /// On the first pass this creates an [Effect] owned by the element: it reads
  /// [prop] and hands the result to [apply], and re-runs whenever anything
  /// [prop] read changes. On later passes it points the existing effect at the
  /// new closure.
  void bind<T>(Prop<T> prop, ValueSetter<T> apply) {
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
      existing._rebind(prop);
      return;
    }
    final binding = _PropBinding<T>(prop, apply);
    _bindings.add(binding);
    _cursor += 1;
    _owner.run<void>(binding._start);
  }
}

/// A render-object widget whose properties are bound to reactive values
/// instead of being copied out of the widget on every rebuild.
///
/// Implementations describe their bindings in [bindProps]. The element creates
/// one [Effect] per binding when it mounts; from then on a write to a bound
/// [Signal] runs that effect and nothing else. The widget is never rebuilt, no
/// element in the tree is marked dirty, and the only invalidation is whatever
/// the render object's own setter decides to do — typically
/// [RenderObject.markNeedsPaint].
///
/// This is a mixin rather than a base class because the element shapes (leaf,
/// single-child) already have their own base classes.
///
/// A property is read twice when the element mounts: once by
/// [RenderObjectWidget.createRenderObject], which seeds the render object with
/// the current value so that it is never laid out with a placeholder, and once
/// by the binding's effect, whose first run is what discovers the
/// dependencies. The second write is a no-op, because every render object
/// setter compares before it invalidates. Seed the render object with
/// `untracked(prop)`: a read made from `createRenderObject` is outside any
/// tracking scope, and would otherwise be reported as a silently untracked
/// read during a frame.
mixin ReactiveRenderObjectWidget on RenderObjectWidget {
  /// Binds every reactive property of this widget to a setter on
  /// [renderObject].
  ///
  /// Called when the element mounts, when the widget is replaced, and when
  /// the element is rebuilt because an inherited widget it depends on
  /// changed. Must call [PropBinder.bind] the same number of times, in the
  /// same order, on every call.
  @protected
  void bindProps(PropBinder binder, covariant RenderObject renderObject);
}

/// Shared implementation for the elements of a [ReactiveRenderObjectWidget].
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
    final PropBinder binder = _binder ??= PropBinder._(this, reactiveOwner);
    // Zero on the first pass, when there is nothing to compare against.
    final int expected = binder._bindings.length;
    binder._cursor = 0;
    (widget as ReactiveRenderObjectWidget).bindProps(binder, renderObject);
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

// -----------------------------------------------------------------------------
// Reactive leaf widgets.
//
// Naming: every widget here is the reactive twin of an existing Flutter
// widget, named with a `Reactive` prefix and keeping the original's property
// names, with each reactive property typed `Prop<T>` instead of `T`. Where two
// of the original's properties feed a single render object setter (Text's
// `data` and `style`, SizedBox's `width` and `height`), they are collapsed
// into the one property the setter actually takes, because a binding is a
// property-to-setter pair.
// -----------------------------------------------------------------------------

/// Makes its child partially transparent, with a reactive opacity.
///
/// A write to [opacity] runs one effect, which calls [RenderOpacity.opacity].
/// Nothing rebuilds and nothing relayouts.
class ReactiveOpacity extends ReactiveSingleChildRenderObjectWidget {
  /// Creates a widget that makes its child partially transparent.
  const ReactiveOpacity({
    super.key,
    required this.opacity,
    this.alwaysIncludeSemantics = false,
    super.child,
  });

  /// The fraction to multiply the child's alpha value by, between 0.0 and 1.0.
  final Prop<double> opacity;

  /// Whether the semantics of the child are included when it is transparent.
  final bool alwaysIncludeSemantics;

  @override
  RenderOpacity createRenderObject(BuildContext context) =>
      RenderOpacity(opacity: untracked(opacity), alwaysIncludeSemantics: alwaysIncludeSemantics);

  @override
  void updateRenderObject(BuildContext context, RenderOpacity renderObject) {
    renderObject.alwaysIncludeSemantics = alwaysIncludeSemantics;
  }

  @override
  void bindProps(PropBinder binder, RenderOpacity renderObject) {
    binder.bind<double>(opacity, (double value) => renderObject.opacity = value);
  }
}

/// Paints its child, and the area behind it, in a reactive colour.
///
/// The render object is this file's own rather than [ColoredBox]'s, whose
/// render object is private; the paint is the same.
class ReactiveColoredBox extends ReactiveSingleChildRenderObjectWidget {
  /// Creates a widget that paints its area in the given colour.
  const ReactiveColoredBox({super.key, required this.color, super.child});

  /// The colour to fill this widget's bounds with.
  final Prop<Color> color;

  @override
  RenderReactiveColoredBox createRenderObject(BuildContext context) =>
      RenderReactiveColoredBox(color: untracked(color));

  @override
  void bindProps(PropBinder binder, RenderReactiveColoredBox renderObject) {
    binder.bind<Color>(color, (Color value) => renderObject.color = value);
  }
}

/// Fills its bounds with [color], then paints its child over the top.
class RenderReactiveColoredBox extends RenderProxyBoxWithHitTestBehavior {
  /// Creates a render object that fills its bounds with [color].
  RenderReactiveColoredBox({required Color color, super.child})
    : _color = color,
      super(behavior: HitTestBehavior.opaque);

  /// The fill colour.
  Color get color => _color;
  Color _color;
  set color(Color value) {
    if (value == _color) {
      return;
    }
    _color = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // The `drawRect` is not skipped for a fully transparent colour: a
    // transparent fill still participates in blending. See
    // https://github.com/flutter/flutter/pull/72526#issuecomment-749185938.
    if (size > Size.zero) {
      context.canvas.drawRect(offset & size, Paint()..color = _color);
    }
    if (child != null) {
      context.paintChild(child!, offset);
    }
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(ColorProperty('color', color));
  }
}

/// Insets its child by a reactive amount.
///
/// Padding is a layout property, so a write here marks the render object as
/// needing layout. It still rebuilds nothing.
class ReactivePadding extends ReactiveSingleChildRenderObjectWidget {
  /// Creates a widget that insets its child.
  const ReactivePadding({super.key, required this.padding, super.child});

  /// The amount of space to inset the child by.
  final Prop<EdgeInsetsGeometry> padding;

  @override
  RenderPadding createRenderObject(BuildContext context) =>
      RenderPadding(padding: untracked(padding), textDirection: Directionality.maybeOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderPadding renderObject) {
    renderObject.textDirection = Directionality.maybeOf(context);
  }

  @override
  void bindProps(PropBinder binder, RenderPadding renderObject) {
    binder.bind<EdgeInsetsGeometry>(
      padding,
      (EdgeInsetsGeometry value) => renderObject.padding = value,
    );
  }
}

/// Applies a reactive transform matrix to its child before painting it.
///
/// Note that [RenderTransform.transform] copies the matrix it is given, so a
/// caller that mutates one matrix in place and expects the render object to
/// follow will be disappointed; produce a new matrix, or use [ReactiveOffset]
/// for the common translate-only case, which allocates nothing.
class ReactiveTransform extends ReactiveSingleChildRenderObjectWidget {
  /// Creates a widget that transforms its child.
  const ReactiveTransform({
    super.key,
    required this.transform,
    this.transformHitTests = true,
    this.filterQuality,
    super.child,
  });

  /// The matrix to transform the child by during painting.
  final Prop<Matrix4> transform;

  /// Whether to apply the transform to hit tests as well as to painting.
  final bool transformHitTests;

  /// The filter quality to apply the transform with, if it is applied as a
  /// bitmap operation.
  final FilterQuality? filterQuality;

  @override
  RenderTransform createRenderObject(BuildContext context) => RenderTransform(
    transform: untracked(transform),
    transformHitTests: transformHitTests,
    filterQuality: filterQuality,
  );

  @override
  void updateRenderObject(BuildContext context, RenderTransform renderObject) {
    renderObject
      ..transformHitTests = transformHitTests
      ..filterQuality = filterQuality;
  }

  @override
  void bindProps(PropBinder binder, RenderTransform renderObject) {
    binder.bind<Matrix4>(transform, (Matrix4 value) => renderObject.transform = value);
  }
}

/// Paints its child shifted by a reactive [offset], without affecting layout.
///
/// This is the sprite case. Because the offset is applied at paint time, and
/// the child's layout is unchanged, moving one of ten thousand of these marks
/// exactly one render object as needing paint: no ancestor relayouts, and no
/// parent data is touched, which is what separates this from moving a
/// [Positioned] inside a [Stack].
class ReactiveOffset extends ReactiveSingleChildRenderObjectWidget {
  /// Creates a widget that paints its child at an offset.
  const ReactiveOffset({
    super.key,
    required this.offset,
    this.transformHitTests = true,
    super.child,
  });

  /// The offset, in logical pixels, to paint the child at.
  final Prop<Offset> offset;

  /// Whether hit tests are performed at the painted position.
  final bool transformHitTests;

  @override
  RenderReactiveOffset createRenderObject(BuildContext context) =>
      RenderReactiveOffset(offset: untracked(offset), transformHitTests: transformHitTests);

  @override
  void updateRenderObject(BuildContext context, RenderReactiveOffset renderObject) {
    renderObject.transformHitTests = transformHitTests;
  }

  @override
  void bindProps(PropBinder binder, RenderReactiveOffset renderObject) {
    binder.bind<Offset>(offset, (Offset value) => renderObject.offset = value);
  }
}

/// Paints its child at [offset], leaving layout alone.
///
/// The absolute-pixel counterpart of [RenderFractionalTranslation], whose
/// translation is a fraction of the child's size.
class RenderReactiveOffset extends RenderProxyBox {
  /// Creates a render object that paints its child at an offset.
  RenderReactiveOffset({
    Offset offset = Offset.zero,
    this.transformHitTests = true,
    RenderBox? child,
  }) : _offset = offset,
       super(child);

  /// The offset, in logical pixels, to paint the child at.
  Offset get offset => _offset;
  Offset _offset;
  set offset(Offset value) {
    if (_offset == value) {
      return;
    }
    _offset = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  /// Whether hit tests are performed at the painted position.
  bool transformHitTests;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Like RenderFractionalTranslation, this box does not test itself: its own
    // bounds are where it was laid out, not where it was painted.
    return hitTestChildren(result, position: position);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    assert(!debugNeedsLayout);
    return result.addWithPaintOffset(
      offset: transformHitTests ? _offset : null,
      position: position,
      hitTest: (BoxHitTestResult result, Offset position) {
        return super.hitTestChildren(result, position: position);
      },
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child != null) {
      super.paint(context, offset + _offset);
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(_offset.dx, _offset.dy, 0, 1);
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<Offset>('offset', offset));
    properties.add(DiagnosticsProperty<bool>('transformHitTests', transformHitTests));
  }
}

/// Imposes reactive additional constraints on its child.
class ReactiveConstrainedBox extends ReactiveSingleChildRenderObjectWidget {
  /// Creates a widget that imposes additional constraints on its child.
  const ReactiveConstrainedBox({super.key, required this.constraints, super.child});

  /// The additional constraints to impose on the child.
  final Prop<BoxConstraints> constraints;

  @override
  RenderConstrainedBox createRenderObject(BuildContext context) =>
      RenderConstrainedBox(additionalConstraints: untracked(constraints));

  @override
  void bindProps(PropBinder binder, RenderConstrainedBox renderObject) {
    binder.bind<BoxConstraints>(
      constraints,
      (BoxConstraints value) => renderObject.additionalConstraints = value,
    );
  }
}

/// Forces its child to a reactive size.
///
/// The reactive counterpart of [SizedBox]. Width and height are one [Prop] of
/// type [Size] rather than two of type `double`, because the render object
/// takes both at once: one binding is one setter, and splitting it would mean
/// two effects that each read both values.
class ReactiveSizedBox extends ReactiveSingleChildRenderObjectWidget {
  /// Creates a widget with a reactive size.
  const ReactiveSizedBox({super.key, required this.size, super.child});

  /// The size to force on the child.
  final Prop<Size> size;

  @override
  RenderConstrainedBox createRenderObject(BuildContext context) =>
      RenderConstrainedBox(additionalConstraints: BoxConstraints.tight(untracked(size)));

  @override
  void bindProps(PropBinder binder, RenderConstrainedBox renderObject) {
    binder.bind<Size>(
      size,
      (Size value) => renderObject.additionalConstraints = BoxConstraints.tight(value),
    );
  }
}

/// Paints a reactive [Decoration] before or after painting its child.
class ReactiveDecoratedBox extends ReactiveSingleChildRenderObjectWidget {
  /// Creates a widget that paints a decoration.
  const ReactiveDecoratedBox({
    super.key,
    required this.decoration,
    this.position = DecorationPosition.background,
    super.child,
  });

  /// The decoration to paint.
  final Prop<Decoration> decoration;

  /// Whether to paint the decoration behind or in front of the child.
  final DecorationPosition position;

  @override
  RenderDecoratedBox createRenderObject(BuildContext context) => RenderDecoratedBox(
    decoration: untracked(decoration),
    position: position,
    configuration: createLocalImageConfiguration(context),
  );

  @override
  void updateRenderObject(BuildContext context, RenderDecoratedBox renderObject) {
    renderObject
      ..position = position
      ..configuration = createLocalImageConfiguration(context);
  }

  @override
  void bindProps(PropBinder binder, RenderDecoratedBox renderObject) {
    binder.bind<Decoration>(decoration, (Decoration value) => renderObject.decoration = value);
  }
}

/// A run of text with a reactive string and style.
///
/// The reactive counterpart of [Text]. [data] and [style] are bound together,
/// as one [InlineSpan], because [RenderParagraph.text] takes the whole span:
/// writing either signal rebuilds one [TextSpan] and hands it to the setter,
/// which compares it with the old one and relayouts only if it differs.
class ReactiveText extends ReactiveLeafRenderObjectWidget {
  /// Creates a run of reactive text.
  const ReactiveText(
    this.data, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.textDirection,
    this.softWrap = true,
    this.overflow = TextOverflow.clip,
    this.maxLines,
  });

  /// The text to display.
  final Prop<String> data;

  /// The style to display the text with, or null for the ambient
  /// [DefaultTextStyle].
  final Prop<TextStyle>? style;

  /// How the text should be aligned horizontally.
  final TextAlign textAlign;

  /// The directionality of the text, or null to use the ambient
  /// [Directionality].
  final TextDirection? textDirection;

  /// Whether the text should break at soft line breaks.
  final bool softWrap;

  /// How visual overflow should be handled.
  final TextOverflow overflow;

  /// The maximum number of lines, or null for no limit.
  final int? maxLines;

  /// The span [RenderParagraph.text] is bound to, under the ambient
  /// [DefaultTextStyle].
  ///
  /// [ambient] is resolved outside this method, from the element's context,
  /// and merged the way [Text] merges it: a style that does not inherit
  /// replaces it outright.
  ///
  /// The closure that calls this is a fresh object on every bind, so the
  /// binding is re-run whenever the widget is replaced or the ambient style
  /// changes. That is correct — a new widget means new closures to read — and
  /// costs one re-run of one effect, which only happens when an ancestor
  /// rebuilds, never when the text changes.
  InlineSpan _span(TextStyle ambient) {
    final TextStyle? own = style?.call();
    return TextSpan(text: data(), style: own == null || own.inherit ? ambient.merge(own) : own);
  }

  @override
  RenderParagraph createRenderObject(BuildContext context) {
    final TextDirection direction = textDirection ?? Directionality.of(context);
    final TextStyle ambient = DefaultTextStyle.of(context).style;
    return RenderParagraph(
      untracked(() => _span(ambient)),
      textAlign: textAlign,
      textDirection: direction,
      softWrap: softWrap,
      overflow: overflow,
      maxLines: maxLines,
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderParagraph renderObject) {
    renderObject
      ..textAlign = textAlign
      ..textDirection = textDirection ?? Directionality.of(context)
      ..softWrap = softWrap
      ..overflow = overflow
      ..maxLines = maxLines
      ..textScaler = MediaQuery.textScalerOf(context)
      ..locale = Localizations.maybeLocaleOf(context);
  }

  @override
  void bindProps(PropBinder binder, RenderParagraph renderObject) {
    // Read here rather than inside the effect: this is the element's own
    // inherited dependency, so a change to the ambient style rebuilds the
    // element, which rebinds and picks the new style up.
    final TextStyle ambient = DefaultTextStyle.of(binder.context).style;
    binder.bind<InlineSpan>(() => _span(ambient), (InlineSpan value) => renderObject.text = value);
  }
}

/// A [CustomPaint] whose painter may read signals from inside
/// [CustomPainter.paint].
///
/// Reads made while painting are tracked by the render object, so a write to
/// any of them calls [RenderObject.markNeedsPaint] on this render object and
/// nothing else: no rebuild, no relayout, and no [CustomPainter.shouldRepaint]
/// to get wrong. This is how a scene of thousands of things can be drawn from
/// one signal — a batch of writes ends in a single repaint.
///
/// The painter is still an ordinary [CustomPainter], so it may also repaint
/// for the ordinary reasons. Note that a mutable buffer, such as a
/// [Float32List] rewritten in place, is not itself a change any signal can
/// see: keep a `Signal<int>` alongside it and bump it after each mutation, and
/// read that signal in `paint`.
class ReactiveCustomPaint extends SingleChildRenderObjectWidget {
  /// Creates a widget that provides a canvas whose painter can read signals.
  const ReactiveCustomPaint({
    super.key,
    this.painter,
    this.foregroundPainter,
    this.size = Size.zero,
    this.isComplex = false,
    this.willChange = false,
    super.child,
  });

  /// The painter that paints before the child.
  final CustomPainter? painter;

  /// The painter that paints after the child.
  final CustomPainter? foregroundPainter;

  /// The size this widget should take when it has no child.
  final Size size;

  /// Whether the painting is complex enough to benefit from caching.
  final bool isComplex;

  /// Whether the painting is likely to change in the next frame.
  final bool willChange;

  @override
  RenderReactiveCustomPaint createRenderObject(BuildContext context) => RenderReactiveCustomPaint(
    painter: painter,
    foregroundPainter: foregroundPainter,
    preferredSize: size,
    isComplex: isComplex,
    willChange: willChange,
  );

  @override
  void updateRenderObject(BuildContext context, RenderReactiveCustomPaint renderObject) {
    renderObject
      ..painter = painter
      ..foregroundPainter = foregroundPainter
      ..preferredSize = size
      ..isComplex = isComplex
      ..willChange = willChange;
  }

  @override
  void didUnmountRenderObject(RenderReactiveCustomPaint renderObject) {
    renderObject
      ..painter = null
      ..foregroundPainter = null;
  }
}

/// A [RenderCustomPaint] that tracks the signals its painters read.
///
/// Only the painters' own [CustomPainter.paint] calls are tracked. The child
/// is painted outside the tracking scope, so a signal read while painting a
/// descendant belongs to that descendant's own tracking and does not repaint
/// this render object as well.
class RenderReactiveCustomPaint extends RenderCustomPaint {
  /// Creates a render object that tracks reactive reads made while painting.
  RenderReactiveCustomPaint({
    super.painter,
    super.foregroundPainter,
    super.preferredSize,
    super.isComplex,
    super.willChange,
    super.child,
  });

  /// The subscriber the painters' reads attach to. Invalidating it repaints
  /// this render object, which re-runs the painters and re-tracks.
  ///
  /// Created detached: a node created while a build or an effect is running
  /// would be disposed the next time that scope re-runs, and this one belongs
  /// to the render object, which disposes it in [dispose].
  late final TrackingNode _paintNode = Owner.detached().run<TrackingNode>(
    () => TrackingNode(markNeedsPaint),
  );

  // The arguments of the painter call in progress, so that the tracked body
  // can be a method reference held in a field rather than a closure allocated
  // per paint.
  Canvas? _painterCanvas;
  CustomPainter? _runningPainter;
  late final VoidCallback _boundPaintPainter = _paintPainter;
  late final VoidCallback _boundResetTracking = _resetTracking;

  void _paintPainter() => _runningPainter!.paint(_painterCanvas!, size);

  void _resetTracking() {}

  /// Paints [painter] inside the tracking scope, saving and restoring the
  /// canvas around it the way [RenderCustomPaint] does.
  void _paintTracked(PaintingContext context, Offset offset, CustomPainter painter) {
    final Canvas canvas = context.canvas;
    late int debugPreviousCanvasSaveCount;
    canvas.save();
    assert(() {
      debugPreviousCanvasSaveCount = canvas.getSaveCount();
      return true;
    }());
    if (offset != Offset.zero) {
      canvas.translate(offset.dx, offset.dy);
    }
    _painterCanvas = canvas;
    _runningPainter = painter;
    try {
      // Both painters are one logical run of the node, so the second appends
      // to the dependencies of the first instead of replacing them.
      _paintNode.track<void>(_boundPaintPainter, retainDeps: true);
      assert(() {
        // This isn't perfect. For example, we can't catch the case of
        // someone first restoring, then setting a transform or whatnot,
        // then saving.
        // If this becomes a real problem, we could add logic to the
        // Canvas class to lock the canvas at a particular save count
        // such that restore() fails if it would take the lock count
        // below that number.
        final int debugNewCanvasSaveCount = canvas.getSaveCount();
        if (debugNewCanvasSaveCount > debugPreviousCanvasSaveCount) {
          throw FlutterError.fromParts(<DiagnosticsNode>[
            ErrorSummary(
              'The $painter custom painter called canvas.save() or canvas.saveLayer() at least '
              '${debugNewCanvasSaveCount - debugPreviousCanvasSaveCount} more '
              'time${debugNewCanvasSaveCount - debugPreviousCanvasSaveCount == 1 ? '' : 's'} '
              'than it called canvas.restore().',
            ),
            ErrorDescription(
              'This leaves the canvas in an inconsistent state and will probably result in a broken display.',
            ),
            ErrorHint(
              'You must pair each call to save()/saveLayer() with a later matching call to restore().',
            ),
          ]);
        }
        if (debugNewCanvasSaveCount < debugPreviousCanvasSaveCount) {
          throw FlutterError.fromParts(<DiagnosticsNode>[
            ErrorSummary(
              'The $painter custom painter called canvas.restore() '
              '${debugPreviousCanvasSaveCount - debugNewCanvasSaveCount} more '
              'time${debugPreviousCanvasSaveCount - debugNewCanvasSaveCount == 1 ? '' : 's'} '
              'than it called canvas.save() or canvas.saveLayer().',
            ),
            ErrorDescription(
              'This leaves the canvas in an inconsistent state and will result in a broken display.',
            ),
            ErrorHint('You should only call restore() if you first called save() or saveLayer().'),
          ]);
        }
        return debugNewCanvasSaveCount == debugPreviousCanvasSaveCount;
      }());
    } finally {
      _painterCanvas = null;
      _runningPainter = null;
      canvas.restore();
    }
    if (isComplex) {
      context.setIsComplexHint();
    }
    if (willChange) {
      context.setWillChangeHint();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // This is RenderCustomPaint.paint with the tracking scope around the
    // painters only. Calling super.paint would put the child's paint inside
    // the scope too, and attribute every signal the subtree reads to this
    // render object.
    //
    // Tracking an empty body starts the run over, dropping what the previous
    // paint read; see Subscriber.track.
    _paintNode.track<void>(_boundResetTracking);
    final CustomPainter? background = painter;
    if (background != null) {
      _paintTracked(context, offset, background);
    }
    if (child != null) {
      context.paintChild(child!, offset);
    }
    final CustomPainter? foreground = foregroundPainter;
    if (foreground != null) {
      _paintTracked(context, offset, foreground);
    }
  }

  @override
  void dispose() {
    _paintNode.dispose();
    super.dispose();
  }
}

// -----------------------------------------------------------------------------
// Structural control flow.
// -----------------------------------------------------------------------------

/// Mounts one of two subtrees, chosen by a reactive condition.
///
/// [Show] is an ordinary [StatelessWidget], and needs to be nothing more: every
/// element already tracks the signals its build reads, so a write that flips
/// [when] rebuilds this element and only this element. Its ancestors are
/// untouched, and the branch that is not selected is never built.
///
/// ```dart
/// Show(
///   when: isLoggedIn,               // a Signal<bool>
///   child: () => const Dashboard(),
///   fallback: () => const LoginForm(),
/// )
/// ```
///
/// [child] and [fallback] are callbacks so that the subtree that is not shown
/// is not built, and not allocated.
///
/// They are called from [Show]'s own build, so a signal read *inside* one of
/// them is a dependency of [Show], not of the widget it returns: writing it
/// rebuilds [Show] and the whole selected subtree.
///
/// ```dart
/// Show(when: on, child: () => Text('${count.value}'))  // rebuilds Show
/// Show(when: on, child: () => const Counter())         // rebuilds Counter
/// ```
///
/// Keep the callbacks to choosing a subtree, and read the values that change
/// often in the build methods of the widgets they return, so that a write
/// rebuilds as little as possible.
class Show extends StatelessWidget {
  /// Creates a widget that mounts [child] when [when] is true.
  const Show({super.key, required this.when, required this.child, this.fallback});

  /// Whether to mount [child].
  final Prop<bool> when;

  /// Builds the subtree mounted when [when] is true.
  final Widget Function() child;

  /// Builds the subtree mounted when [when] is false. Defaults to nothing.
  final Widget Function()? fallback;

  @override
  Widget build(BuildContext context) {
    if (when()) {
      return child();
    }
    return fallback?.call() ?? const SizedBox.shrink();
  }
}

/// Mounts one child per item of a reactive list, reconciled by key.
///
/// The list is read inside this element's tracking scope, so a write to it
/// reconciles here and nowhere else. Reconciliation is keyed and minimal: a
/// key that is already mounted is left completely alone — [builder] is not
/// called for it, [Element.updateChild] is not called for it, and its element
/// and render object are the same objects as before. Only new keys are
/// inflated, only removed keys are deactivated, and only children whose
/// position changed are moved.
///
/// Because an existing child is never rebuilt from its item, the item widgets
/// must read their own signals for anything that changes:
///
/// ```dart
/// For<Sprite>(
///   each: sprites,                 // a Signal<List<Sprite>>
///   keyOf: (Sprite s) => s.id,
///   builder: (Sprite s) => ReactiveOffset(offset: s.position, child: const _Dot()),
/// )
/// ```
///
/// The children are laid out as a [Stack]: they are all given the incoming
/// constraints, loosened, and the widget takes the size of the largest. That
/// is the layout a scene of independently positioned things wants; for
/// anything else, put the [For] inside the layout widget you want and give its
/// items a fixed size.
///
/// The parameter is called `keyOf` rather than `key` because [Widget.key]
/// already has that name.
class For<T> extends RenderObjectWidget {
  /// Creates a widget that mounts one child per item of [each].
  const For({
    super.key,
    required this.each,
    required this.keyOf,
    required this.builder,
    this.alignment = AlignmentDirectional.topStart,
    this.fit = StackFit.loose,
    this.clipBehavior = Clip.hardEdge,
  });

  /// The reactive list of items.
  final Prop<List<T>> each;

  /// The identity of an item, used to match it against a mounted child.
  ///
  /// Keys must be unique within one list, and are compared with `==`.
  final Object Function(T item) keyOf;

  /// Builds the widget for an item. Called once per key, when that key first
  /// appears.
  final Widget Function(T item) builder;

  /// How to align children that are not [Positioned].
  final AlignmentGeometry alignment;

  /// How to size children that are not [Positioned].
  final StackFit fit;

  /// How to clip children that overflow.
  final Clip clipBehavior;

  @override
  RenderObjectElement createElement() => _ForElement<T>(this);

  @override
  RenderStack createRenderObject(BuildContext context) => RenderStack(
    alignment: alignment,
    textDirection: Directionality.maybeOf(context),
    fit: fit,
    clipBehavior: clipBehavior,
  );

  @override
  void updateRenderObject(BuildContext context, RenderStack renderObject) {
    renderObject
      ..alignment = alignment
      ..textDirection = Directionality.maybeOf(context)
      ..fit = fit
      ..clipBehavior = clipBehavior;
  }
}

class _ForElement<T> extends RenderObjectElement {
  _ForElement(For<T> super.widget);

  @override
  ContainerRenderObjectMixin<RenderObject, ContainerParentDataMixin<RenderObject>>
  get renderObject {
    return super.renderObject
        as ContainerRenderObjectMixin<RenderObject, ContainerParentDataMixin<RenderObject>>;
  }

  /// The mounted children, in list order.
  List<Element> _children = <Element>[];

  /// The mounted children by item key, which is what makes reconciliation
  /// keyed rather than positional.
  Map<Object, Element> _childrenByKey = HashMap<Object, Element>();

  /// Children taken over by a [GlobalKey] elsewhere. They are still in
  /// [_children] until the next reconciliation, but must not be visited or
  /// reused.
  final Set<Element> _forgottenChildren = HashSet<Element>();

  @override
  void visitChildren(ElementVisitor visitor) {
    for (final Element child in _children) {
      if (!_forgottenChildren.contains(child)) {
        visitor(child);
      }
    }
  }

  @override
  void forgetChild(Element child) {
    assert(_children.contains(child));
    assert(!_forgottenChildren.contains(child));
    _forgottenChildren.add(child);
    super.forgetChild(child);
  }

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    _reconcile();
  }

  @override
  void update(For<T> newWidget) {
    super.update(newWidget); // calls updateRenderObject
    _reconcile();
  }

  @override
  void performRebuild() {
    super.performRebuild(); // calls updateRenderObject, clears the dirty flag
    _reconcile();
  }

  /// Matches the mounted children against the current list.
  ///
  /// Only the list read is tracked: [For.builder] runs outside the tracking
  /// scope, so a signal an item widget reads belongs to that item's own
  /// element, not to this one.
  void _reconcile() {
    final widget = this.widget as For<T>;
    final List<T> items = trackSignalReads<List<T>>(widget.each);

    final Map<Object, Element> previous = _childrenByKey;
    final newChildrenByKey = HashMap<Object, Element>();
    final newChildren = List<Element>.empty(growable: true);
    Element? previousSibling;
    Object? duplicateKey;
    for (var i = 0; i < items.length; i += 1) {
      final T item = items[i];
      final Object key = widget.keyOf(item);
      if (newChildrenByKey.containsKey(key)) {
        // Duplicate keys are a caller error, reported by the assert below.
        // The item is skipped rather than mounted, because a second child
        // under a key that is already taken can never be matched again, and
        // so would be leaked instead of deactivated by the next
        // reconciliation. The assert waits until the tree is consistent.
        duplicateKey ??= key;
        continue;
      }
      final slot = IndexedSlot<Element?>(newChildren.length, previousSibling);
      Element? child = previous.remove(key);
      if (child != null && _forgottenChildren.contains(child)) {
        child = null;
      }
      if (child == null) {
        child = inflateWidget(widget.builder(item), slot);
      } else if (child.slot != slot) {
        updateSlotForChild(child, slot);
      }
      newChildrenByKey[key] = child;
      newChildren.add(child);
      previousSibling = child;
    }
    for (final Element stale in previous.values) {
      if (!_forgottenChildren.contains(stale)) {
        deactivateChild(stale);
      }
    }
    _forgottenChildren.clear();
    _children = newChildren;
    _childrenByKey = newChildrenByKey;
    assert(
      duplicateKey == null,
      'For.keyOf produced the duplicate key $duplicateKey. Keys must be unique within one list.',
    );
  }

  @override
  void insertRenderObjectChild(RenderObject child, IndexedSlot<Element?> slot) {
    final ContainerRenderObjectMixin<RenderObject, ContainerParentDataMixin<RenderObject>>
    renderObject = this.renderObject;
    assert(renderObject.debugValidateChild(child));
    renderObject.insert(child, after: slot.value?.renderObject);
    assert(renderObject == this.renderObject);
  }

  @override
  void moveRenderObjectChild(
    RenderObject child,
    IndexedSlot<Element?> oldSlot,
    IndexedSlot<Element?> newSlot,
  ) {
    final ContainerRenderObjectMixin<RenderObject, ContainerParentDataMixin<RenderObject>>
    renderObject = this.renderObject;
    assert(child.parent == renderObject);
    renderObject.move(child, after: newSlot.value?.renderObject);
    assert(renderObject == this.renderObject);
  }

  @override
  void removeRenderObjectChild(RenderObject child, Object? slot) {
    final ContainerRenderObjectMixin<RenderObject, ContainerParentDataMixin<RenderObject>>
    renderObject = this.renderObject;
    assert(child.parent == renderObject);
    renderObject.remove(child);
    assert(renderObject == this.renderObject);
  }
}
