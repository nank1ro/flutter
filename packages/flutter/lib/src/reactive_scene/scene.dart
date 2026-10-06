// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// A retained scene graph driven entirely by signals.
///
/// Scene mode is phase 4 of `docs/fine_grained_reactivity/PLAN.md`: option (c),
/// "no tree at all". A [SceneNode] is not a widget, has no element, and has no
/// render object. It is a plain object holding reactive properties, its own
/// [ui.Picture], and two subscribers into the signal graph. Frames are produced
/// by walking the node tree once and calling [ui.SceneBuilder] (standalone) or
/// [ui.Canvas] (embedded in the classic tree through `SceneView`).
///
/// See `docs/fine_grained_reactivity/SCENE_MODE.md` for the retention model and
/// for what scene mode deliberately does not provide.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

// ---------------------------------------------------------------------------
// Composition sinks.
// ---------------------------------------------------------------------------

/// Where a scene walk sends its transform, opacity and picture operations.
///
/// The walk in [ReactiveScene.composeFrame] is the same whatever the sink is;
/// only the sink differs between the two embeddings. [SceneBuilderCompositor]
/// writes to a [ui.SceneBuilder], which is what standalone mode renders with
/// and what gives per-node engine-layer retention. [CanvasCompositor] writes to
/// a [ui.Canvas], which is what the embedded `SceneView` paints into. Tests and
/// benchmarks implement it to count operations.
///
/// Every `push` is handed the node that pushed it, so that a sink able to
/// retain engine resources per node has somewhere to keep them. Each `push`
/// must be matched by a [pop].
///
/// There is deliberately no `pushOffset`. Translation is accumulated by the
/// walk and handed to [addPicture], because a layer per moving node turned out
/// to be the most expensive thing in the frame: at ten thousand nodes, pushing
/// an offset layer each cost 15,200 µs per frame against 2,500 µs for adding
/// the pictures at an offset. Transform and opacity layers remain, because they
/// cannot be folded into a picture's position.
abstract class SceneCompositor {
  /// Abstract const constructor, so that subclasses can be const.
  const SceneCompositor();

  /// Transforms everything up to the matching [pop] by `matrix`, a
  /// column-major 4x4 matrix. The node's accumulated translation is already
  /// baked into it.
  void pushTransform(SceneNode node, Float64List matrix);

  /// Blends everything up to the matching [pop] with `alpha`, in 0..255.
  void pushOpacity(SceneNode node, int alpha);

  /// Draws a node's retained picture at (`dx`, `dy`) from the current origin.
  ///
  /// The offset is passed as two doubles rather than a [ui.Offset] because the
  /// walk itself allocates nothing; a sink that ends up calling
  /// [ui.SceneBuilder.addPicture] has to build one [ui.Offset] per call, which
  /// that API requires and which is the one allocation per composed node.
  void addPicture(SceneNode node, double dx, double dy, ui.Picture picture);

  /// Undoes the most recent push.
  void pop();
}

/// A [SceneCompositor] that builds a [ui.Scene].
///
/// Each node's engine layers are kept on the node and handed back as
/// `oldLayer`, so the engine can reuse the resources it allocated for them.
/// The layer returned by the push replaces the stored one, because a layer may
/// only be used as `oldLayer` once.
class SceneBuilderCompositor extends SceneCompositor {
  /// Creates a compositor that appends to `builder`.
  SceneBuilderCompositor(this.builder);

  /// The builder being written to.
  final ui.SceneBuilder builder;

  @override
  void pushTransform(SceneNode node, Float64List matrix) {
    final ui.TransformEngineLayer? old = node._transformLayer;
    node._transformLayer = builder.pushTransform(matrix, oldLayer: old);
    old?.dispose();
  }

  @override
  void pushOpacity(SceneNode node, int alpha) {
    final ui.OpacityEngineLayer? old = node._opacityLayer;
    node._opacityLayer = builder.pushOpacity(alpha, oldLayer: old);
    old?.dispose();
  }

  @override
  void addPicture(SceneNode node, double dx, double dy, ui.Picture picture) {
    // One ui.Offset per composed node per frame. `SceneBuilder.addPicture`
    // takes an Offset and nothing else, so this allocation is the API's, not
    // the walk's, and it is the only one a steady-state frame makes.
    builder.addPicture(ui.Offset(dx, dy), picture);
  }

  @override
  void pop() => builder.pop();
}

/// A [SceneCompositor] that replays the scene into a [ui.Canvas].
///
/// This is what the embedded `SceneView` uses: a [ui.PaintingContext] hands out
/// a canvas, not a scene builder. There are no per-node engine layers here; an
/// unchanged node costs one `drawPicture` of the picture it already recorded.
class CanvasCompositor extends SceneCompositor {
  /// Creates a compositor that draws into `canvas`.
  CanvasCompositor(this.canvas);

  /// The canvas being drawn into.
  final ui.Canvas canvas;

  @override
  void pushTransform(SceneNode node, Float64List matrix) {
    canvas.save();
    canvas.transform(matrix);
  }

  @override
  void pushOpacity(SceneNode node, int alpha) {
    // The paint is kept on the node, so a node that fades costs no allocation
    // per frame.
    final ui.Paint paint = node._opacityPaint ??= ui.Paint();
    paint.color = ui.Color.fromARGB(alpha, 0, 0, 0);
    canvas.saveLayer(null, paint);
  }

  @override
  void addPicture(SceneNode node, double dx, double dy, ui.Picture picture) {
    if (dx == 0.0 && dy == 0.0) {
      canvas.drawPicture(picture);
      return;
    }
    canvas.save();
    canvas.translate(dx, dy);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  @override
  void pop() => canvas.restore();
}

// ---------------------------------------------------------------------------
// Nodes.
// ---------------------------------------------------------------------------

/// A node in a retained, signal-driven scene.
///
/// Every property is reactive: it has type `T Function()`, which a [Signal]
/// satisfies directly, so `RectNode(x: xSignal)` binds the node's position to
/// that signal with no closure and no wrapper. A null property means "use the
/// default" and costs nothing.
///
/// A node holds two subscribers into the signal graph, both owned by [owner]
/// and disposed with it:
///
/// * a [Effect] over the *composition* properties ([x], [y], [rotation],
///   [scale], [opacity], [visible]). It caches their values into fields and
///   asks the scene for a frame. The per-frame walk then reads only those
///   fields, so composing a scene reads no signals and allocates no closures.
/// * a [TrackingNode] over whatever the node's picture is recorded from. It
///   marks the node picture-dirty; the picture is re-recorded on the next walk,
///   inside that node's tracking scope. Only [DrawableSceneNode] has one.
///
/// The two are separate because they cost different amounts. Moving a node
/// re-composes: nothing is re-recorded and only the parameters passed to the
/// compositor differ, so the node is not tracked as dirty at all. Changing what
/// a node draws marks it picture-dirty, and re-records exactly that node.
///
/// Nodes are disposed explicitly, with [dispose]. There is no element lifetime
/// to hang disposal on, which is the point.
abstract class SceneNode {
  /// Creates a node with the given reactive properties.
  SceneNode({
    this.x,
    this.y,
    this.rotation,
    this.scale,
    this.opacity,
    this.visible,
    this.onPointerEvent,
  }) {
    owner.run(() => Effect(_readTransform));
  }

  /// The node's horizontal offset from its parent, in logical pixels.
  final double Function()? x;

  /// The node's vertical offset from its parent, in logical pixels.
  final double Function()? y;

  /// The node's clockwise rotation about its own origin, in radians.
  final double Function()? rotation;

  /// The node's uniform scale about its own origin. Defaults to 1.
  final double Function()? scale;

  /// The node's opacity, in 0..1. Defaults to 1. A node at 0 is not composed.
  final double Function()? opacity;

  /// Whether the node and its children are composed at all. Defaults to true.
  final bool Function()? visible;

  /// Called when a pointer event lands on this node.
  ///
  /// The event is delivered to the top-most node whose bounds contain the
  /// pointer, with no capture: a drag that leaves the node stops being
  /// delivered to it. See [ReactiveScene.dispatchPointerEvent].
  final void Function(PointerEvent event)? onPointerEvent;

  /// The disposal scope for this node's subscribers.
  ///
  /// Detached, so that creating a node inside somebody else's effect does not
  /// hand that effect ownership of the node's bindings. The node's lifetime is
  /// the caller's, exactly like a [ChangeNotifier].
  final Owner owner = Owner.detached();

  ReactiveScene? _scene;
  GroupNode? _parent;

  // Cached composition values, refreshed by [_readTransform] when a property
  // changes and read by the per-frame walk.
  double _x = 0.0;
  double _y = 0.0;
  double _rotation = 0.0;
  double _scale = 1.0;
  double _opacity = 1.0;
  bool _visible = true;

  // Engine layers pushed for this node last frame, kept so they can be handed
  // back as `oldLayer`. Only [SceneBuilderCompositor] uses them.
  ui.TransformEngineLayer? _transformLayer;
  ui.OpacityEngineLayer? _opacityLayer;

  // Reused by [CanvasCompositor.pushOpacity], so a fading node allocates no
  // paint per frame.
  ui.Paint? _opacityPaint;

  Float64List? _matrix;

  bool _disposed = false;

  /// The scene this node belongs to, or null if it is not in one.
  ReactiveScene? get scene => _scene;

  /// The group this node is a child of, or null if it is a root or detached.
  GroupNode? get parent => _parent;

  void _readTransform() {
    _x = x?.call() ?? 0.0;
    _y = y?.call() ?? 0.0;
    _rotation = rotation?.call() ?? 0.0;
    _scale = scale?.call() ?? 1.0;
    _opacity = opacity?.call() ?? 1.0;
    _visible = visible?.call() ?? true;
    markNeedsComposition();
  }

  /// Records that this node's place in the scene changed.
  ///
  /// Cheap: no picture is re-recorded, only the parameters the compositor is
  /// called with, and the composition walk is unconditional. All this does is
  /// ask the scene for a frame. Called for you when a composition property
  /// changes.
  void markNeedsComposition() {
    _scene?._markNeedsCompose();
  }

  void _attach(ReactiveScene scene) {
    if (identical(_scene, scene)) {
      return;
    }
    _scene = scene;
    scene._markNeedsCompose();
  }

  /// Forgets the scene this node belonged to. Overridden to recurse.
  void _detachFromScene() {
    _scene = null;
  }

  Float64List _transformMatrix(double dx, double dy) {
    final Float64List m = _matrix ??= Float64List(16);
    final double c = math.cos(_rotation) * _scale;
    final double s = math.sin(_rotation) * _scale;
    m[0] = c;
    m[1] = s;
    m[4] = -s;
    m[5] = c;
    m[10] = 1.0;
    m[12] = dx;
    m[13] = dy;
    m[15] = 1.0;
    return m;
  }

  /// Walks this node and its children, sending them to `compositor`.
  ///
  /// `tx` and `ty` are the accumulated translation from the root, and `exact`
  /// says whether that translation is the whole story, that is, whether no
  /// ancestor rotated or scaled. When both hold, a node can cull itself against
  /// `cullRect` with two additions and four comparisons.
  ///
  /// This reads no signals and allocates nothing.
  void _compose(SceneCompositor compositor, double tx, double ty, bool exact, ui.Rect? cullRect) {
    if (_disposed) {
      // Disposing a node unlinks it from its parent, so reaching one here is a
      // bug in something holding a node list of its own. Loud in debug, and
      // skipped rather than crashing on a freed picture in release.
      assert(false, 'A disposed SceneNode was composed.');
      return;
    }
    if (!_visible || _opacity <= 0.0) {
      return;
    }
    final double nx = tx + _x;
    final double ny = ty + _y;
    final bool nExact = exact && _rotation == 0.0 && _scale == 1.0;
    if (!_prepareCompose(nx, ny, nExact, cullRect)) {
      return;
    }
    var pushed = 0;
    var cx = nx;
    var cy = ny;
    if (_opacity < 1.0) {
      compositor.pushOpacity(this, (_opacity * 255.0).round().clamp(0, 255));
      pushed += 1;
    }
    if (_rotation != 0.0 || _scale != 1.0) {
      // A rotated or scaled node is the only one that needs a layer of its own;
      // the translation accumulated so far is folded into its matrix, and its
      // children start again from the origin.
      compositor.pushTransform(this, _transformMatrix(nx, ny));
      pushed += 1;
      cx = 0.0;
      cy = 0.0;
    }
    _composeContents(compositor, cx, cy, nExact, cullRect);
    while (pushed > 0) {
      compositor.pop();
      pushed -= 1;
    }
  }

  /// Brings the node up to date and says whether it has anything inside
  /// `cullRect`. The base implementation composes unconditionally; only leaves
  /// that know their bounds cull.
  bool _prepareCompose(double tx, double ty, bool exact, ui.Rect? cullRect) => true;

  void _composeContents(
    SceneCompositor compositor,
    double tx,
    double ty,
    bool exact,
    ui.Rect? cullRect,
  );

  /// The top-most node containing `position`, expressed in this node's parent's
  /// coordinates, or null.
  SceneNode? _hitTest(ui.Offset position) {
    if (!_visible || _opacity <= 0.0) {
      return null;
    }
    double dx = position.dx - _x;
    double dy = position.dy - _y;
    if (_rotation != 0.0) {
      final double c = math.cos(-_rotation);
      final double s = math.sin(-_rotation);
      final double rx = dx * c - dy * s;
      dy = dx * s + dy * c;
      dx = rx;
    }
    if (_scale != 1.0 && _scale != 0.0) {
      dx /= _scale;
      dy /= _scale;
    }
    return _hitTestLocal(ui.Offset(dx, dy));
  }

  SceneNode? _hitTestLocal(ui.Offset localPosition);

  /// Releases this node's subscribers, pictures and engine layers.
  ///
  /// The node is removed from its parent group first, so nothing composes it
  /// again. Disposing a [GroupNode] disposes its children.
  @mustCallSuper
  void dispose() {
    assert(!_disposed, 'A SceneNode was disposed twice.');
    _parent?._detachChild(this);
    _disposed = true;
    owner.dispose();
    _transformLayer?.dispose();
    _opacityLayer?.dispose();
    _transformLayer = null;
    _opacityLayer = null;
    _scene = null;
  }

  /// Whether [dispose] has been called.
  bool get debugDisposed => _disposed;
}

/// A node that draws something, into a [ui.Picture] it retains.
///
/// The picture is re-recorded only when a property the recording read changes.
/// Everything else about the node -- where it is, how transparent it is,
/// whether it is visible -- changes without touching it.
///
/// Recording happens lazily, on the first frame the node is actually composed
/// in. A node that is culled or invisible therefore does not pay to record.
abstract class DrawableSceneNode extends SceneNode {
  /// Creates a drawable node.
  DrawableSceneNode({
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.opacity,
    super.visible,
    super.onPointerEvent,
  }) {
    owner.run(() {
      _pictureNode = TrackingNode(markNeedsPicture);
    });
  }

  late final TrackingNode _pictureNode;
  ui.Picture? _picture;
  ui.Rect _bounds = ui.Rect.zero;
  bool _pictureDirty = true;

  /// How many times this node's picture has been recorded.
  ///
  /// The liveness check for every benchmark and most tests in scene mode: the
  /// claim being made is that moving a node does not increment it.
  int debugRecordCount = 0;

  /// Whether the picture will be re-recorded on the next frame this node is
  /// composed in.
  bool get debugPictureDirty => _pictureDirty;

  /// This node's bounds in its own coordinates, as of the last recording.
  ///
  /// Used for culling and hit testing. Zero until the node has been composed
  /// at least once.
  ui.Rect get bounds => _bounds;

  /// Draws this node at its own origin.
  ///
  /// Called inside the node's picture tracking scope, so every reactive value
  /// read here is subscribed, and changing one re-records this node and only
  /// this node.
  @protected
  void paintNode(ui.Canvas canvas);

  /// This node's bounds in its own coordinates.
  ///
  /// Called immediately after [paintNode], in the same tracking scope.
  @protected
  ui.Rect computeBounds();

  /// Records that what this node draws changed, so its picture is re-recorded
  /// on the next frame.
  void markNeedsPicture() {
    _pictureDirty = true;
    _scene?._markNeedsCompose();
  }

  void _record() {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    paintNode(canvas);
    _bounds = computeBounds();
    _picture?.dispose();
    _picture = recorder.endRecording();
    debugRecordCount += 1;
  }

  @override
  bool _prepareCompose(double tx, double ty, bool exact, ui.Rect? cullRect) {
    if (_pictureDirty || _picture == null) {
      // Recording is deferred to here, rather than done in the effect that
      // marked the node dirty, so that a node the frame never reaches -- one
      // behind an invisible ancestor -- does not pay to record. A node whose
      // picture is dirty is recorded before the cull test, because its bounds
      // are not known until it has been.
      _pictureNode.track(_record);
      _pictureDirty = false;
    }
    if (cullRect != null && exact) {
      final ui.Rect b = _bounds;
      if (b.left + tx >= cullRect.right ||
          b.right + tx <= cullRect.left ||
          b.top + ty >= cullRect.bottom ||
          b.bottom + ty <= cullRect.top) {
        return false;
      }
    }
    return true;
  }

  @override
  void _composeContents(
    SceneCompositor compositor,
    double tx,
    double ty,
    bool exact,
    ui.Rect? cullRect,
  ) {
    compositor.addPicture(this, tx, ty, _picture!);
  }

  @override
  SceneNode? _hitTestLocal(ui.Offset localPosition) =>
      _bounds.contains(localPosition) ? this : null;

  @override
  void dispose() {
    _picture?.dispose();
    _picture = null;
    super.dispose();
  }
}

/// A rectangle of a single colour.
class RectNode extends DrawableSceneNode {
  /// Creates a rectangle node.
  RectNode({
    required this.color,
    required this.width,
    required this.height,
    this.anchor = ui.Offset.zero,
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.opacity,
    super.visible,
    super.onPointerEvent,
  });

  /// The fill colour.
  final ui.Color Function() color;

  /// The width, in logical pixels.
  final double Function() width;

  /// The height, in logical pixels.
  final double Function() height;

  /// Where the node's origin sits within its own box, as a fraction of its
  /// size. `Offset.zero` is the top left; `Offset(0.5, 0.5)` is the centre.
  final ui.Offset anchor;

  ui.Rect _rect = ui.Rect.zero;

  @override
  void paintNode(ui.Canvas canvas) {
    final double w = width();
    final double h = height();
    _rect = ui.Rect.fromLTWH(-anchor.dx * w, -anchor.dy * h, w, h);
    canvas.drawRect(_rect, ui.Paint()..color = color());
  }

  // Set by [paintNode], which runs immediately before this in the same
  // tracking scope, so the size signals are read once per recording.
  @override
  ui.Rect computeBounds() => _rect;
}

/// A filled circle centred on the node's origin.
class CircleNode extends DrawableSceneNode {
  /// Creates a circle node.
  CircleNode({
    required this.color,
    required this.radius,
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.opacity,
    super.visible,
    super.onPointerEvent,
  });

  /// The fill colour.
  final ui.Color Function() color;

  /// The radius, in logical pixels.
  final double Function() radius;

  @override
  void paintNode(ui.Canvas canvas) {
    canvas.drawCircle(ui.Offset.zero, radius(), ui.Paint()..color = color());
  }

  @override
  ui.Rect computeBounds() {
    final double r = radius();
    return ui.Rect.fromLTRB(-r, -r, r, r);
  }
}

/// An image, optionally a sub-rectangle of one, optionally tinted.
class SpriteNode extends DrawableSceneNode {
  /// Creates a sprite node.
  SpriteNode({
    required this.image,
    this.sourceRect,
    this.tint,
    this.anchor = ui.Offset.zero,
    this.filterQuality = ui.FilterQuality.low,
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.opacity,
    super.visible,
    super.onPointerEvent,
  });

  /// The image to draw. Not owned: disposing the node does not dispose it.
  final ui.Image Function() image;

  /// The part of [image] to draw, in image pixels. Defaults to all of it.
  final ui.Rect Function()? sourceRect;

  /// A colour multiplied into the sprite, or null for no tint.
  final ui.Color Function()? tint;

  /// Where the node's origin sits within the sprite, as a fraction of its size.
  final ui.Offset anchor;

  /// The sampling quality used when the sprite is scaled.
  final ui.FilterQuality filterQuality;

  ui.Rect _destination = ui.Rect.zero;

  @override
  void paintNode(ui.Canvas canvas) {
    final ui.Image source = image();
    final ui.Rect src =
        sourceRect?.call() ??
        ui.Rect.fromLTWH(0.0, 0.0, source.width.toDouble(), source.height.toDouble());
    _destination = ui.Rect.fromLTWH(
      -anchor.dx * src.width,
      -anchor.dy * src.height,
      src.width,
      src.height,
    );
    final paint = ui.Paint()..filterQuality = filterQuality;
    final ui.Color? colour = tint?.call();
    if (colour != null) {
      paint.colorFilter = ui.ColorFilter.mode(colour, ui.BlendMode.modulate);
    }
    canvas.drawImageRect(source, src, _destination, paint);
  }

  @override
  ui.Rect computeBounds() => _destination;
}

/// A node painted by an arbitrary callback.
///
/// The escape hatch, and the fast path for a crowd: a particle field of fifty
/// thousand points is one [PictureNode] whose painter reads one signal holding
/// a [Float32List], not fifty thousand nodes.
///
/// Reactive values read by [painter] are tracked, because the painter runs
/// inside this node's picture tracking scope. Changing one re-records this node
/// and nothing else.
class PictureNode extends DrawableSceneNode {
  /// Creates a node painted by `painter`.
  ///
  /// `bounds` is the node's extent in its own coordinates, used for culling and
  /// hit testing. It is not reactive and is not enforced: drawing outside it is
  /// allowed and simply is not accounted for.
  PictureNode({
    required this.painter,
    required ui.Rect bounds,
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.opacity,
    super.visible,
    super.onPointerEvent,
  }) : _declaredBounds = bounds;

  /// Draws the node at its own origin.
  final void Function(ui.Canvas canvas) painter;

  final ui.Rect _declaredBounds;

  @override
  void paintNode(ui.Canvas canvas) => painter(canvas);

  @override
  ui.Rect computeBounds() => _declaredBounds;
}

/// A run of text.
///
/// Deliberately minimal. Scene mode does not have the text stack: no
/// `TextSpan`, no inline widgets, no selection, no `TextPainter` caching
/// beyond the retained picture. What is here is one paragraph, laid out at
/// [maxWidth], re-laid-out when its reactive properties change.
class TextNode extends DrawableSceneNode {
  /// Creates a text node.
  TextNode({
    required this.text,
    this.fontSize,
    this.color,
    this.fontFamily,
    this.maxWidth = double.infinity,
    this.textAlign = ui.TextAlign.left,
    this.textDirection = ui.TextDirection.ltr,
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.opacity,
    super.visible,
    super.onPointerEvent,
  });

  /// The string to lay out.
  final String Function() text;

  /// The font size in logical pixels. Defaults to 14.
  final double Function()? fontSize;

  /// The text colour. Defaults to opaque white.
  final ui.Color Function()? color;

  /// The font family, or null for the platform default.
  final String? fontFamily;

  /// The width the paragraph is laid out at.
  final double maxWidth;

  /// How lines are aligned within [maxWidth].
  final ui.TextAlign textAlign;

  /// The reading direction.
  final ui.TextDirection textDirection;

  ui.Paragraph? _paragraph;

  @override
  void paintNode(ui.Canvas canvas) {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: textAlign,
        textDirection: textDirection,
        fontFamily: fontFamily,
        fontSize: fontSize?.call() ?? 14.0,
      ),
    );
    builder.pushStyle(ui.TextStyle(color: color?.call() ?? const ui.Color(0xFFFFFFFF)));
    builder.addText(text());
    final ui.Paragraph paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: maxWidth));
    _paragraph?.dispose();
    _paragraph = paragraph;
    canvas.drawParagraph(paragraph, ui.Offset.zero);
  }

  @override
  ui.Rect computeBounds() {
    final ui.Paragraph paragraph = _paragraph!;
    return ui.Rect.fromLTWH(0.0, 0.0, paragraph.longestLine, paragraph.height);
  }

  @override
  void dispose() {
    _paragraph?.dispose();
    _paragraph = null;
    super.dispose();
  }
}

/// A node that draws nothing itself and composes its children in order.
///
/// The children are either a list the caller mutates ([add], [remove]), or, in
/// [GroupNode.reactive], a reactive list. The reactive form is scene mode's
/// `For`: when the list signal changes, only the nodes that entered or left it
/// are touched. Identity is the key, so reordering the same nodes costs a scan
/// of the list and nothing else.
///
/// A node that leaves a reactive list is disposed, but not immediately: it is
/// put on the scene's orphan list and disposed at the start of the next frame,
/// and only if it has not been adopted by another group in the meantime. That
/// is what makes moving a node between two reactive groups in one [batch]
/// work, while still making the list signal the owner of its items' lifetimes.
///
/// A node belongs to at most one group. Adding one that already has a parent is
/// rejected, because composing the same node twice a frame would hand the
/// engine the same `oldLayer` twice.
class GroupNode extends SceneNode {
  /// Creates a group over a fixed list of children.
  ///
  /// The list is copied; use [add] and [remove] to change it afterwards.
  GroupNode({
    List<SceneNode> children = const <SceneNode>[],
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.opacity,
    super.visible,
    super.onPointerEvent,
  }) : _children = <SceneNode>[],
       childrenBuilder = null {
    children.forEach(_adopt);
  }

  /// Creates a group whose children come from a reactive list.
  GroupNode.reactive({
    required List<SceneNode> Function() children,
    super.x,
    super.y,
    super.rotation,
    super.scale,
    super.opacity,
    super.visible,
    super.onPointerEvent,
  }) : childrenBuilder = children,
       _children = const <SceneNode>[] {
    owner.run(() {
      _childrenEffect = Effect(_readChildren);
    });
  }

  /// The reactive child list, for [GroupNode.reactive]; null otherwise.
  final List<SceneNode> Function()? childrenBuilder;

  List<SceneNode> _children;
  Effect? _childrenEffect;

  /// The group's current children, in paint order: last is on top.
  List<SceneNode> get children => List<SceneNode>.unmodifiable(_children);

  /// Adds `child` to the end of a non-reactive group.
  ///
  /// The child must not already be in a group: a node composed twice in one
  /// frame would reuse its engine layers twice, which `dart:ui` forbids.
  void add(SceneNode child) {
    assert(childrenBuilder == null, 'The children of a reactive group come from its list signal.');
    _adopt(child);
    markNeedsComposition();
  }

  /// Takes `child` on, unless it already belongs somewhere.
  void _adopt(SceneNode child) {
    assert(
      child._parent == null,
      'A SceneNode can only be in one group at a time; remove it from its current group first.',
    );
    if (child._parent != null) {
      return;
    }
    child._parent = this;
    _children.add(child);
    final ReactiveScene? scene = _scene;
    if (scene != null) {
      child._attach(scene);
    }
  }

  /// Removes `child` from a non-reactive group, without disposing it.
  void remove(SceneNode child) {
    assert(childrenBuilder == null, 'The children of a reactive group come from its list signal.');
    if (_children.remove(child)) {
      child._parent = null;
      child._detachFromScene();
      markNeedsComposition();
    }
  }

  /// Drops a child that is disposing itself. Never disposes anything.
  void _detachChild(SceneNode child) {
    child._parent = null;
    if (_children.isNotEmpty && _children.remove(child)) {
      markNeedsComposition();
    }
  }

  void _readChildren() {
    final List<SceneNode> next = childrenBuilder!();
    final List<SceneNode> previous = _children;
    final kept = Set<SceneNode>.identity();
    final children = <SceneNode>[];
    for (final child in next) {
      if (!kept.add(child)) {
        assert(false, 'A SceneNode appeared twice in a reactive group; the duplicate is ignored.');
        continue;
      }
      children.add(child);
    }
    for (final child in previous) {
      // A child that another group has already claimed in this same flush has
      // moved, not left: its `_parent` is no longer us, and it is that group's
      // problem now.
      if (!kept.contains(child) && identical(child._parent, this)) {
        child._parent = null;
        final ReactiveScene? scene = _scene;
        if (scene != null) {
          scene._orphan(child);
        } else if (!child.debugDisposed) {
          child.dispose();
        }
      }
    }
    _children = children;
    final ReactiveScene? scene = _scene;
    for (final child in children) {
      child._parent = this;
      if (scene != null) {
        child._attach(scene);
      }
    }
    markNeedsComposition();
  }

  @override
  void _attach(ReactiveScene scene) {
    if (identical(_scene, scene)) {
      return;
    }
    super._attach(scene);
    for (final SceneNode child in _children) {
      child._attach(scene);
    }
  }

  @override
  void _detachFromScene() {
    super._detachFromScene();
    for (final SceneNode child in _children) {
      child._detachFromScene();
    }
  }

  @override
  void _composeContents(
    SceneCompositor compositor,
    double tx,
    double ty,
    bool exact,
    ui.Rect? cullRect,
  ) {
    final List<SceneNode> children = _children;
    for (var i = 0; i < children.length; i += 1) {
      children[i]._compose(compositor, tx, ty, exact, cullRect);
    }
  }

  @override
  SceneNode? _hitTestLocal(ui.Offset localPosition) {
    final List<SceneNode> children = _children;
    for (int i = children.length - 1; i >= 0; i -= 1) {
      final SceneNode? hit = children[i]._hitTest(localPosition);
      if (hit != null) {
        return hit;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _childrenEffect?.dispose();
    final List<SceneNode> children = _children;
    // Emptied first: a child's dispose() unlinks itself from its parent, and
    // that would mutate the list being walked.
    _children = <SceneNode>[];
    for (final child in children) {
      child._parent = null;
      if (!child.debugDisposed) {
        child.dispose();
      }
    }
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// The scene, and the standalone frame driver.
// ---------------------------------------------------------------------------

/// A retained scene graph, and the frame work that turns it into pixels.
///
/// A scene is composed by walking it once per frame and calling a
/// [SceneCompositor]. The walk is O(nodes), reads no signals and allocates
/// nothing; the work that scales with what actually changed is the recording,
/// which happens only for nodes whose picture is dirty.
///
/// A scene reaches the screen in one of two ways:
///
/// * standalone, through [attachToView], which drives
///   [ui.PlatformDispatcher.onBeginFrame] and [ui.PlatformDispatcher.onDrawFrame]
///   itself and needs no [WidgetsBinding] at all;
/// * embedded, through `SceneView`, one leaf render object in an otherwise
///   ordinary widget tree.
class ReactiveScene {
  /// Creates a scene rooted at `root`.
  ReactiveScene(this.root) {
    root._attach(this);
  }

  /// The root node. Its own transform applies to the whole scene.
  final SceneNode root;

  /// The rectangle outside which nodes are not composed. Null disables culling.
  ///
  /// In the same coordinates the scene is composed into, that is, the root
  /// node's parent coordinates: the root's own `x` and `y` move the scene
  /// within the cull rectangle rather than moving the rectangle.
  ///
  /// Culling only applies below an unrotated, unscaled ancestor chain, which is
  /// the common case for a camera that pans.
  ui.Rect? cullRect;

  final List<void Function()> _needsFrameListeners = <void Function()>[];
  final List<SceneNode> _orphans = <SceneNode>[];
  SceneDriver? _driver;

  bool _needsCompose = true;
  bool _disposed = false;

  /// Registers `listener` to be called when the scene becomes dirty and a frame
  /// is needed.
  ///
  /// There is a list rather than one slot because a scene can be shown by more
  /// than one `SceneView` at a time, and every one of them has to repaint.
  /// Each `SceneView` registers `markNeedsPaint`; [attachToView] registers
  /// [ui.PlatformDispatcher.scheduleFrame].
  void addNeedsFrameListener(void Function() listener) {
    _needsFrameListeners.add(listener);
  }

  /// Unregisters a listener added by [addNeedsFrameListener].
  void removeNeedsFrameListener(void Function() listener) {
    _needsFrameListeners.remove(listener);
  }

  /// How many frames this scene has composed. Diagnostic.
  int debugComposeCount = 0;

  /// Whether something changed since the last [composeFrame].
  bool get needsCompose => _needsCompose;

  void _markNeedsCompose() {
    if (_needsCompose || _disposed) {
      return;
    }
    _needsCompose = true;
    for (var i = 0; i < _needsFrameListeners.length; i += 1) {
      _needsFrameListeners[i]();
    }
  }

  /// Records that `node` has left its group and should be disposed at the start
  /// of the next frame, unless another group adopts it first.
  void _orphan(SceneNode node) {
    _orphans.add(node);
    _markNeedsCompose();
  }

  /// Walks the scene once, sending it to `compositor`.
  ///
  /// The caller is responsible for having drained the effect queue first, with
  /// [flushSignals]; otherwise the frame is composed from values that a pending
  /// effect is about to change. [SceneDriver.handleDrawFrame] does that
  /// immediately before composing. `RenderSceneView.paint` does not: embedded
  /// mode relies on the signal flush `WidgetsBinding` already runs before the
  /// build phase, so a write made *after* that flush — from a layout callback,
  /// or from another render object's paint — is composed one frame late.
  void composeFrame(SceneCompositor compositor) {
    assert(!_disposed, 'Cannot compose a disposed ReactiveScene.');
    if (_orphans.isNotEmpty) {
      for (final SceneNode node in _orphans) {
        if (node._parent == null && !node.debugDisposed) {
          node.dispose();
        }
      }
      _orphans.clear();
    }
    debugComposeCount += 1;
    _needsCompose = false;
    root._compose(compositor, 0.0, 0.0, true, cullRect);
  }

  /// The top-most node whose bounds contain `position`, or null.
  ///
  /// `position` is in the root node's parent coordinates, that is, the same
  /// space the scene is composed into.
  // ponytail: linear back-to-front scan over the whole tree. Fine up to a few
  // thousand nodes and for the one pointer event per frame a game gets. The
  // upgrade path is a uniform grid or a loose quadtree over `bounds`, rebuilt
  // from the same dirty set the compositor already maintains; nothing in the
  // API changes when that happens.
  SceneNode? hitTest(ui.Offset position) => root._hitTest(position);

  /// Delivers `event` to the top-most node under it, if that node wants it.
  ///
  /// There is no capture and no gesture arena: a node gets the events that land
  /// on it, and nothing else. Recognising a drag or a tap is the caller's job.
  void dispatchPointerEvent(PointerEvent event) {
    hitTest(event.localPosition)?.onPointerEvent?.call(event);
  }

  /// Drives this scene straight from the platform, with no [WidgetsBinding].
  ///
  /// Installs [signalFlushScheduler] so that a signal written outside a frame
  /// asks for one, takes over the view's frame and pointer callbacks, and
  /// schedules the first frame. This is the "no tree" ceiling: nothing exists
  /// per node except the node.
  ///
  /// Standalone mode is for an application that has no [WidgetsBinding] at all.
  /// Frame callbacks have exactly one owner, and this takes it: attaching while
  /// a binding owns them asserts, because the binding would stop producing
  /// frames.
  ///
  /// Returns the driver, so it can be detached again. Disposing the scene
  /// detaches it too.
  SceneDriver attachToView(ui.FlutterView view, {void Function(Duration elapsed)? onTick}) {
    final driver = SceneDriver(
      this,
      renderFrame: (ReactiveScene scene) {
        final builder = ui.SceneBuilder();
        scene.composeFrame(SceneBuilderCompositor(builder));
        final ui.Scene rendered = builder.build();
        view.render(rendered);
        rendered.dispose();
      },
      onTick: onTick,
    );
    driver.attachToView(view);
    return driver;
  }

  /// Disposes every node in the scene, and detaches the driver if there is one.
  void dispose() {
    _disposed = true;
    _driver?.detach();
    _needsFrameListeners.clear();
    for (final SceneNode node in _orphans) {
      if (!node.debugDisposed) {
        node.dispose();
      }
    }
    _orphans.clear();
    if (!root.debugDisposed) {
      root.dispose();
    }
  }
}

/// Runs a [ReactiveScene]'s frames without a [WidgetsBinding].
///
/// The driver is the whole of scene mode's standalone frame loop: take the
/// timestamp, let the game write its signals inside one [batch], drain the
/// effect queue, compose, render. [renderFrame] is injected so that the loop
/// can be tested, and benchmarked, without a real view.
class SceneDriver {
  /// Creates a driver for `scene`.
  SceneDriver(this.scene, {required this.renderFrame, this.onTick});

  /// The scene being driven.
  final ReactiveScene scene;

  /// Composes and presents the scene. Called once per frame, after the effect
  /// queue has been drained.
  final void Function(ReactiveScene scene) renderFrame;

  /// The game's per-frame work, run inside a [batch] so that however many
  /// signals it writes, each affected effect runs once.
  final void Function(Duration elapsed)? onTick;

  ui.FlutterView? _view;
  Duration _elapsed = Duration.zero;

  // What the view's callbacks were before this driver took them, so detaching
  // gives back what it borrowed rather than nulling them.
  ui.FrameCallback? _previousBeginFrame;
  ui.VoidCallback? _previousDrawFrame;
  ui.PointerDataPacketCallback? _previousPointerDataPacket;
  void Function()? _previousFlushScheduler;

  /// The timestamp of the frame currently being produced.
  Duration get elapsed => _elapsed;

  /// Runs the tick callback for a frame starting at `timeStamp`.
  void handleBeginFrame(Duration timeStamp) {
    _elapsed = timeStamp;
    final void Function(Duration elapsed)? tick = onTick;
    if (tick != null) {
      batch(() => tick(timeStamp));
    }
  }

  /// Drains the effect queue and renders one frame.
  void handleDrawFrame() {
    flushSignals();
    renderFrame(scene);
  }

  /// Takes over `view`'s frame and pointer callbacks.
  ///
  /// Only legal when nothing else owns them: a [WidgetsBinding] sets
  /// `onBeginFrame` when it initialises, and standalone scene mode exists for
  /// applications that never create one. There is no public nullable accessor
  /// for the binding, so the precondition is stated on the thing that actually
  /// matters — whether anybody is already driving frames.
  void attachToView(ui.FlutterView view) {
    assert(_view == null, 'This SceneDriver is already attached to a view.');
    final ui.PlatformDispatcher dispatcher = view.platformDispatcher;
    assert(
      dispatcher.onBeginFrame == null && dispatcher.onDrawFrame == null,
      "Something already owns this view's frame callbacks, most likely a "
      'WidgetsBinding. Standalone scene mode drives frames itself and is for '
      'applications with no binding; use SceneView to embed a scene instead.',
    );
    _view = view;
    _previousBeginFrame = dispatcher.onBeginFrame;
    _previousDrawFrame = dispatcher.onDrawFrame;
    _previousPointerDataPacket = dispatcher.onPointerDataPacket;
    _previousFlushScheduler = signalFlushScheduler;
    dispatcher.onBeginFrame = handleBeginFrame;
    dispatcher.onDrawFrame = handleDrawFrame;
    dispatcher.onPointerDataPacket = _handlePointerDataPacket;
    signalFlushScheduler = dispatcher.scheduleFrame;
    scene.addNeedsFrameListener(dispatcher.scheduleFrame);
    scene._driver = this;
    dispatcher.scheduleFrame();
  }

  /// Gives the view's callbacks back, as they were before [attachToView].
  void detach() {
    final ui.FlutterView? view = _view;
    if (view == null) {
      return;
    }
    final ui.PlatformDispatcher dispatcher = view.platformDispatcher;
    dispatcher.onBeginFrame = _previousBeginFrame;
    dispatcher.onDrawFrame = _previousDrawFrame;
    dispatcher.onPointerDataPacket = _previousPointerDataPacket;
    signalFlushScheduler = _previousFlushScheduler;
    scene.removeNeedsFrameListener(dispatcher.scheduleFrame);
    scene._driver = null;
    _previousBeginFrame = null;
    _previousDrawFrame = null;
    _previousPointerDataPacket = null;
    _previousFlushScheduler = null;
    _view = null;
  }

  void _handlePointerDataPacket(ui.PointerDataPacket packet) {
    final ui.FlutterView view = _view!;
    final int viewId = view.viewId;
    PointerEventConverter.expand(
      // Other views' pointers are not this scene's business.
      packet.data.where((ui.PointerData data) => data.viewId == viewId),
      (int id) => view.devicePixelRatio,
    ).forEach(scene.dispatchPointerEvent);
  }
}
