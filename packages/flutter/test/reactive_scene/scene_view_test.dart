// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ui' as ui;

import 'package:flutter/reactive_scene.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts how many times it paints, so a test can assert that a scene change
/// did not reach outside the scene's repaint boundary.
class PaintCounter extends SingleChildRenderObjectWidget {
  const PaintCounter({super.key, super.child});

  @override
  RenderPaintCounter createRenderObject(BuildContext context) => RenderPaintCounter();
}

class RenderPaintCounter extends RenderProxyBox {
  int paints = 0;

  @override
  void paint(PaintingContext context, Offset offset) {
    paints += 1;
    super.paint(context, offset);
  }
}

/// Rebuilds are counted here, so a test can assert that a scene change caused
/// no element rebuild at all.
class BuildCounter extends StatelessWidget {
  const BuildCounter({super.key, required this.child, required this.counter});

  final Widget child;
  final List<int> counter;

  @override
  Widget build(BuildContext context) {
    counter[0] += 1;
    return child;
  }
}

void main() {
  testWidgets('a scene write repaints only the SceneView', (WidgetTester tester) async {
    final x = Signal<double>(0.0);
    final rect = RectNode(
      x: x.call,
      color: () => const ui.Color(0xFFFF0000),
      width: () => 10.0,
      height: () => 10.0,
    );
    final scene = ReactiveScene(rect);
    final builds = <int>[0];

    await tester.pumpWidget(
      PaintCounter(
        child: BuildCounter(
          counter: builds,
          child: Center(
            child: SizedBox(
              width: const .fixed(100),
              height: const .fixed(100),
              child: SceneView(scene: scene),
            ),
          ),
        ),
      ),
    );

    final RenderPaintCounter ancestor = tester.renderObject<RenderPaintCounter>(
      find.byType(PaintCounter),
    );
    final RenderSceneView view = tester.renderObject<RenderSceneView>(find.byType(SceneView));
    expect(builds[0], 1);
    expect(rect.debugRecordCount, 1);
    final int ancestorPaints = ancestor.paints;
    final int viewPaints = view.debugPaintCount;

    x.value = 20.0;
    await tester.pump();

    expect(view.debugPaintCount, viewPaints + 1, reason: 'the scene repainted');
    expect(
      ancestor.paints,
      ancestorPaints,
      reason: 'the scene is a repaint boundary; nothing above it repainted',
    );
    expect(builds[0], 1, reason: 'no element rebuilt');
    expect(rect.debugRecordCount, 1, reason: 'no picture was re-recorded');
    expect(scene.debugComposeCount, 2);

    scene.dispose();
  });

  testWidgets('a scene write reaches paint in the same frame', (WidgetTester tester) async {
    final radius = Signal<double>(4.0);
    final node = PictureNode(
      bounds: const ui.Rect.fromLTRB(-20, -20, 20, 20),
      painter: (ui.Canvas canvas) {
        canvas.drawCircle(ui.Offset.zero, radius.value, ui.Paint());
      },
    );
    final scene = ReactiveScene(node);

    await tester.pumpWidget(SceneView(scene: scene));
    expect(node.debugRecordCount, 1);

    radius.value = 9.0;
    await tester.pump();
    expect(node.debugRecordCount, 2, reason: 'the write was picked up by the same frame');

    scene.dispose();
  });

  testWidgets('pointer events reach the top-most node', (WidgetTester tester) async {
    final log = <PointerEvent>[];
    final target = RectNode(
      x: () => 10.0,
      y: () => 10.0,
      color: () => const ui.Color(0xFF00FF00),
      width: () => 40.0,
      height: () => 40.0,
      onPointerEvent: log.add,
    );
    final scene = ReactiveScene(GroupNode(children: <SceneNode>[target]));

    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: const .fixed(200),
          height: const .fixed(200),
          child: SceneView(scene: scene),
        ),
      ),
    );

    final Offset origin = tester.getTopLeft(find.byType(SceneView));
    await tester.tapAt(origin + const Offset(30, 30));
    await tester.pump();
    expect(log.whereType<PointerDownEvent>(), isNotEmpty);

    log.clear();
    await tester.tapAt(origin + const Offset(150, 150));
    await tester.pump();
    expect(log, isEmpty, reason: 'the tap missed every node');

    scene.dispose();
  });

  testWidgets('two views onto one scene both repaint', (WidgetTester tester) async {
    final x = Signal<double>(0.0);
    final rect = RectNode(
      x: x.call,
      color: () => const ui.Color(0xFFFF0000),
      width: () => 10.0,
      height: () => 10.0,
    );
    final scene = ReactiveScene(rect);

    await tester.pumpWidget(
      Column(
        children: <Widget>[
          SizedBox(
            width: const .fixed(50),
            height: const .fixed(50),
            child: SceneView(scene: scene),
          ),
          SizedBox(
            width: const .fixed(50),
            height: const .fixed(50),
            child: SceneView(scene: scene),
          ),
        ],
      ),
    );

    final List<RenderSceneView> views = tester
        .renderObjectList<RenderSceneView>(find.byType(SceneView))
        .toList();
    expect(views, hasLength(2));
    final before = <int>[for (final RenderSceneView v in views) v.debugPaintCount];

    x.value = 20.0;
    await tester.pump();

    expect(views[0].debugPaintCount, before[0] + 1);
    expect(views[1].debugPaintCount, before[1] + 1, reason: 'the second view is not stale');

    // Taking one view away must not stop the other from being told.
    await tester.pumpWidget(
      Column(
        children: <Widget>[
          SizedBox(
            width: const .fixed(50),
            height: const .fixed(50),
            child: SceneView(scene: scene),
          ),
        ],
      ),
    );
    final RenderSceneView survivor = tester.renderObject<RenderSceneView>(find.byType(SceneView));
    final int survivorPaints = survivor.debugPaintCount;
    x.value = 40.0;
    await tester.pump();
    expect(survivor.debugPaintCount, survivorPaints + 1);

    scene.dispose();
  });

  testWidgets('a SceneView must be given bounded constraints', (WidgetTester tester) async {
    final scene = ReactiveScene(GroupNode());
    final view = RenderSceneView(scene: scene);
    // Unbounded constraints would mean an infinite size, and an infinite cull
    // rectangle with it.
    expect(() => view.getDryLayout(const BoxConstraints()), throwsAssertionError);
    scene.dispose();
  });
}
