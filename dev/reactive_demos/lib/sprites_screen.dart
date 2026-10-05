import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'frame_stats_overlay.dart';

const int _spriteCount = 10000;
const Size _arenaSize = Size(900, 600);
const double _dotSize = 6;

/// One sprite: an id for [For]'s keying, a reactive position, and a plain
/// (non-reactive) velocity that only the simulation step touches.
class _Sprite {
  _Sprite(this.id, this.color, Offset start, this.velocity) : position = Signal<Offset>(start);

  final int id;
  final Color color;
  final Signal<Offset> position;
  Offset velocity;
}

/// 10,000 sprites, each moved by its own [Signal], each painted by its own
/// [ReactiveOffset]. A write to one sprite's position repaints exactly that
/// sprite's render object.
class SpritesScreen extends StatefulWidget {
  const SpritesScreen({super.key});

  @override
  State<SpritesScreen> createState() => _SpritesScreenState();
}

class _SpritesScreenState extends State<SpritesScreen> with SingleTickerProviderStateMixin {
  late final List<_Sprite> _sprites;
  late final FrameClock _clock;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    final rng = math.Random();
    _sprites = List<_Sprite>.generate(_spriteCount, (int i) {
      final start = Offset(
        rng.nextDouble() * _arenaSize.width,
        rng.nextDouble() * _arenaSize.height,
      );
      final velocity = Offset((rng.nextDouble() - 0.5) * 160, (rng.nextDouble() - 0.5) * 160);
      return _Sprite(i, Colors.primaries[i % Colors.primaries.length], start, velocity);
    });
    _clock = FrameClock.withVsync(vsync: this, simulate: _simulate);
    _clock.start();
  }

  void _simulate(double dt) {
    for (final _Sprite sprite in _sprites) {
      Offset next = sprite.position.peek + sprite.velocity * dt;
      double vx = sprite.velocity.dx;
      double vy = sprite.velocity.dy;
      if (next.dx < 0 || next.dx > _arenaSize.width) {
        vx = -vx;
        next = Offset(next.dx.clamp(0, _arenaSize.width), next.dy);
      }
      if (next.dy < 0 || next.dy > _arenaSize.height) {
        vy = -vy;
        next = Offset(next.dx, next.dy.clamp(0, _arenaSize.height));
      }
      sprite.velocity = Offset(vx, vy);
      sprite.position.value = next;
    }
  }

  void _togglePaused() {
    setState(() {
      _paused = !_paused;
      _clock.paused = _paused;
    });
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  Widget _buildSprite(_Sprite sprite) {
    return ReactiveOffset(
      offset: sprite.position,
      child: DecoratedBox(
        decoration: BoxDecoration(color: sprite.color, shape: BoxShape.circle),
        child: const SizedBox(width: _dotSize, height: _dotSize),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('10,000 sprites')),
      body: Stack(
        children: [
          Center(
            child: SizedBox(
              width: _arenaSize.width,
              height: _arenaSize.height,
              child: ColoredBox(
                color: Colors.black12,
                child: For<_Sprite>(
                  each: () => _sprites,
                  keyOf: (_Sprite sprite) => sprite.id,
                  builder: _buildSprite,
                ),
              ),
            ),
          ),
          FrameStatsOverlay(clock: _clock),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _togglePaused,
        child: Icon(_paused ? Icons.play_arrow : Icons.pause),
      ),
    );
  }
}
