// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// B10: signal-prop overhead on static values. See
// docs/fine_grained_reactivity/BENCHMARKS.md.
//
// Stock `Padding`, `Opacity`, `Transform.rotate` and `SizedBox`, whose
// properties are ReadonlySignals and receive `.fixed` values, against private
// copies of their plain-value versions from before that change. Both run in
// one process, interleaved by `runInterleaved`, so machine load and JIT or AOT
// state hit both sides equally. Values vary per card and per tick, so every
// card allocates its FixedSignals on mount and on rebuild.
//
// Render objects per card -- 5 in both variants:
//   Padding > Opacity > Transform > SizedBox > SizedBox
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reactivity_bench_common.dart';

const int kCards = 2000;
const int kWarmup = 3;
const int kTimed = 10;

class _PlainOpacity extends SingleChildRenderObjectWidget {
  const _PlainOpacity({required this.opacity, super.child});
  final double opacity;
  @override
  RenderOpacity createRenderObject(BuildContext context) => RenderOpacity(opacity: opacity);
  @override
  void updateRenderObject(BuildContext context, RenderOpacity renderObject) {
    renderObject
      ..opacity = opacity
      ..alwaysIncludeSemantics = false;
  }
}

class _PlainPadding extends SingleChildRenderObjectWidget {
  const _PlainPadding({required this.padding, super.child});
  final EdgeInsetsGeometry padding;
  @override
  RenderPadding createRenderObject(BuildContext context) =>
      RenderPadding(padding: padding, textDirection: Directionality.maybeOf(context));
  @override
  void updateRenderObject(BuildContext context, RenderPadding renderObject) {
    renderObject
      ..padding = padding
      ..textDirection = Directionality.maybeOf(context);
  }
}

class _PlainSizedBox extends SingleChildRenderObjectWidget {
  const _PlainSizedBox({this.width, this.height, super.child});
  final double? width;
  final double? height;
  BoxConstraints get _c => BoxConstraints.tightFor(width: width, height: height);
  @override
  RenderConstrainedBox createRenderObject(BuildContext context) =>
      RenderConstrainedBox(additionalConstraints: _c);
  @override
  void updateRenderObject(BuildContext context, RenderConstrainedBox renderObject) {
    renderObject.additionalConstraints = _c;
  }
}

Matrix4 _computeRotation(double radians) {
  assert(radians.isFinite, 'Cannot compute the rotation matrix for a non-finite angle: $radians');
  if (radians == 0.0) {
    return Matrix4.identity();
  }
  final double sin = math.sin(radians);
  if (sin == 1.0) {
    return _createZRotation(1.0, 0.0);
  }
  if (sin == -1.0) {
    return _createZRotation(-1.0, 0.0);
  }
  final double cos = math.cos(radians);
  if (cos == -1.0) {
    return _createZRotation(0.0, -1.0);
  }
  return _createZRotation(sin, cos);
}

Matrix4 _createZRotation(double sin, double cos) {
  final result = Matrix4.zero();
  result.storage[0] = cos;
  result.storage[1] = sin;
  result.storage[4] = -sin;
  result.storage[5] = cos;
  result.storage[10] = 1.0;
  result.storage[15] = 1.0;
  return result;
}

class _PlainTransform extends SingleChildRenderObjectWidget {
  _PlainTransform.rotate({required double angle, super.child})
    : transform = _computeRotation(angle);
  final Matrix4 transform;
  final Offset? origin = null;
  final AlignmentGeometry? alignment = Alignment.center;
  final bool transformHitTests = true;
  final FilterQuality? filterQuality = null;
  @override
  RenderTransform createRenderObject(BuildContext context) => RenderTransform(
    transform: transform,
    origin: origin,
    alignment: alignment,
    textDirection: Directionality.maybeOf(context),
    transformHitTests: transformHitTests,
    filterQuality: filterQuality,
  );
  @override
  void updateRenderObject(BuildContext context, RenderTransform renderObject) {
    renderObject
      ..transform = transform
      ..origin = origin
      ..alignment = alignment
      ..textDirection = Directionality.maybeOf(context)
      ..transformHitTests = transformHitTests
      ..filterQuality = filterQuality;
  }
}

// Five render-object widgets per card, values vary per item and per tick.
Widget _signalCard(int i, int t) => Padding(
  padding: .fixed(EdgeInsets.all(1.0 + (i + t) % 3)),
  child: Opacity(
    opacity: .fixed(0.5 + ((i + t) % 5) / 10),
    child: Transform.rotate(
      angle: .fixed(((i + t) % 3) / 100),
      child: SizedBox(
        width: .fixed(100.0 + (i + t) % 7),
        height: const .fixed(18),
        child: SizedBox(width: .fixed(10.0 + (i + t) % 5), height: const .fixed(8)),
      ),
    ),
  ),
);

Widget _plainCard(int i, int t) => _PlainPadding(
  padding: EdgeInsets.all(1.0 + (i + t) % 3),
  child: _PlainOpacity(
    opacity: 0.5 + ((i + t) % 5) / 10,
    child: _PlainTransform.rotate(
      angle: ((i + t) % 3) / 100,
      child: _PlainSizedBox(
        width: 100.0 + (i + t) % 7,
        height: 18,
        child: _PlainSizedBox(width: 10.0 + (i + t) % 5, height: 8),
      ),
    ),
  ),
);

/// Times mounting, rebuilding with changed values, and unmounting [kCards]
/// cards built by [card]. Returns the median of [phase] in microseconds.
Future<double> _measure(
  WidgetTester tester,
  Widget Function(int i, int tick) card,
  String phase,
) async {
  late StateSetter setState;
  var mounted = false;
  var tick = 0;
  await tester.pumpWidget(
    StatefulBuilder(
      builder: (BuildContext context, StateSetter setter) {
        setState = setter;
        return Directionality(
          textDirection: TextDirection.ltr,
          child: mounted
              ? mountAllInRows([for (var i = 0; i < kCards; i++) card(i, tick)], itemHeight: 22)
              : const SizedBox.shrink(),
        );
      },
    ),
  );

  final times = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < kWarmup + kTimed; i++) {
    final bool keep = i >= kWarmup;
    watch
      ..reset()
      ..start();
    mounted = true;
    setState(() {});
    await tester.pump();
    watch.stop();
    if (keep && phase == 'mount') {
      times.add(watch.elapsedMicroseconds.toDouble());
    }

    watch
      ..reset()
      ..start();
    tick += 1;
    setState(() {});
    await tester.pump();
    watch.stop();
    if (keep && phase == 'rebuild') {
      times.add(watch.elapsedMicroseconds.toDouble());
    }

    watch
      ..reset()
      ..start();
    mounted = false;
    setState(() {});
    await tester.pump();
    watch.stop();
    if (keep && phase == 'unmount') {
      times.add(watch.elapsedMicroseconds.toDouble());
    }
  }
  return median(times);
}

void main() {
  testWidgets('B10 signal props against plain props', (WidgetTester tester) async {
    await runInterleaved(tester, 'b10', <BenchVariant>[
      for (final String phase in <String>['mount', 'rebuild', 'unmount']) ...<BenchVariant>[
        BenchVariant('plain_$phase', (WidgetTester t) => _measure(t, _plainCard, phase)),
        BenchVariant('signal_$phase', (WidgetTester t) => _measure(t, _signalCard, phase)),
      ],
    ]);
  });
}
