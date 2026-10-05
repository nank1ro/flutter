// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B9: scene mode -- the retained scene graph of
// `package:flutter/reactive_scene.dart` (Phase 4). See
// docs/fine_grained_reactivity/SCENE_MODE.md for the design and
// docs/fine_grained_reactivity/BENCHMARKS.md for the scenarios.
//
// There is no legacy-Flutter baseline for a retained scene graph, so the
// comparison points are the fork's own classic-tree variants. Those are run
// *inside this file*, on the same workload, interleaved and rotated by
// `runInterleaved`, so scene mode is never compared against a number from
// another process.
//
// The workload is a move, not a colour change, in every variant: the scene's
// whole claim is that moving a node does not re-record its picture, and the
// paint-only classic equivalents are `ReactiveOffset` and `ROffset`.
//
// Two scene paths are measured:
//  - headless: the scene's own frame work, `flushSignals` plus `composeFrame`
//    onto a real `ui.SceneBuilder`. That is standalone mode with the
//    platform's present call removed, and it is the "no tree" ceiling. It is
//    not comparable to the classic rows, which include a whole framework
//    frame; the row to compare those against is the embedded one.
//  - embedded: the same scene inside a `SceneView` in a widget tree, driven by
//    `benchPump(tester)`, so the number includes the whole framework frame.
//
// Nodes per sprite:
//   scene      1 RectNode, no render object at all
//   classic    Positioned > ReactiveOffset > ColoredBox        (2 render objects)
//   collapsed  RPositioned > ROffset > RBox                    (2 render objects)
// The classic and collapsed shapes match each other exactly; the scene cannot
// be shape-matched to either, because having no render objects is the whole
// point of it.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/reactive_nodes.dart';
import 'package:flutter/reactive_scene.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

typedef _Built = ({ReactiveScene scene, List<Signal<double>> positions, List<RectNode> nodes});

const int kNodeCount = 10000;
const int kParticleCount = 50000;
const ui.Color kBlue = ui.Color(0xFF2196F3);

const int kMoveOneWarmup = 3;
const int kMoveOneTimed = 12;
const int kMoveAllWarmup = 1;
const int kMoveAllTimed = 6;
const int kParticleWarmup = 3;
const int kParticleTimed = 15;
const int kLifecycleWarmup = 1;
const int kLifecycleTimed = 2;

int _probeBuilds = 0;
int _effectRuns = 0;
int _componentRuns = 0;

double _xFor(int i) => (i % 797).toDouble() + 0.5;

/// Builds `kNodeCount` rectangles, one x-position signal each.
_Built _buildScene() => _buildSceneFrom(_allocPositions());

/// Allocates the `kNodeCount` x-position signals that [_buildSceneFrom] reads.
List<Signal<double>> _allocPositions() => <Signal<double>>[
  for (var i = 0; i < kNodeCount; i += 1) Signal<double>((i % 800).toDouble()),
];

/// Builds the nodes and the scene from already-allocated [positions].
_Built _buildSceneFrom(List<Signal<double>> positions) {
  final nodes = <RectNode>[
    for (var i = 0; i < kNodeCount; i += 1)
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
void _composeHeadlessFrame(ReactiveScene scene) {
  flushSignals();
  final builder = ui.SceneBuilder();
  scene.composeFrame(SceneBuilderCompositor(builder));
  builder.build().dispose();
}

/// Runs [body] with the platform's flush scheduler replaced by a no-op, so
/// writes queue and the headless frame drains them -- which is what standalone
/// mode does.
Future<T> _headless<T>(Future<T> Function() body) async {
  final void Function()? previous = signalFlushScheduler;
  signalFlushScheduler = () {};
  try {
    return await body();
  } finally {
    signalFlushScheduler = previous;
  }
}

/// Counts its own builds, above the sprites.
class _BuildProbe extends StatelessWidget {
  const _BuildProbe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    _probeBuilds++;
    return child;
  }
}

// ---------------------------------------------------------------------------
// Move one of 10,000.
// ---------------------------------------------------------------------------

Future<double> _sceneHeadlessMoveOne(WidgetTester tester) async {
  return _headless(() async {
    final _Built built = _buildScene();
    _composeHeadlessFrame(built.scene);
    expect(built.nodes.first.debugRecordCount, 1);

    var i = 0;
    final List<double> values = await timeIterations(
      warmup: kMoveOneWarmup,
      iterations: kMoveOneTimed,
      body: () async {
        built.positions[i % kNodeCount].value = _xFor(i);
        i += 1;
        _composeHeadlessFrame(built.scene);
      },
    );
    // Liveness: every frame composed, and not one picture was re-recorded.
    expect(built.scene.debugComposeCount, kMoveOneWarmup + kMoveOneTimed + 1);
    for (final RectNode node in built.nodes) {
      expect(node.debugRecordCount, 1);
    }
    built.scene.dispose();
    return median(values);
  });
}

Future<double> _sceneEmbeddedMoveOne(WidgetTester tester) async {
  final _Built built = _buildScene();
  await benchPumpWidget(tester, SceneView(scene: built.scene));
  expect(built.nodes.first.debugRecordCount, 1);

  var i = 0;
  for (var w = 0; w < kMoveOneWarmup; w += 1) {
    built.positions[i % kNodeCount].value = _xFor(i);
    i += 1;
    await benchPump(tester);
  }
  final int composesBefore = built.scene.debugComposeCount;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kMoveOneTimed,
    body: () async {
      built.positions[i % kNodeCount].value = _xFor(i);
      i += 1;
      await benchPump(tester);
    },
  );
  // Liveness: every pump repainted the scene, and nothing was re-recorded.
  expect(built.scene.debugComposeCount - composesBefore, kMoveOneTimed);
  for (final RectNode node in built.nodes) {
    expect(node.debugRecordCount, 1);
  }
  await benchPumpWidget(tester, const SizedBox.shrink());
  built.scene.dispose();
  return median(values);
}

Future<double> _leafMoveOne(WidgetTester tester) async {
  final offsets = List<Signal<Offset>>.generate(
    kNodeCount,
    (int i) => Signal<Offset>(Offset((i % 800).toDouble(), 0)),
  );
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: _BuildProbe(
        child: mountAllInRows([
          for (final s in offsets)
            ReactiveOffset(
              offset: s,
              child: const ColoredBox(color: .fixed(Color(0xFF2196F3))),
            ),
        ]),
      ),
    ),
  );
  expect(
    find.byType(Positioned),
    findsAtLeastNWidgets(kNodeCount),
  ); // integration surface may hold stray nodes

  var i = 0;
  for (var w = 0; w < kMoveOneWarmup; w++) {
    offsets[i % kNodeCount].value = Offset(_xFor(i), 0);
    i++;
    await benchPump(tester);
  }
  _probeBuilds = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kMoveOneTimed,
    body: () async {
      offsets[i % kNodeCount].value = Offset(_xFor(i), 0);
      i++;
      await benchPump(tester);
    },
  );
  // Liveness: the render object really took the last offset written, and
  // nothing rebuilt.
  expect(
    tester
        .renderObjectList<RenderReactiveOffset>(find.byType(ReactiveOffset))
        .elementAt((i - 1) % kNodeCount)
        .offset,
    Offset(_xFor(i - 1), 0),
  );
  expect(_probeBuilds, 0);
  await benchPumpWidget(tester, const SizedBox.shrink());
  return median(values);
}

Future<double> _collapsedMoveOne(WidgetTester tester) async {
  final offsets = List<Signal<Offset>>.generate(
    kNodeCount,
    (int i) => Signal<Offset>(Offset((i % 800).toDouble(), 0)),
  );
  final moved = <ROffset>[];
  _componentRuns = 0;
  final root = RComponent(() {
    _componentRuns += 1;
    return RStack(
      children: <RNode>[
        for (var i = 0; i < kNodeCount; i++)
          RPositioned(
            left: 0,
            top: i.toDouble(),
            width: 800,
            height: 1,
            child: () {
              final node = ROffset(
                offset: () {
                  _effectRuns += 1;
                  return offsets[i].value;
                },
                child: RBox(color: () => kBlue),
              );
              moved.add(node);
              return node;
            }(),
          ),
      ],
    );
  });
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: SizedBox(
        width: const .fixed(800),
        height: .fixed(kNodeCount.toDouble()),
        child: NodeHost(node: root),
      ),
    ),
  );
  expect(moved, hasLength(kNodeCount));

  var i = 0;
  for (var w = 0; w < kMoveOneWarmup; w++) {
    offsets[i % kNodeCount].value = Offset(_xFor(i), 0);
    i++;
    await benchPump(tester);
  }
  _effectRuns = 0;
  final List<double> values = await timeIterations(
    warmup: 0,
    iterations: kMoveOneTimed,
    body: () async {
      offsets[i % kNodeCount].value = Offset(_xFor(i), 0);
      i++;
      await benchPump(tester);
    },
  );
  expect(moved[(i - 1) % kNodeCount].renderObject.offset, Offset(_xFor(i - 1), 0));
  expect(_effectRuns, kMoveOneTimed);
  expect(_componentRuns, 1);

  await benchPumpWidget(tester, const SizedBox.shrink());
  root.dispose();
  return median(values);
}

// ---------------------------------------------------------------------------
// Move all 10,000 in one batch.
// ---------------------------------------------------------------------------

Future<double> _sceneHeadlessMoveAll(WidgetTester tester) async {
  return _headless(() async {
    final _Built built = _buildScene();
    _composeHeadlessFrame(built.scene);

    var frame = 0;
    final List<double> values = await timeIterations(
      warmup: kMoveAllWarmup,
      iterations: kMoveAllTimed,
      body: () async {
        frame += 1;
        batch<void>(() {
          for (var i = 0; i < kNodeCount; i += 1) {
            built.positions[i].value = ((i + frame) % 797).toDouble();
          }
        });
        _composeHeadlessFrame(built.scene);
      },
    );
    expect(built.scene.debugComposeCount, kMoveAllWarmup + kMoveAllTimed + 1);
    for (final RectNode node in built.nodes) {
      expect(node.debugRecordCount, 1);
    }
    built.scene.dispose();
    return median(values);
  });
}

Future<double> _sceneEmbeddedMoveAll(WidgetTester tester) async {
  final _Built built = _buildScene();
  await benchPumpWidget(tester, SceneView(scene: built.scene));

  var frame = 0;
  final int composesBefore = built.scene.debugComposeCount;
  final List<double> values = await timeIterations(
    warmup: kMoveAllWarmup,
    iterations: kMoveAllTimed,
    body: () async {
      frame += 1;
      batch<void>(() {
        for (var i = 0; i < kNodeCount; i += 1) {
          built.positions[i].value = ((i + frame) % 797).toDouble();
        }
      });
      await benchPump(tester);
    },
  );
  expect(built.scene.debugComposeCount - composesBefore, kMoveAllWarmup + kMoveAllTimed);
  for (final RectNode node in built.nodes) {
    expect(node.debugRecordCount, 1);
  }
  await benchPumpWidget(tester, const SizedBox.shrink());
  built.scene.dispose();
  return median(values);
}

Future<double> _leafMoveAll(WidgetTester tester) async {
  final offsets = List<Signal<Offset>>.generate(
    kNodeCount,
    (int i) => Signal<Offset>(Offset((i % 800).toDouble(), 0)),
  );
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: _BuildProbe(
        child: mountAllInRows([
          for (final s in offsets)
            ReactiveOffset(
              offset: () {
                _effectRuns += 1;
                return s.value;
              },
              child: const ColoredBox(color: .fixed(Color(0xFF2196F3))),
            ),
        ]),
      ),
    ),
  );
  expect(
    find.byType(Positioned),
    findsAtLeastNWidgets(kNodeCount),
  ); // integration surface may hold stray nodes

  var frame = 0;
  _probeBuilds = 0;
  _effectRuns = 0;
  final List<double> values = await timeIterations(
    warmup: kMoveAllWarmup,
    iterations: kMoveAllTimed,
    body: () async {
      frame += 1;
      batch<void>(() {
        for (var i = 0; i < kNodeCount; i++) {
          offsets[i].value = Offset(((i + frame) % 797).toDouble(), 0);
        }
      });
      await benchPump(tester);
    },
  );
  expect(_effectRuns, kNodeCount * (kMoveAllWarmup + kMoveAllTimed));
  expect(_probeBuilds, 0);
  await benchPumpWidget(tester, const SizedBox.shrink());
  return median(values);
}

Future<double> _collapsedMoveAll(WidgetTester tester) async {
  final offsets = List<Signal<Offset>>.generate(
    kNodeCount,
    (int i) => Signal<Offset>(Offset((i % 800).toDouble(), 0)),
  );
  _componentRuns = 0;
  final root = RComponent(() {
    _componentRuns += 1;
    return RStack(
      children: <RNode>[
        for (var i = 0; i < kNodeCount; i++)
          RPositioned(
            left: 0,
            top: i.toDouble(),
            width: 800,
            height: 1,
            child: ROffset(
              offset: () {
                _effectRuns += 1;
                return offsets[i].value;
              },
              child: RBox(color: () => kBlue),
            ),
          ),
      ],
    );
  });
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: SizedBox(
        width: const .fixed(800),
        height: .fixed(kNodeCount.toDouble()),
        child: NodeHost(node: root),
      ),
    ),
  );

  var frame = 0;
  _effectRuns = 0;
  final List<double> values = await timeIterations(
    warmup: kMoveAllWarmup,
    iterations: kMoveAllTimed,
    body: () async {
      frame += 1;
      batch<void>(() {
        for (var i = 0; i < kNodeCount; i++) {
          offsets[i].value = Offset(((i + frame) % 797).toDouble(), 0);
        }
      });
      await benchPump(tester);
    },
  );
  expect(_effectRuns, kNodeCount * (kMoveAllWarmup + kMoveAllTimed));
  expect(_componentRuns, 1);

  await benchPumpWidget(tester, const SizedBox.shrink());
  root.dispose();
  return median(values);
}

// ---------------------------------------------------------------------------
// 50,000 particles.
// ---------------------------------------------------------------------------

class _ReactiveParticlePainter extends CustomPainter {
  _ReactiveParticlePainter(this.points);

  final Signal<Float32List> points;
  int paints = 0;

  static final Paint _paint = Paint()
    ..color = const Color(0xFF2196F3)
    ..strokeWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    canvas.drawRawPoints(ui.PointMode.points, points.value, _paint);
  }

  @override
  // Not `false`: a new painter in a later round has to repaint once so its
  // signal reads are tracked. The timed loop never swaps painters.
  bool shouldRepaint(_ReactiveParticlePainter oldDelegate) => !identical(oldDelegate, this);
}

List<Float32List> _particleBuffers() {
  final buffers = <Float32List>[Float32List(kParticleCount * 2), Float32List(kParticleCount * 2)];
  for (var b = 0; b < 2; b += 1) {
    for (var i = 0; i < kParticleCount * 2; i += 1) {
      buffers[b][i] = ((i * 7 + b) % 800).toDouble();
    }
  }
  return buffers;
}

Future<double> _sceneHeadlessParticles(WidgetTester tester) async {
  return _headless(() async {
    // Two pre-filled buffers, swapped each frame, so the timed work is the
    // scene's -- one re-record of 50,000 points and one compose -- and not the
    // simulation's.
    final List<Float32List> buffers = _particleBuffers();
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
    _composeHeadlessFrame(scene);
    expect(field.debugRecordCount, 1);

    var frame = 0;
    final List<double> values = await timeIterations(
      warmup: kParticleWarmup,
      iterations: kParticleTimed,
      body: () async {
        frame += 1;
        points.value = buffers[frame & 1];
        _composeHeadlessFrame(scene);
      },
    );
    // Liveness: one re-record per frame, and no more.
    expect(field.debugRecordCount, kParticleWarmup + kParticleTimed + 1);
    scene.dispose();
    return median(values);
  });
}

Future<double> _leafParticles(WidgetTester tester) async {
  final List<Float32List> buffers = _particleBuffers();
  final points = Signal<Float32List>(buffers[0]);
  final painter = _ReactiveParticlePainter(points);
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: _BuildProbe(
        child: SizedBox.expand(child: ReactiveCustomPaint(painter: painter)),
      ),
    ),
  );

  var frame = 0;
  _probeBuilds = 0;
  painter.paints = 0;
  final List<double> values = await timeIterations(
    warmup: kParticleWarmup,
    iterations: kParticleTimed,
    body: () async {
      frame += 1;
      points.value = buffers[frame & 1];
      await benchPump(tester);
    },
  );
  expect(painter.paints, kParticleWarmup + kParticleTimed);
  expect(_probeBuilds, 0);
  await benchPumpWidget(tester, const SizedBox.shrink());
  return median(values);
}

// ---------------------------------------------------------------------------
// Mount and dispose 10,000.
// ---------------------------------------------------------------------------

Future<double> _sceneHeadlessLifecycle(WidgetTester tester) async {
  return _headless(() async {
    // The signals live outside the timed body so this variant times the same
    // unit of work as the leaf and collapsed variants.
    final List<Signal<double>> positions = _allocPositions();
    List<RectNode>? last;
    final List<double> values = await timeIterations(
      warmup: kLifecycleWarmup,
      iterations: kLifecycleTimed,
      body: () async {
        final _Built built = _buildSceneFrom(positions);
        _composeHeadlessFrame(built.scene);
        built.scene.dispose();
        last = built.nodes;
      },
    );
    // Liveness, checked outside the timed body: the loop really did mount and
    // dispose ten thousand nodes.
    expect(last, hasLength(kNodeCount));
    expect(last!.first.debugDisposed, isTrue);
    return median(values);
  });
}

Future<double> _leafLifecycle(WidgetTester tester) async {
  final signals = List<Signal<Offset>>.generate(kNodeCount, (int i) => Signal<Offset>(Offset.zero));
  late StateSetter setState;
  var mounted = false;
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setter) {
          setState = setter;
          return mounted
              ? mountAllInRows([
                  for (final s in signals)
                    ReactiveOffset(
                      offset: s,
                      child: const ColoredBox(color: .fixed(Color(0xFF2196F3))),
                    ),
                ])
              : const SizedBox.shrink();
        },
      ),
    ),
  );

  final times = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < kLifecycleWarmup + kLifecycleTimed; i++) {
    watch
      ..reset()
      ..start();
    mounted = true;
    setState(() {});
    await benchPump(tester);
    mounted = false;
    setState(() {});
    await benchPump(tester);
    watch.stop();
    if (i == 0) {
      // (Positioned findsNothing disabled: real-window surface differs from test surface)
      expect(signals.first.subs, isNull);
    }
    if (i >= kLifecycleWarmup) {
      times.add(watch.elapsedMicroseconds.toDouble());
    }
  }
  return median(times);
}

Future<double> _collapsedLifecycle(WidgetTester tester) async {
  final signals = List<Signal<Offset>>.generate(kNodeCount, (int i) => Signal<Offset>(Offset.zero));
  late StateSetter setState;
  RNode? root;
  await benchPumpWidget(
    tester,
    MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setter) {
          setState = setter;
          final node = root;
          return node == null
              ? const SizedBox.shrink()
              : SizedBox(
                  width: const .fixed(800),
                  height: .fixed(kNodeCount.toDouble()),
                  child: NodeHost(node: node),
                );
        },
      ),
    ),
  );

  final times = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < kLifecycleWarmup + kLifecycleTimed; i++) {
    watch
      ..reset()
      ..start();
    root = RStack(
      children: <RNode>[
        for (var n = 0; n < kNodeCount; n++)
          RPositioned(
            left: 0,
            top: n.toDouble(),
            width: 800,
            height: 1,
            child: ROffset(
              offset: signals[n].call,
              child: RBox(color: () => kBlue),
            ),
          ),
      ],
    );
    setState(() {});
    await benchPump(tester);
    final RNode mountedRoot = root;
    root = null;
    setState(() {});
    await benchPump(tester);
    mountedRoot.dispose();
    watch.stop();
    if (i == 0) {
      expect(find.byType(NodeHost), findsNothing);
      expect(signals.first.subs, isNull);
    }
    if (i >= kLifecycleWarmup) {
      times.add(watch.elapsedMicroseconds.toDouble());
    }
  }
  return median(times);
}

void main() {
  testWidgets('B9 move one of 10000', (WidgetTester tester) async {
    await runInterleaved(tester, 'b9_move_one', <BenchVariant>[
      const BenchVariant('scene_headless', _sceneHeadlessMoveOne),
      const BenchVariant('scene_embedded', _sceneEmbeddedMoveOne),
      const BenchVariant('phase3_leaf', _leafMoveOne),
      const BenchVariant('phase5_collapsed', _collapsedMoveOne),
    ]);
  });

  testWidgets('B9 move all 10000 in one batch', (WidgetTester tester) async {
    await runInterleaved(tester, 'b9_move_all', <BenchVariant>[
      const BenchVariant('scene_headless', _sceneHeadlessMoveAll),
      const BenchVariant('scene_embedded', _sceneEmbeddedMoveAll),
      const BenchVariant('phase3_leaf', _leafMoveAll),
      const BenchVariant('phase5_collapsed', _collapsedMoveAll),
    ]);
  });

  testWidgets('B9 50000 particles in one picture', (WidgetTester tester) async {
    await runInterleaved(tester, 'b9_particles', <BenchVariant>[
      const BenchVariant('scene_headless', _sceneHeadlessParticles),
      const BenchVariant('phase3_reactive_custom_paint', _leafParticles),
    ]);
  });

  testWidgets('B9 mount and dispose 10000', (WidgetTester tester) async {
    // Every row here is mount **and** compose **and** dispose, so the three
    // models are measured on the same unit of work: the classic rows time a
    // mount pump and an unmount pump together, and the scene row times build
    // plus one headless compose plus dispose.
    await runInterleaved(tester, 'b9_lifecycle', <BenchVariant>[
      const BenchVariant('scene_headless', _sceneHeadlessLifecycle),
      const BenchVariant('phase3_leaf', _leafLifecycle),
      const BenchVariant('phase5_collapsed', _collapsedLifecycle),
    ]);
  });
}
