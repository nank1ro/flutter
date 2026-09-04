// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/reactive_scene.dart';

/// A [SceneCompositor] that records what the scene walk asked for, so a test
/// can assert on the operations rather than on pixels.
class RecordingCompositor extends SceneCompositor {
  /// One string per call, in order: `transform(dx, dy)`, `opacity(alpha)`,
  /// `picture(dx, dy)`, `pop`.
  final List<String> operations = <String>[];

  /// The pictures handed to [addPicture], in order.
  final List<ui.Picture> pictures = <ui.Picture>[];

  /// The `dx` of the last [addPicture], or NaN if there has not been one.
  double lastDx = double.nan;

  @override
  void pushTransform(SceneNode node, Float64List matrix) {
    operations.add('transform(${matrix[12]}, ${matrix[13]})');
  }

  @override
  void pushOpacity(SceneNode node, int alpha) {
    operations.add('opacity($alpha)');
  }

  @override
  void addPicture(SceneNode node, double dx, double dy, ui.Picture picture) {
    operations.add('picture($dx, $dy)');
    pictures.add(picture);
    lastDx = dx;
  }

  @override
  void pop() {
    operations.add('pop');
  }
}
