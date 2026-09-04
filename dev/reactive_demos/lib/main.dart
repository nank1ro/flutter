import 'package:flutter/material.dart';

import 'deep_tree_screen.dart';
import 'particles_screen.dart';
import 'sprites_screen.dart';

void main() {
  runApp(const ReactiveDemosApp());
}

/// Demos of the signal-based reactive widgets added to this Flutter fork.
class ReactiveDemosApp extends StatelessWidget {
  const ReactiveDemosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reactive demos',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reactive demos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _DemoTile(
            title: '10,000 sprites',
            subtitle: 'One Signal<Offset> per sprite, moved by a FrameClock',
            builder: (context) => const SpritesScreen(),
          ),
          _DemoTile(
            title: '50,000 particles',
            subtitle: 'One Float32List, one ReactiveCustomPaint',
            builder: (context) => const ParticlesScreen(),
          ),
          _DemoTile(
            title: '120 Hz counter, 50 levels deep',
            subtitle: 'A ReactiveText leaf nested inside plain widgets',
            builder: (context) => const DeepTreeScreen(),
          ),
        ],
      ),
    );
  }
}

class _DemoTile extends StatelessWidget {
  const _DemoTile({required this.title, required this.subtitle, required this.builder});

  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: builder)),
      ),
    );
  }
}
