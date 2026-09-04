// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B9: scene mode -- B1's and B3's workloads re-run against the retained scene
// graph of `package:flutter/reactive_scene.dart` (phase 4). See
// docs/fine_grained_reactivity/SCENE_MODE.md for the numbers and
// docs/fine_grained_reactivity/BENCHMARKS.md for the scenarios.
//
// There is no legacy-Flutter baseline for this scenario: a retained scene
// graph that bypasses the widget/element/render-object tree does not exist on
// unmodified Flutter, which is why BENCHMARKS.md marks B9's baseline columns
// "n/a". The comparison points are B1's and B3's own numbers.
//
// Two things are measured for each workload:
//  - headless: the scene's own frame work, `flushSignals` plus
//    `composeFrame` onto a real `ui.SceneBuilder`. This is standalone mode
//    with the platform's present call removed, and it is the "no tree"
//    ceiling.
//  - embedded: the same scene inside a `SceneView` in a widget tree, driven
//    by `tester.pump()`, so the number includes the whole framework frame.
//
// Every measurement carries a liveness assertion. The claim scene mode makes
// is that moving a node does not re-record its picture, so every timed loop
// asserts on `debugRecordCount`; a benchmark that silently stopped doing work
// would fail rather than look fast.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/reactive_scene.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kNodeCount = 10000;
const int kParticleCount = 50000;
const ui.Color kBlue = ui.Color(0xFF2196F3);

/// Builds `kNodeCount` rectangles, one position signal each.
({ReactiveScene scene, List<Signal<double>> positions, List<RectNode> nodes}) buildScene() {
  final positions = <Signal<double>>[
    for (int i = 0; i < kNodeCount; i += 1) Signal<double>((i % 800).toDouble()),
  ];
  final nodes = <RectNode>[
    for (int i = 0; i < kNodeCount; i += 1)
      RectNode(
        x: positions[i],
        y: () => (i ~/ 800).toDouble(),
        color: () => kBlue,
        width: () => 1.0,
        height: () => 1.0,
      ),
  ];
  final scene = ReactiveScene(GroupNode(children: nodes));
  return (scene: scene, positions: positions, nodes: nodes);
}

/// One headless frame: drain the queue, walk the scene into a scene builder,
/// build and drop the resulting scene. This is what `SceneDriver` does, minus
/// `FlutterView.render`.
void composeHeadlessFrame(ReactiveScene scene) {
  flushSignals();
  final builder = ui.SceneBuilder();
  scene.composeFrame(SceneBuilderCompositor(builder));
  builder.build().dispose();
}

void main() {
  group('headless', () {
    late void Function()? previousScheduler;

    setUp(() {
      previousScheduler = signalFlushScheduler;
      // Stand in for the platform's scheduleFrame: writes queue, and the frame
      // drains them, which is what standalone mode does.
      signalFlushScheduler = () {};
    });

    tearDown(() {
      signalFlushScheduler = previousScheduler;
    });

    test('B9 scene headless move one of 10000', () async {
      final ({List<RectNode> nodes, List<Signal<double>> positions, ReactiveScene scene}) built =
          buildScene();
      composeHeadlessFrame(built.scene);
      expect(built.nodes.first.debugRecordCount, 1);

      var i = 0;
      const timedIterations = 200;
      final List<double> values = await timeIterations(
        warmup: 20,
        iterations: timedIterations,
        body: () async {
          built.positions[i % kNodeCount].value = (i % 797).toDouble() + 0.5;
          i += 1;
          composeHeadlessFrame(built.scene);
        },
      );
      // Liveness: every frame composed, and not one picture was re-recorded.
      expect(built.scene.debugComposeCount, timedIterations + 21);
      for (final RectNode node in built.nodes) {
        expect(node.debugRecordCount, 1);
      }
      printMedian('b9_scene_headless_move_one_of_10000', values);
      built.scene.dispose();
    });

    test('B9 scene headless move all 10000 in one batch', () async {
      final ({List<RectNode> nodes, List<Signal<double>> positions, ReactiveScene scene}) built =
          buildScene();
      composeHeadlessFrame(built.scene);

      var frame = 0;
      const timedIterations = 50;
      final List<double> values = await timeIterations(
        warmup: 5,
        iterations: timedIterations,
        body: () async {
          frame += 1;
          batch(() {
            for (var i = 0; i < kNodeCount; i += 1) {
              built.positions[i].value = ((i + frame) % 797).toDouble();
            }
          });
          composeHeadlessFrame(built.scene);
        },
      );
      expect(built.scene.debugComposeCount, timedIterations + 6);
      for (final RectNode node in built.nodes) {
        expect(node.debugRecordCount, 1);
      }
      printMedian('b9_scene_headless_move_all_10000_batched', values);
      built.scene.dispose();
    });

    test('B9 scene headless 50000 particles in one PictureNode', () async {
      // Two pre-filled buffers, swapped each frame, so the timed work is the
      // scene's -- one re-record of 50,000 points and one compose -- and not
      // the simulation's.
      final buffers = <Float32List>[
        Float32List(kParticleCount * 2),
        Float32List(kParticleCount * 2),
      ];
      for (var b = 0; b < 2; b += 1) {
        for (var i = 0; i < kParticleCount * 2; i += 1) {
          buffers[b][i] = ((i * 7 + b) % 800).toDouble();
        }
      }
      final points = Signal<Float32List>(buffers[0]);
      final paint = ui.Paint()
        ..color = kBlue
        ..strokeWidth = 1.0;
      final field = PictureNode(
        bounds: const ui.Rect.fromLTWH(0, 0, 800, 600),
        painter: (ui.Canvas canvas) {
          canvas.drawRawPoints(ui.PointMode.points, points.value, paint);
        },
      );
      final scene = ReactiveScene(field);
      composeHeadlessFrame(scene);
      expect(field.debugRecordCount, 1);

      var frame = 0;
      const timedIterations = 50;
      final List<double> values = await timeIterations(
        warmup: 5,
        iterations: timedIterations,
        body: () async {
          frame += 1;
          points.value = buffers[frame & 1];
          composeHeadlessFrame(scene);
        },
      );
      // Liveness: one re-record per frame, and no more.
      expect(field.debugRecordCount, timedIterations + 6);
      printMedian('b9_scene_headless_50000_particles', values);
      scene.dispose();
    });

    test('B9 scene headless mount and dispose 10000 nodes', () async {
      List<RectNode>? last;
      final List<double> values = await timeIterations(
        warmup: 2,
        iterations: 10,
        body: () async {
          final ({List<RectNode> nodes, List<Signal<double>> positions, ReactiveScene scene})
          built = buildScene();
          composeHeadlessFrame(built.scene);
          built.scene.dispose();
          last = built.nodes;
        },
      );
      // Liveness, checked outside the timed body: the loop really did mount and
      // dispose ten thousand nodes.
      expect(last, hasLength(kNodeCount));
      expect(last!.first.debugDisposed, isTrue);
      printMedian('b9_scene_headless_mount_dispose_10000', values);
    });
  });

  testWidgets('B9 scene embedded move one of 10000', (WidgetTester tester) async {
    final ({List<RectNode> nodes, List<Signal<double>> positions, ReactiveScene scene}) built =
        buildScene();
    await tester.pumpWidget(SceneView(scene: built.scene));
    expect(built.nodes.first.debugRecordCount, 1);

    var i = 0;
    const timedIterations = 200;
    for (var w = 0; w < 20; w += 1) {
      built.positions[i % kNodeCount].value = (i % 797).toDouble() + 0.5;
      i += 1;
      await tester.pump();
    }
    final int composesBefore = built.scene.debugComposeCount;
    final List<double> values = await timeIterations(
      warmup: 0,
      iterations: timedIterations,
      body: () async {
        built.positions[i % kNodeCount].value = (i % 797).toDouble() + 0.5;
        i += 1;
        await tester.pump();
      },
    );
    // Liveness: every pump repainted the scene, and nothing was re-recorded.
    expect(built.scene.debugComposeCount - composesBefore, timedIterations);
    for (final RectNode node in built.nodes) {
      expect(node.debugRecordCount, 1);
    }
    printMedian('b9_scene_embedded_move_one_of_10000', values);
    built.scene.dispose();
  });

  testWidgets('B9 scene embedded move all 10000 in one batch', (WidgetTester tester) async {
    final ({List<RectNode> nodes, List<Signal<double>> positions, ReactiveScene scene}) built =
        buildScene();
    await tester.pumpWidget(SceneView(scene: built.scene));

    var frame = 0;
    const timedIterations = 50;
    const warmupIterations = 5;
    final int composesBefore = built.scene.debugComposeCount;
    final List<double> values = await timeIterations(
      warmup: warmupIterations,
      iterations: timedIterations,
      body: () async {
        frame += 1;
        batch(() {
          for (var i = 0; i < kNodeCount; i += 1) {
            built.positions[i].value = ((i + frame) % 797).toDouble();
          }
        });
        await tester.pump();
      },
    );
    // Liveness: every pump repainted the scene, and nothing was re-recorded.
    expect(built.scene.debugComposeCount - composesBefore, timedIterations + warmupIterations);
    for (final RectNode node in built.nodes) {
      expect(node.debugRecordCount, 1);
    }
    printMedian('b9_scene_embedded_move_all_10000_batched', values);
    built.scene.dispose();
  });
}
