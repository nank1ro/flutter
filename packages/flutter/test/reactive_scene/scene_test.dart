// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/reactive_scene.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recording_compositor.dart';

const ui.Color _red = ui.Color(0xFFFF0000);

RectNode makeRect({double Function()? x, double Function()? y, double size = 10.0}) {
  return RectNode(x: x, y: y, color: () => _red, width: () => size, height: () => size);
}

void main() {
  test('a composition write re-composes the node without re-recording it', () {
    final x = Signal<double>(0.0);
    final RectNode rect = makeRect(x: x.call);
    final scene = ReactiveScene(rect);

    scene.composeFrame(RecordingCompositor());
    expect(rect.debugRecordCount, 1);
    expect(scene.needsCompose, isFalse);

    x.value = 12.0;
    flushSignals();
    expect(rect.debugPictureDirty, isFalse);
    expect(scene.needsCompose, isTrue);

    final compositor = RecordingCompositor();
    scene.composeFrame(compositor);
    expect(rect.debugRecordCount, 1, reason: 'moving a node must not re-record it');
    expect(compositor.operations, <String>['picture(12.0, 0.0)']);

    scene.dispose();
  });

  test('a signal read by a painter marks exactly that node picture dirty', () {
    final radius = Signal<double>(4.0);
    final painted = PictureNode(
      bounds: const ui.Rect.fromLTRB(-10, -10, 10, 10),
      painter: (ui.Canvas canvas) {
        canvas.drawCircle(ui.Offset.zero, radius.value, ui.Paint()..color = _red);
      },
    );
    final RectNode sibling = makeRect();
    final scene = ReactiveScene(GroupNode(children: <SceneNode>[painted, sibling]));

    scene.composeFrame(RecordingCompositor());
    expect(painted.debugRecordCount, 1);
    expect(sibling.debugRecordCount, 1);

    radius.value = 6.0;
    flushSignals();
    expect(painted.debugPictureDirty, isTrue);
    expect(sibling.debugPictureDirty, isFalse);

    scene.composeFrame(RecordingCompositor());
    expect(painted.debugRecordCount, 2, reason: 'exactly one re-record');
    expect(sibling.debugRecordCount, 1, reason: 'the sibling is untouched');

    scene.composeFrame(RecordingCompositor());
    expect(painted.debugRecordCount, 2, reason: 'a clean node is not re-recorded');

    scene.dispose();
  });

  test('writing an equal value does nothing at all', () {
    final x = Signal<double>(3.0);
    final RectNode rect = makeRect(x: x.call);
    final scene = ReactiveScene(rect);
    scene.composeFrame(RecordingCompositor());

    x.value = 3.0;
    flushSignals();
    expect(scene.needsCompose, isFalse);
    expect(rect.debugRecordCount, 1);

    scene.dispose();
  });

  test('a reactive group touches only the children that entered or left', () {
    final RectNode a = makeRect();
    final RectNode b = makeRect();
    final RectNode c = makeRect();
    final items = Signal<List<SceneNode>>(<SceneNode>[a, b]);
    final scene = ReactiveScene(GroupNode.reactive(children: () => items.value));
    scene.composeFrame(RecordingCompositor());
    expect(a.debugRecordCount, 1);
    expect(b.debugRecordCount, 1);

    // Reorder: nothing is disposed, nothing is re-recorded.
    items.value = <SceneNode>[b, a];
    flushSignals();
    scene.composeFrame(RecordingCompositor());
    expect(a.debugDisposed, isFalse);
    expect(b.debugDisposed, isFalse);
    expect(a.debugRecordCount, 1);
    expect(b.debugRecordCount, 1);

    // Add one: only the new node records.
    items.value = <SceneNode>[b, a, c];
    flushSignals();
    scene.composeFrame(RecordingCompositor());
    expect(c.debugRecordCount, 1);
    expect(a.debugRecordCount, 1);
    expect(b.debugRecordCount, 1);

    // Remove one: it is disposed at the next frame, the others are untouched.
    items.value = <SceneNode>[b, c];
    flushSignals();
    expect(a.debugDisposed, isFalse, reason: 'disposal waits for the next frame');
    scene.composeFrame(RecordingCompositor());
    expect(a.debugDisposed, isTrue);
    expect(b.debugDisposed, isFalse);
    expect(b.debugRecordCount, 1);
    expect(c.debugRecordCount, 1);

    scene.dispose();
  });

  test('disposing a node unlinks every subscription it had', () {
    final x = Signal<double>(0.0);
    final size = Signal<double>(5.0);
    final rect = RectNode(x: x.call, color: () => _red, width: size.call, height: size.call);
    final scene = ReactiveScene(rect);
    scene.composeFrame(RecordingCompositor());

    expect(x.subs, isNotNull);
    expect(size.subs, isNotNull);

    scene.dispose();

    expect(x.subs, isNull);
    expect(size.subs, isNull);
    expect(rect.debugDisposed, isTrue);
  });

  test('hit testing finds the top-most node under a point', () {
    final RectNode bottom = makeRect(x: () => 0.0, y: () => 0.0, size: 100.0);
    final RectNode top = makeRect(x: () => 20.0, y: () => 20.0);
    final scene = ReactiveScene(GroupNode(children: <SceneNode>[bottom, top]));
    scene.composeFrame(RecordingCompositor());

    expect(scene.hitTest(const ui.Offset(25, 25)), same(top));
    expect(scene.hitTest(const ui.Offset(5, 5)), same(bottom));
    expect(scene.hitTest(const ui.Offset(500, 500)), isNull);

    scene.dispose();
  });

  test('an invisible node and its children are not composed', () {
    final shown = Signal<bool>(true);
    final RectNode child = makeRect();
    final scene = ReactiveScene(GroupNode(visible: shown.call, children: <SceneNode>[child]));
    final first = RecordingCompositor();
    scene.composeFrame(first);
    expect(first.operations, contains('picture(0.0, 0.0)'));

    shown.value = false;
    flushSignals();
    final second = RecordingCompositor();
    scene.composeFrame(second);
    expect(second.operations, isEmpty);

    shown.value = true;
    flushSignals();
    final third = RecordingCompositor();
    scene.composeFrame(third);
    expect(third.operations, contains('picture(0.0, 0.0)'));

    scene.dispose();
  });

  test('a node outside the cull rect is neither recorded nor composed', () {
    final x = Signal<double>(5000.0);
    final RectNode rect = makeRect(x: x.call);
    final scene = ReactiveScene(rect)..cullRect = const ui.Rect.fromLTWH(0, 0, 800, 600);

    final offscreen = RecordingCompositor();
    scene.composeFrame(offscreen);
    expect(offscreen.operations, isEmpty);
    expect(rect.debugRecordCount, 1, reason: 'bounds are unknown until recorded once');

    x.value = 10.0;
    flushSignals();
    final onscreen = RecordingCompositor();
    scene.composeFrame(onscreen);
    expect(onscreen.operations, contains('picture(10.0, 0.0)'));
    expect(rect.debugRecordCount, 1);

    scene.dispose();
  });

  test('steady state adds no links and no subscribers', () {
    const nodeCount = 2000;
    final positions = <Signal<double>>[
      for (int i = 0; i < nodeCount; i += 1) Signal<double>(i.toDouble()),
    ];
    final nodes = <SceneNode>[
      for (int i = 0; i < nodeCount; i += 1) makeRect(x: positions[i].call),
    ];
    final scene = ReactiveScene(GroupNode(children: nodes));
    scene.composeFrame(RecordingCompositor());

    final Object firstLink = positions.first.subs!;
    final Object lastLink = positions.last.subs!;
    final int recordsBefore = (nodes.first as RectNode).debugRecordCount;

    for (var frame = 0; frame < 100; frame += 1) {
      batch(() {
        for (var i = 0; i < nodeCount; i += 1) {
          positions[i].value = (frame + i).toDouble();
        }
      });
      flushSignals();
      scene.composeFrame(RecordingCompositor());
    }

    expect(identical(positions.first.subs, firstLink), isTrue);
    expect(identical(positions.last.subs, lastLink), isTrue);
    expect(positions.first.subs!.nextSub, isNull, reason: 'exactly one subscriber per signal');
    expect((nodes.first as RectNode).debugRecordCount, recordsBefore);

    scene.dispose();
  });

  test('disposing a node unlinks it from its parent, and the scene composes on', () {
    final RectNode a = makeRect();
    final RectNode b = makeRect();
    final group = GroupNode(children: <SceneNode>[a, b]);
    final scene = ReactiveScene(group);
    scene.composeFrame(RecordingCompositor());

    a.dispose();
    expect(group.children, <SceneNode>[b]);
    expect(a.parent, isNull);

    final compositor = RecordingCompositor();
    scene.composeFrame(compositor);
    expect(compositor.pictures.length, 1, reason: 'the disposed node is gone, not composed');

    scene.dispose();
  });

  test('remove clears the scene of the whole subtree it takes out', () {
    final RectNode leaf = makeRect();
    final inner = GroupNode(children: <SceneNode>[leaf]);
    final root = GroupNode(children: <SceneNode>[inner]);
    final scene = ReactiveScene(root);
    scene.composeFrame(RecordingCompositor());
    expect(inner.scene, same(scene));
    expect(leaf.scene, same(scene));

    root.remove(inner);
    expect(inner.scene, isNull);
    expect(leaf.scene, isNull, reason: 'detaching is recursive');
    expect(inner.parent, isNull);
    expect(inner.debugDisposed, isFalse, reason: 'remove does not dispose');

    final compositor = RecordingCompositor();
    scene.composeFrame(compositor);
    expect(compositor.operations, isEmpty);

    inner.dispose();
    scene.dispose();
  });

  test('a node cannot be in two groups at once', () {
    final RectNode node = makeRect();
    final first = GroupNode(children: <SceneNode>[node]);
    final second = GroupNode();

    expect(() => second.add(node), throwsAssertionError);
    expect(() => first.add(node), throwsAssertionError);
    expect(node.parent, same(first));
    expect(second.children, isEmpty);
    expect(() => GroupNode(children: <SceneNode>[node]), throwsAssertionError);

    first.dispose();
    second.dispose();
  });

  test('a node moved between two reactive groups in one batch survives', () {
    final RectNode node = makeRect();
    final left = Signal<List<SceneNode>>(<SceneNode>[node]);
    final right = Signal<List<SceneNode>>(<SceneNode>[]);
    final scene = ReactiveScene(
      GroupNode(
        children: <SceneNode>[
          GroupNode.reactive(children: () => left.value),
          GroupNode.reactive(children: () => right.value),
        ],
      ),
    );
    scene.composeFrame(RecordingCompositor());
    expect(node.debugRecordCount, 1);

    batch(() {
      left.value = <SceneNode>[];
      right.value = <SceneNode>[node];
    });
    flushSignals();
    scene.composeFrame(RecordingCompositor());

    expect(node.debugDisposed, isFalse, reason: 'the node moved, it did not leave');
    expect(node.debugRecordCount, 1, reason: 'moving groups does not re-record');

    // ... and one that really did leave is disposed at the next frame.
    right.value = <SceneNode>[];
    flushSignals();
    expect(node.debugDisposed, isFalse);
    scene.composeFrame(RecordingCompositor());
    expect(node.debugDisposed, isTrue);

    scene.dispose();
  });

  test('engine layers are reused across frames by a real SceneBuilder', () {
    final angle = Signal<double>(0.0);
    final spinner = RectNode(
      rotation: angle.call,
      color: () => _red,
      width: () => 10.0,
      height: () => 10.0,
    );
    final scaled = RectNode(
      scale: () => 2.0,
      color: () => _red,
      width: () => 4.0,
      height: () => 4.0,
    );
    final scene = ReactiveScene(
      GroupNode(
        opacity: () => 0.5,
        children: <SceneNode>[
          spinner,
          GroupNode(opacity: () => 0.25, children: <SceneNode>[scaled]),
        ],
      ),
    );

    // Three frames through the real thing: an engine layer may only be handed
    // back as `oldLayer` once, so a compositor that kept a stale layer would
    // assert inside dart:ui here.
    for (var frame = 0; frame < 3; frame += 1) {
      angle.value = frame * 0.1;
      flushSignals();
      final builder = ui.SceneBuilder();
      scene.composeFrame(SceneBuilderCompositor(builder));
      builder.build().dispose();
    }

    expect(spinner.debugRecordCount, 1, reason: 'rotating never re-records');
    expect(scaled.debugRecordCount, 1);

    scene.dispose();
  });
}
