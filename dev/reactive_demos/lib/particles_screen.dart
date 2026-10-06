import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'frame_stats_overlay.dart';

const int _particleCount = 50000;
const Size _fieldSize = Size(900, 600);

/// 50,000 particles packed into one `Float32List` (x, y interleaved).
///
/// Mutating the buffer in place is invisible to signals, so [generation] is
/// bumped after every step; the painter reads it to know when to repaint.
class _ParticleField {
  _ParticleField(int count, Size bounds)
    : points = Float32List(count * 2),
      _velocities = Float32List(count * 2) {
    final rng = math.Random();
    for (var i = 0; i < count; i++) {
      points[i * 2] = rng.nextDouble() * bounds.width;
      points[i * 2 + 1] = rng.nextDouble() * bounds.height;
      _velocities[i * 2] = (rng.nextDouble() - 0.5) * 120;
      _velocities[i * 2 + 1] = (rng.nextDouble() - 0.5) * 120;
    }
  }

  final Float32List points;
  final Float32List _velocities;

  /// Bumped after every mutation of [points], so a [ReactiveCustomPaint]
  /// painter reading it is repainted without any signal ever touching the
  /// buffer's contents directly.
  final Signal<int> generation = Signal<int>(0);

  void step(double dt, Size bounds) {
    for (var i = 0; i < points.length; i += 2) {
      double x = points[i] + _velocities[i] * dt;
      double y = points[i + 1] + _velocities[i + 1] * dt;
      if (x < 0 || x > bounds.width) {
        _velocities[i] = -_velocities[i];
        x = x.clamp(0, bounds.width);
      }
      if (y < 0 || y > bounds.height) {
        _velocities[i + 1] = -_velocities[i + 1];
        y = y.clamp(0, bounds.height);
      }
      points[i] = x;
      points[i + 1] = y;
    }
    generation.value = generation.peek + 1;
  }
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter({required this.points, required this.generation});

  final Float32List points;
  final Signal<int> generation;
  final Paint _paint = Paint()
    ..color = Colors.cyanAccent
    ..strokeWidth = 2
    ..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas canvas, Size size) {
    // Subscribes this paint to the generation signal: a bump repaints only
    // this render object, never the widget tree above it.
    generation.value;
    canvas.drawRawPoints(ui.PointMode.points, points, _paint);
  }

  // Repaints are driven by the generation signal read above, not by widget
  // rebuilds, so there is nothing new to compare here.
  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => false;
}

/// A single [ReactiveCustomPaint] drawing 50,000 particles from a shared
/// buffer, repainted once per simulation step via a generation counter.
class ParticlesScreen extends StatefulWidget {
  const ParticlesScreen({super.key});

  @override
  State<ParticlesScreen> createState() => _ParticlesScreenState();
}

class _ParticlesScreenState extends State<ParticlesScreen> with SingleTickerProviderStateMixin {
  late final _ParticleField _field;
  late final FrameClock _clock;

  @override
  void initState() {
    super.initState();
    _field = _ParticleField(_particleCount, _fieldSize);
    _clock = FrameClock.withVsync(
      vsync: this,
      simulate: (double dt) => _field.step(dt, _fieldSize),
    );
    _clock.start();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('50,000 particles')),
      body: Stack(
        children: [
          Center(
            child: SizedBox(
              width: .fixed(_fieldSize.width),
              height: .fixed(_fieldSize.height),
              child: ColoredBox(
                color: const .fixed(Colors.black),
                child: ReactiveCustomPaint(
                  size: _fieldSize,
                  painter: _ParticlePainter(points: _field.points, generation: _field.generation),
                ),
              ),
            ),
          ),
          FrameStatsOverlay(clock: _clock),
        ],
      ),
    );
  }
}
