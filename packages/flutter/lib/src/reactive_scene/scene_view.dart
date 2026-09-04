// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Embedding a [ReactiveScene] in the classic widget tree.
library;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'scene.dart';

/// Shows a [ReactiveScene] inside an ordinary widget tree.
///
/// This is the whole of the embedded path: one widget, one element, one render
/// object, however many nodes the scene has. Nothing in the scene is a widget,
/// so nothing in the scene can cause a rebuild; a signal write reaches
/// [RenderSceneView] through the scene's dirty flag and stops there.
///
/// A scene may be shown by more than one [SceneView] at once; each one repaints
/// when the scene changes.
class SceneView extends LeafRenderObjectWidget {
  /// Creates a view onto `scene`.
  const SceneView({super.key, required this.scene});

  /// The scene to show. Not owned: disposing the widget does not dispose it.
  final ReactiveScene scene;

  @override
  RenderSceneView createRenderObject(BuildContext context) => RenderSceneView(scene: scene);

  @override
  void updateRenderObject(BuildContext context, RenderSceneView renderObject) {
    renderObject.scene = scene;
  }
}

/// The render object behind [SceneView].
///
/// A repaint boundary that fills its constraints and paints a [ReactiveScene]
/// into its own layer. When any node in the scene becomes dirty the scene calls
/// [markNeedsPaint]; because the effect that set the flag runs in the signal
/// flush `WidgetsBinding.drawFrame` performs before the build phase, the
/// repaint happens in the same frame as the write. A write made after that
/// flush -- from a layout callback, say -- is composed one frame late; this
/// render object does not flush signals itself during paint.
class RenderSceneView extends RenderBox {
  /// Creates a render object showing `scene`.
  RenderSceneView({required ReactiveScene scene}) : _scene = scene {
    scene.addNeedsFrameListener(markNeedsPaint);
  }

  ReactiveScene _scene;

  /// The scene being painted.
  ReactiveScene get scene => _scene;
  set scene(ReactiveScene value) {
    if (identical(_scene, value)) {
      return;
    }
    _scene.removeNeedsFrameListener(markNeedsPaint);
    _scene = value;
    value.addNeedsFrameListener(markNeedsPaint);
    markNeedsPaint();
  }

  /// How many times this render object has painted. Diagnostic; tests assert
  /// that an unrelated part of the tree did not repaint.
  int debugPaintCount = 0;

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    assert(
      constraints.biggest.isFinite,
      'SceneView must be given bounded constraints: it fills them, and an '
      'infinite size would give the scene an infinite cull rectangle. Wrap it '
      'in a SizedBox or an Expanded.',
    );
    return constraints.biggest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    debugPaintCount += 1;
    // The scene walk reads only cached fields, so nothing here reads a signal
    // outside a tracking scope. Re-recording a dirty node does read signals,
    // and does it inside that node's own tracking scope, which is what keeps
    // `debugSignalReadOutsideTracking` quiet during paint.
    _scene.cullRect = ui.Rect.fromLTWH(0.0, 0.0, size.width, size.height);
    final ui.Canvas canvas = context.canvas;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    _scene.composeFrame(CanvasCompositor(canvas));
    canvas.restore();
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    _scene.dispatchPointerEvent(event);
  }

  @override
  void dispose() {
    _scene.removeNeedsFrameListener(markNeedsPaint);
    super.dispose();
  }
}
