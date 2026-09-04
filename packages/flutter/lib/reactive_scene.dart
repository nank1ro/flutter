// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// A retained scene graph driven entirely by signals, with no widget, element
/// or render object per node.
///
/// To use, import `package:flutter/reactive_scene.dart`.
///
/// This is scene mode, phase 4 of the fork's plan: the option that gives up the
/// framework inside the scene in exchange for the lowest achievable per-node
/// cost. A node is an object with reactive properties and a retained
/// [dart:ui.Picture]. Moving one re-composes; changing what it draws re-records
/// it and nothing else.
///
/// ```dart
/// final Signal<double> x = Signal<double>(0);
/// final ReactiveScene scene = ReactiveScene(
///   GroupNode(
///     children: <SceneNode>[
///       RectNode(x: x, color: () => const Color(0xFFFF0000), width: () => 8, height: () => 8),
///     ],
///   ),
/// );
/// // Embedded in a widget tree:
/// //   SceneView(scene: scene)
/// // Standalone, with no WidgetsBinding at all:
/// //   scene.attachToView(view, onTick: (Duration t) => x.value = t.inMilliseconds / 16);
/// ```
///
/// What scene mode does not provide, deliberately: semantics, focus, text
/// input, the gesture arena, layout, and the widget library. See
/// `docs/fine_grained_reactivity/SCENE_MODE.md`.
library reactive_scene;

export 'src/reactive_scene/scene.dart';
export 'src/reactive_scene/scene_view.dart';
