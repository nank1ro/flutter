// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Leaf-level reactivity: a signal write reaches a RenderObject setter through
// an effect, and nothing in the widget or element tree runs at all. These
// tests assert both halves of that — the property really did change, and the
// build counters really are zero.

import 'package:flutter/rendering.dart';
// `Link` is intentionally not exported from `foundation.dart`; the graph
// internals these tests inspect come from the source file directly.
import 'package:flutter/src/foundation/signals.dart' show Link, ReactiveNode;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts builds of everything in a chain of ancestors above the widget under
/// test, so a test can assert that a signal write rebuilt nothing at all.
class _BuildCounter extends StatelessWidget {
  const _BuildCounter({required this.depth, required this.counts, required this.child});

  final int depth;
  final List<int> counts;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    counts[depth] += 1;
    if (depth == 0) {
      return child;
    }
    return _BuildCounter(depth: depth - 1, counts: counts, child: child);
  }
}

/// Counts the layout and paint passes that reach it, so a test can tell a
/// paint-only invalidation from one that relayouts.
class _PipelineSpy extends SingleChildRenderObjectWidget {
  const _PipelineSpy({required this.stats, super.child});

  final _PipelineStats stats;

  @override
  _RenderPipelineSpy createRenderObject(BuildContext context) => _RenderPipelineSpy(stats);

  @override
  void updateRenderObject(BuildContext context, _RenderPipelineSpy renderObject) {
    renderObject.stats = stats;
  }
}

class _PipelineStats {
  int layouts = 0;
  int paints = 0;

  void reset() {
    layouts = 0;
    paints = 0;
  }
}

class _RenderPipelineSpy extends RenderProxyBox {
  _RenderPipelineSpy(this.stats);

  _PipelineStats stats;

  @override
  void performLayout() {
    stats.layouts += 1;
    super.performLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    stats.paints += 1;
    super.paint(context, offset);
  }
}

/// A painter that reads [generation] while painting, and counts its paints.
class _TrackingPainter extends CustomPainter {
  _TrackingPainter(this.generation, this.paints);

  final Signal<int> generation;
  final List<int> paints;

  @override
  void paint(Canvas canvas, Size size) {
    paints.add(generation.value);
  }

  @override
  bool shouldRepaint(_TrackingPainter oldDelegate) => false;
}

/// A painter that records that it painted, so a test can assert paint order.
class _LogPainter extends CustomPainter {
  _LogPainter(this.label, this.log);

  final String label;
  final List<String> log;

  @override
  void paint(Canvas canvas, Size size) {
    log.add(label);
  }

  @override
  bool shouldRepaint(_LogPainter oldDelegate) => false;
}

/// A painter that does nothing, for tests that only care about the
/// save/restore bookkeeping around [CustomPainter.paint].
class _NoopPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_NoopPainter oldDelegate) => true;
}

class _MockCanvas extends Fake implements Canvas {
  int saveCount = 0;
  int saveCountDelta = 1;

  @override
  int getSaveCount() {
    return saveCount += saveCountDelta;
  }

  @override
  void save() {}

  @override
  void restore() {}
}

class _MockPaintingContext extends Fake implements PaintingContext {
  @override
  final _MockCanvas canvas = _MockCanvas();
}

/// Reads a signal while painting, with no tracking of its own — the read an
/// enclosing tracking scope would otherwise swallow.
class _PaintProbe extends LeafRenderObjectWidget {
  const _PaintProbe(this.signal);

  final Signal<int> signal;

  @override
  _RenderPaintProbe createRenderObject(BuildContext context) => _RenderPaintProbe(signal);

  @override
  void updateRenderObject(BuildContext context, _RenderPaintProbe renderObject) {
    renderObject.signal = signal;
  }
}

class _RenderPaintProbe extends RenderBox {
  _RenderPaintProbe(this.signal);

  Signal<int> signal;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.smallest;

  @override
  void paint(PaintingContext context, Offset offset) {
    signal.value;
  }
}

/// A reactive property that counts how many times a binding read it.
///
/// Two tear-offs of the same instance's `call` are equal but not identical,
/// exactly like a [Signal] passed straight to a property, so a rebind with the
/// same object must not re-run the binding.
/// A [ReadonlySignal] that counts every read, tracked or not.
class _CountingProp<T> implements ReadonlySignal<T> {
  _CountingProp(this.signal);

  final Signal<T> signal;
  int reads = 0;

  @override
  T get value {
    reads += 1;
    return signal.value;
  }

  @override
  T get peek => untracked(() => value);

  @override
  T call() => value;
}

/// A [ReadonlySignal] read through a closure, so that a test can count reads,
/// or hand a widget a fresh accessor on every build.
final class _Read<T> implements ReadonlySignal<T> {
  _Read(this._read);

  final T Function() _read;

  @override
  T get value => _read();

  @override
  T get peek => untracked(_read);

  @override
  T call() => _read();
}

/// Rebuilds a [Directionality] around the *same* child widget instance, so
/// that the reactive element below is rebuilt through `performRebuild` — the
/// inherited-dependency path — rather than through `update`.
class _DirectionalityHost extends StatefulWidget {
  const _DirectionalityHost({required this.child});

  final Widget child;

  @override
  State<_DirectionalityHost> createState() => _DirectionalityHostState();
}

class _DirectionalityHostState extends State<_DirectionalityHost> {
  TextDirection _direction = TextDirection.ltr;

  void flip() {
    setState(() {
      _direction = _direction == TextDirection.ltr ? TextDirection.rtl : TextDirection.ltr;
    });
  }

  @override
  Widget build(BuildContext context) =>
      Directionality(textDirection: _direction, child: widget.child);
}

/// Writes the signals its children are bound to from [State.didUpdateWidget],
/// where writes are queued rather than run, and rebuilds both children with
/// fresh prop closures, so their bindings are rebound while their effects are
/// still in the queue. The trailing [Builder] writes once more, after the
/// rebinding, which is the write that corrupts the queue if a rebind re-armed
/// a queued effect.
class _QueuedRebind extends StatefulWidget {
  const _QueuedRebind({required this.a, required this.b});

  final Signal<double> a;
  final Signal<double> b;

  @override
  State<_QueuedRebind> createState() => _QueuedRebindState();
}

class _QueuedRebindState extends State<_QueuedRebind> {
  /// A property that is the same object on every build, so the second binding
  /// is never rebound and stays in the queue as it was left.
  late final _Read<double> _stableProp = _Read<double>(_readB);

  double _readB() => widget.b.value;

  @override
  void didUpdateWidget(_QueuedRebind oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.a.value = 0.4;
    widget.b.value = 0.75;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        // A fresh accessor on every build, so this binding is rebound.
        Opacity(
          opacity: _Read<double>(() => widget.a.value),
          child: const SizedBox(width: .fixed(10), height: .fixed(10)),
        ),
        Opacity(
          opacity: _stableProp,
          child: const SizedBox(width: .fixed(10), height: .fixed(10)),
        ),
        Builder(
          builder: (BuildContext context) {
            widget.a.value = 0.5;
            return const SizedBox();
          },
        ),
      ],
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({super.key, required this.label, required this.builds});

  final String label;
  final List<String> builds;

  @override
  Widget build(BuildContext context) {
    builds.add(label);
    return SizedBox(
      key: ValueKey<String>('box-$label'),
      width: const .fixed(10),
      height: const .fixed(10),
    );
  }
}

void main() {
  group('reactive props', () {
    testWidgets('a signal write updates RenderOpacity.opacity with no rebuild anywhere', (
      WidgetTester tester,
    ) async {
      final opacity = Signal<double>(1);
      final counts = List<int>.filled(6, 0);
      final stats = _PipelineStats();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: _BuildCounter(
            depth: 5,
            counts: counts,
            child: _PipelineSpy(
              stats: stats,
              child: Opacity(
                opacity: opacity,
                child: const SizedBox(width: .fixed(10), height: .fixed(10)),
              ),
            ),
          ),
        ),
      );

      final RenderOpacity renderObject = tester.renderObject<RenderOpacity>(find.byType(Opacity));
      expect(renderObject.opacity, 1.0);
      expect(counts, everyElement(1));

      counts.fillRange(0, counts.length, 0);
      stats.reset();
      opacity.value = 0.25;
      await tester.pump();

      expect(renderObject.opacity, 0.25);
      // Nothing rebuilt: not the leaf's own element, not any of its ancestors.
      expect(counts, everyElement(0));
      // RenderOpacity is a repaint boundary and its setter ends in
      // markNeedsCompositedLayerUpdate, the cheapest invalidation there is:
      // the frame neither relayouts nor repaints anything, it just hands the
      // compositor a new alpha.
      expect(stats.layouts, 0);
      expect(stats.paints, 0);
    });

    testWidgets('writing an equal value does nothing', (WidgetTester tester) async {
      final color = Signal<Color>(const Color(0xFF00FF00));
      final applied = <Color>[];

      await tester.pumpWidget(
        ColoredBox(
          color: _Read<Color>(() {
            applied.add(color.value);
            return color.value;
          }),
          child: const SizedBox(width: .fixed(10), height: .fixed(10)),
        ),
      );
      // Two reads at mount: createRenderObject seeds the render object with
      // the current value, then the binding's effect runs for the first time.
      expect(applied, hasLength(2));

      // A different Color object with the same value is not a change: Signal
      // compares with ==.
      color.value = const Color(0xFF00FF00);
      await tester.pump();
      expect(applied, hasLength(2));

      color.value = const Color(0xFFFF0000);
      await tester.pump();
      expect(applied, hasLength(3));
      expect(
        tester.renderObject<RenderObject>(find.byType(ColoredBox)),
        paints..rect(color: const Color(0xFFFF0000)),
      );
    });

    testWidgets('ReactiveOffset moves a sprite with paint only, no relayout', (
      WidgetTester tester,
    ) async {
      final position = Signal<Offset>(Offset.zero);
      final stats = _PipelineStats();

      await tester.pumpWidget(
        _PipelineSpy(
          stats: stats,
          child: ReactiveOffset(
            offset: position,
            child: const SizedBox(width: .fixed(10), height: .fixed(10)),
          ),
        ),
      );
      final RenderReactiveOffset renderObject = tester.renderObject<RenderReactiveOffset>(
        find.byType(ReactiveOffset),
      );
      expect(renderObject.offset, Offset.zero);

      stats.reset();
      position.value = const Offset(12, 34);
      await tester.pump();

      expect(renderObject.offset, const Offset(12, 34));
      expect(stats.layouts, 0);
      expect(stats.paints, 1);
    });

    testWidgets('Padding relayouts but does not rebuild', (WidgetTester tester) async {
      final padding = Signal<EdgeInsetsGeometry>(EdgeInsets.zero);
      final counts = List<int>.filled(3, 0);
      final stats = _PipelineStats();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: _BuildCounter(
            depth: 2,
            counts: counts,
            child: Padding(
              padding: padding,
              child: _PipelineSpy(
                stats: stats,
                child: const SizedBox(width: .fixed(10), height: .fixed(10)),
              ),
            ),
          ),
        ),
      );
      final RenderPadding renderObject = tester.renderObject<RenderPadding>(find.byType(Padding));

      counts.fillRange(0, counts.length, 0);
      stats.reset();
      padding.value = const EdgeInsets.all(8);
      await tester.pump();

      expect(renderObject.padding, const EdgeInsets.all(8));
      expect(counts, everyElement(0));
      // Padding is a layout property, so the subtree relayouts. It still
      // rebuilds nothing.
      expect(stats.layouts, 1);
    });

    testWidgets('ReactiveText updates RenderParagraph.text with no rebuild', (
      WidgetTester tester,
    ) async {
      final label = Signal<String>('hello');
      final style = Signal<TextStyle>(const TextStyle(fontSize: 10));
      final counts = List<int>.filled(4, 0);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: _BuildCounter(
            depth: 3,
            counts: counts,
            child: ReactiveText(label, style: style),
          ),
        ),
      );
      final RenderParagraph renderObject = tester.renderObject<RenderParagraph>(
        find.byType(ReactiveText),
      );
      expect(renderObject.text.toPlainText(), 'hello');

      counts.fillRange(0, counts.length, 0);
      label.value = 'goodbye';
      await tester.pump();
      expect(renderObject.text.toPlainText(), 'goodbye');
      expect(counts, everyElement(0));

      style.value = const TextStyle(fontSize: 20);
      await tester.pump();
      expect(renderObject.text.style!.fontSize, 20);
      expect(counts, everyElement(0));
    });

    testWidgets('a new widget rebinds a prop that is a different closure', (
      WidgetTester tester,
    ) async {
      final a = Signal<double>(0.5);
      final b = Signal<double>(0.25);

      Widget build(Signal<double> source) => Opacity(
        opacity: source,
        child: const SizedBox(width: .fixed(10), height: .fixed(10)),
      );

      await tester.pumpWidget(build(a));
      final RenderOpacity renderObject = tester.renderObject<RenderOpacity>(find.byType(Opacity));
      expect(renderObject.opacity, 0.5);

      await tester.pumpWidget(build(b));
      expect(renderObject.opacity, 0.25);

      // The binding followed the new signal, and let go of the old one.
      a.value = 1;
      await tester.pump();
      expect(renderObject.opacity, 0.25);

      b.value = 0.75;
      await tester.pump();
      expect(renderObject.opacity, 0.75);
    });

    testWidgets('unmounting disposes the bindings', (WidgetTester tester) async {
      final opacity = Signal<double>(1);

      await tester.pumpWidget(
        Opacity(
          opacity: opacity,
          child: const SizedBox(width: .fixed(10), height: .fixed(10)),
        ),
      );
      expect(opacity.subs, isNotNull);

      await tester.pumpWidget(const SizedBox());
      expect(opacity.subs, isNull);

      // The dangling write must not reach a disposed render object.
      opacity.value = 0;
      await tester.pump();
    });

    testWidgets('ReactiveCustomPaint repaints on a signal read during paint', (
      WidgetTester tester,
    ) async {
      final generation = Signal<int>(0);
      final paints = <int>[];
      final counts = List<int>.filled(3, 0);

      await tester.pumpWidget(
        _BuildCounter(
          depth: 2,
          counts: counts,
          child: ReactiveCustomPaint(
            painter: _TrackingPainter(generation, paints),
            size: const Size(100, 100),
          ),
        ),
      );
      expect(paints, <int>[0]);

      counts.fillRange(0, counts.length, 0);
      generation.value = 1;
      await tester.pump();
      expect(paints, <int>[0, 1]);
      expect(counts, everyElement(0));

      generation.value = 2;
      await tester.pump();
      expect(paints, <int>[0, 1, 2]);
    });

    testWidgets('a batch of writes produces one flush', (WidgetTester tester) async {
      final x = Signal<double>(0);
      final y = Signal<double>(0);
      final applied = <Offset>[];

      await tester.pumpWidget(
        ReactiveOffset(
          offset: () {
            final offset = Offset(x.value, y.value);
            applied.add(offset);
            return offset;
          },
          child: const SizedBox(width: .fixed(10), height: .fixed(10)),
        ),
      );
      // Once to seed createRenderObject, once for the effect's first run.
      expect(applied, <Offset>[Offset.zero, Offset.zero]);

      batch<void>(() {
        x.value = 1;
        y.value = 2;
      });
      await tester.pump();
      // Two writes, one effect run.
      expect(applied, <Offset>[Offset.zero, Offset.zero, const Offset(1, 2)]);
    });

    testWidgets('a parent rebuild with the same prop does not re-run the binding', (
      WidgetTester tester,
    ) async {
      final opacity = Signal<double>(1);
      final prop = _CountingProp<double>(opacity);

      Widget build() => Opacity(
        opacity: prop,
        child: const SizedBox(width: .fixed(10), height: .fixed(10)),
      );

      await tester.pumpWidget(build());
      // Once to seed createRenderObject, once for the effect's first run.
      expect(prop.reads, 2);

      // A new widget, but the same property: the two tear-offs are equal, so
      // the binding is left alone.
      await tester.pumpWidget(build());
      expect(prop.reads, 2);

      opacity.value = 0.5;
      await tester.pump();
      expect(prop.reads, 3);
      expect(tester.renderObject<RenderOpacity>(find.byType(Opacity)).opacity, 0.5);
    });

    testWidgets('a re-run that writes an equal value does not repaint', (
      WidgetTester tester,
    ) async {
      final tick = Signal<int>(0);
      final stats = _PipelineStats();
      var reads = 0;

      await tester.pumpWidget(
        ColoredBox(
          color: _Read<Color>(() {
            tick.value;
            reads += 1;
            return const Color(0xFF00FF00);
          }),
          child: _PipelineSpy(
            stats: stats,
            child: const SizedBox(width: .fixed(10), height: .fixed(10)),
          ),
        ),
      );
      expect(reads, 2);

      stats.reset();
      tick.value = 1;
      await tester.pump();

      // The effect re-ran and wrote the same colour. The setter compared it
      // and did nothing, so nothing laid out and nothing painted.
      expect(reads, 3);
      expect(stats.layouts, 0);
      expect(stats.paints, 0);
    });

    testWidgets('rebinding while an effect is queued leaves the other bindings live', (
      WidgetTester tester,
    ) async {
      final a = Signal<double>(1);
      final b = Signal<double>(1);

      await tester.pumpWidget(_QueuedRebind(a: a, b: b));
      final List<RenderOpacity> boxes = tester
          .renderObjectList<RenderOpacity>(find.byType(Opacity))
          .toList();
      expect(boxes, hasLength(2));

      await tester.pumpWidget(_QueuedRebind(a: a, b: b));
      // Writes made during a build are flushed at the start of the next frame.
      await tester.pump();
      expect(boxes[0].opacity, 0.5);
      expect(boxes[1].opacity, 0.75);

      // Both bindings are still watching their signals.
      a.value = 0.25;
      b.value = 0.25;
      await tester.pump();
      expect(boxes[0].opacity, 0.25);
      expect(boxes[1].opacity, 0.25);
    });

    testWidgets('an inherited change rebuilds through performRebuild without rebinding', (
      WidgetTester tester,
    ) async {
      final padding = Signal<EdgeInsetsGeometry>(const EdgeInsetsDirectional.only(start: 8));
      final prop = _CountingProp<EdgeInsetsGeometry>(padding);

      await tester.pumpWidget(
        _DirectionalityHost(
          child: Padding(
            padding: prop,
            child: const SizedBox(width: .fixed(10), height: .fixed(10)),
          ),
        ),
      );
      final RenderPadding renderObject = tester.renderObject<RenderPadding>(find.byType(Padding));
      expect(renderObject.textDirection, TextDirection.ltr);
      expect(prop.reads, 2);

      // The same Padding widget instance, under a Directionality that
      // changed: the element is dirtied by its inherited dependency and
      // rebuilt through performRebuild rather than update.
      tester.state<_DirectionalityHostState>(find.byType(_DirectionalityHost)).flip();
      await tester.pump();

      expect(renderObject.textDirection, TextDirection.rtl);
      // Rebinding happened, but the property is unchanged, so no effect ran.
      expect(prop.reads, 2);

      padding.value = const EdgeInsetsDirectional.only(start: 16);
      await tester.pump();
      expect(prop.reads, 3);
      expect(renderObject.padding, const EdgeInsetsDirectional.only(start: 16));
    });

    testWidgets('a GlobalKey reparent keeps the binding live', (WidgetTester tester) async {
      final opacity = Signal<double>(1);
      final Widget target = Opacity(
        key: GlobalKey(),
        opacity: opacity,
        child: const SizedBox(width: .fixed(10), height: .fixed(10)),
      );

      await tester.pumpWidget(
        Column(
          children: <Widget>[
            Padding(padding: const .fixed(EdgeInsets.zero), child: target),
            const SizedBox(width: .fixed(10), height: .fixed(10)),
          ],
        ),
      );
      final RenderOpacity renderObject = tester.renderObject<RenderOpacity>(find.byType(Opacity));

      // The same widget under a different parent: the element is deactivated
      // and reactivated in one frame, and its bindings must survive the move.
      await tester.pumpWidget(
        Column(
          children: <Widget>[
            const SizedBox(width: .fixed(10), height: .fixed(10)),
            Padding(padding: const .fixed(EdgeInsets.zero), child: target),
          ],
        ),
      );
      expect(tester.renderObject<RenderOpacity>(find.byType(Opacity)), same(renderObject));

      opacity.value = 0.25;
      await tester.pump();
      expect(renderObject.opacity, 0.25);
    });

    testWidgets('ReactiveText merges the ambient DefaultTextStyle', (WidgetTester tester) async {
      final label = Signal<String>('hello');
      final style = Signal<TextStyle>(const TextStyle(fontSize: 20));

      Widget build(Color color) => Directionality(
        textDirection: TextDirection.ltr,
        child: DefaultTextStyle(
          style: TextStyle(color: color, fontSize: 10, fontFamily: 'ambient'),
          child: ReactiveText(label, style: style),
        ),
      );

      await tester.pumpWidget(build(const Color(0xFF0000FF)));
      final RenderParagraph renderObject = tester.renderObject<RenderParagraph>(
        find.byType(ReactiveText),
      );
      TextStyle spanStyle() => renderObject.text.style!;

      // The widget's own style wins where the two overlap; the rest of the
      // ambient style comes through.
      expect(spanStyle().fontSize, 20);
      expect(spanStyle().fontFamily, 'ambient');
      expect(spanStyle().color, const Color(0xFF0000FF));

      // A change to the ambient style reaches the span.
      await tester.pumpWidget(build(const Color(0xFF00FF00)));
      expect(spanStyle().color, const Color(0xFF00FF00));

      // And the signals still drive it.
      label.value = 'goodbye';
      await tester.pump();
      expect(renderObject.text.toPlainText(), 'goodbye');
      expect(spanStyle().color, const Color(0xFF00FF00));
      expect(spanStyle().fontSize, 20);
    });

    testWidgets('ReactiveCustomPaint tracks its painters, not its child subtree', (
      WidgetTester tester,
    ) async {
      final outer = Signal<int>(0);
      final probe = Signal<int>(0);
      final outerPaints = <int>[];

      await tester.pumpWidget(
        ReactiveCustomPaint(
          painter: _TrackingPainter(outer, outerPaints),
          size: const Size(100, 100),
          child: _PaintProbe(probe),
        ),
      );
      expect(outerPaints, <int>[0]);

      // The child's paint read nothing was tracking. That is reported as the
      // mistake it is, rather than silently becoming a dependency of this
      // render object's painters, where it would repaint the wrong thing and
      // stop working the moment the child moved.
      expect(tester.takeException(), isFlutterError);
      expect(probe.subs, isNull);
      expect(_countSubs(outer), 1);
    });

    testWidgets('ReactiveCustomPaint paints the background, the child and the foreground', (
      WidgetTester tester,
    ) async {
      final log = <String>[];
      final stats = _PipelineStats();

      await tester.pumpWidget(
        ReactiveCustomPaint(
          painter: _LogPainter('background', log),
          foregroundPainter: _LogPainter('foreground', log),
          child: _PipelineSpy(
            stats: stats,
            child: const SizedBox(width: .fixed(10), height: .fixed(10)),
          ),
        ),
      );

      expect(log, <String>['background', 'foreground']);
      expect(stats.paints, 1);
    });

    testWidgets('Throws FlutterError on ReactiveCustomPaint incorrect restore/save calls', (
      WidgetTester tester,
    ) async {
      final GlobalKey target = GlobalKey();
      await tester.pumpWidget(
        ReactiveCustomPaint(key: target, isComplex: true, painter: _NoopPainter()),
      );
      final renderCustom = target.currentContext!.findRenderObject()! as RenderReactiveCustomPaint;
      final paintingContext = _MockPaintingContext();
      final _MockCanvas canvas = paintingContext.canvas;

      FlutterError getError() {
        late FlutterError error;
        try {
          renderCustom.paint(paintingContext, Offset.zero);
        } on FlutterError catch (e) {
          error = e;
        }
        return error;
      }

      FlutterError error = getError();
      expect(
        error.toStringDeep(),
        equalsIgnoringHashCodes(
          'FlutterError\n'
          '   The _NoopPainter#00000() custom painter called canvas.save() or\n'
          '   canvas.saveLayer() at least 1 more time than it called\n'
          '   canvas.restore().\n'
          '   This leaves the canvas in an inconsistent state and will probably\n'
          '   result in a broken display.\n'
          '   You must pair each call to save()/saveLayer() with a later\n'
          '   matching call to restore().\n',
        ),
      );

      canvas.saveCountDelta = -1;
      error = getError();
      expect(
        error.toStringDeep(),
        equalsIgnoringHashCodes(
          'FlutterError\n'
          '   The _NoopPainter#00000() custom painter called canvas.restore() 1\n'
          '   more time than it called canvas.save() or canvas.saveLayer().\n'
          '   This leaves the canvas in an inconsistent state and will result\n'
          '   in a broken display.\n'
          '   You should only call restore() if you first called save() or\n'
          '   saveLayer().\n',
        ),
      );

      canvas.saveCountDelta = 2;
      error = getError();
      expect(error.toStringDeep(), matches(RegExp(r'2\s+more times')));

      canvas.saveCountDelta = -2;
      error = getError();
      expect(error.toStringDeep(), matches(RegExp(r'2\s+more times')));
    });
  });

  group('Show', () {
    testWidgets('mounts and unmounts a subtree without rebuilding the parent', (
      WidgetTester tester,
    ) async {
      final visible = Signal<bool>(false);
      final counts = List<int>.filled(3, 0);
      final builds = <String>[];

      await tester.pumpWidget(
        _BuildCounter(
          depth: 2,
          counts: counts,
          child: Show(
            when: visible,
            child: () => _Item(label: 'shown', builds: builds),
            fallback: () => _Item(label: 'hidden', builds: builds),
          ),
        ),
      );
      expect(builds, <String>['hidden']);
      expect(find.byKey(const ValueKey<String>('box-shown')), findsNothing);

      counts.fillRange(0, counts.length, 0);
      builds.clear();
      visible.value = true;
      await tester.pump();

      expect(builds, <String>['shown']);
      expect(find.byKey(const ValueKey<String>('box-shown')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('box-hidden')), findsNothing);
      // Only the Show element rebuilt.
      expect(counts, everyElement(0));

      builds.clear();
      visible.value = false;
      await tester.pump();
      expect(builds, <String>['hidden']);
      expect(counts, everyElement(0));
    });
  });

  group('For', () {
    Widget wrap(Widget child) => Directionality(textDirection: TextDirection.ltr, child: child);

    Element itemElement(WidgetTester tester, String label) =>
        tester.element(find.byKey(ValueKey<String>('box-$label')));

    testWidgets('adds, removes and reorders without touching unchanged children', (
      WidgetTester tester,
    ) async {
      final items = Signal<List<String>>(<String>['a', 'b', 'c']);
      final builds = <String>[];
      final counts = List<int>.filled(3, 0);

      await tester.pumpWidget(
        wrap(
          _BuildCounter(
            depth: 2,
            counts: counts,
            child: For<String>(
              each: items,
              keyOf: (String item) => item,
              builder: (String item) =>
                  _Item(key: ValueKey<String>(item), label: item, builds: builds),
            ),
          ),
        ),
      );
      expect(builds, <String>['a', 'b', 'c']);

      final Element elementA = itemElement(tester, 'a');
      final Element elementC = itemElement(tester, 'c');

      // Insert in the middle and remove from the end.
      builds.clear();
      counts.fillRange(0, counts.length, 0);
      items.value = <String>['a', 'd', 'b'];
      await tester.pump();

      // Only the new key was built.
      expect(builds, <String>['d']);
      // The unchanged children are the same elements as before.
      expect(itemElement(tester, 'a'), same(elementA));
      expect(find.byKey(const ValueKey<String>('box-c')), findsNothing);
      expect(elementC.debugIsDefunct, isTrue);
      // Nothing above the For rebuilt.
      expect(counts, everyElement(0));

      // Reorder only.
      builds.clear();
      final Element elementB = itemElement(tester, 'b');
      final Element elementD = itemElement(tester, 'd');
      items.value = <String>['b', 'd', 'a'];
      await tester.pump();

      expect(builds, isEmpty);
      expect(itemElement(tester, 'a'), same(elementA));
      expect(itemElement(tester, 'b'), same(elementB));
      expect(itemElement(tester, 'd'), same(elementD));
      expect(counts, everyElement(0));

      // The render objects moved to match the new order, and they are the
      // same render objects as before.
      expect(_stackChildren(tester), <RenderObject>[
        elementB.renderObject!,
        elementD.renderObject!,
        elementA.renderObject!,
      ]);
    });

    testWidgets('item widgets read their own signals', (WidgetTester tester) async {
      final items = Signal<List<int>>(<int>[1, 2]);
      final colors = <int, Signal<Color>>{
        1: Signal<Color>(const Color(0xFF000001)),
        2: Signal<Color>(const Color(0xFF000002)),
      };

      await tester.pumpWidget(
        wrap(
          For<int>(
            each: items,
            keyOf: (int item) => item,
            builder: (int item) => ColoredBox(
              key: ValueKey<int>(item),
              color: colors[item]!,
              child: const SizedBox(width: .fixed(10), height: .fixed(10)),
            ),
          ),
        ),
      );

      final RenderObject renderObject = tester.renderObject<RenderObject>(
        find.byKey(const ValueKey<int>(1)),
      );
      colors[1]!.value = const Color(0xFFABCDEF);
      await tester.pump();
      expect(renderObject, paints..rect(color: const Color(0xFFABCDEF)));
    });

    testWidgets('unmounting the For deactivates every child', (WidgetTester tester) async {
      final items = Signal<List<String>>(<String>['a', 'b']);
      final builds = <String>[];

      await tester.pumpWidget(
        wrap(
          For<String>(
            each: items,
            keyOf: (String item) => item,
            builder: (String item) =>
                _Item(key: ValueKey<String>(item), label: item, builds: builds),
          ),
        ),
      );
      expect(items.subs, isNotNull);

      await tester.pumpWidget(wrap(const SizedBox()));
      expect(find.byKey(const ValueKey<String>('box-a')), findsNothing);
      expect(items.subs, isNull);
    });

    testWidgets('Positioned items get parent data and are laid out', (WidgetTester tester) async {
      final items = Signal<List<int>>(<int>[0, 1]);

      await tester.pumpWidget(
        wrap(
          For<int>(
            each: items,
            keyOf: (int item) => item,
            builder: (int item) => Positioned(
              key: ValueKey<int>(item),
              left: 10.0 * item,
              top: 20.0 * item,
              width: 5,
              height: 5,
              child: const SizedBox(),
            ),
          ),
        ),
      );

      final RenderBox box = tester.renderObject<RenderBox>(find.byKey(const ValueKey<int>(1)));
      expect((box.parentData! as StackParentData).isPositioned, isTrue);
      expect(box.size, const Size(5, 5));
      expect(tester.getTopLeft(find.byKey(const ValueKey<int>(1))), const Offset(10, 20));
    });

    testWidgets('a duplicate key is skipped rather than leaked', (WidgetTester tester) async {
      final items = Signal<List<String>>(<String>['a', 'b']);
      final builds = <String>[];

      await tester.pumpWidget(
        wrap(
          For<String>(
            each: items,
            keyOf: (String item) => item,
            builder: (String item) =>
                _Item(key: ValueKey<String>(item), label: item, builds: builds),
          ),
        ),
      );
      final Element elementA = itemElement(tester, 'a');
      builds.clear();

      items.value = <String>['a', 'b', 'a'];
      await tester.pump();

      // The duplicate is reported...
      expect(tester.takeException(), isAssertionError);
      // ...and skipped, leaving the two children that were already mounted
      // and no orphan render object behind them.
      expect(builds, isEmpty);
      expect(itemElement(tester, 'a'), same(elementA));
      expect(_stackChildren(tester), hasLength(2));

      // The next reconciliation still works, and lets go of what it should.
      items.value = <String>['b'];
      await tester.pump();
      expect(_stackChildren(tester), hasLength(1));
      expect(elementA.debugIsDefunct, isTrue);
    });
  });
}

/// The direct children of the [RenderStack] a [For] renders, in order.
List<RenderObject> _stackChildren(WidgetTester tester) {
  final RenderStack stack = tester.renderObject<RenderStack>(find.byType(For<String>));
  final children = <RenderObject>[];
  RenderBox? child = stack.firstChild;
  while (child != null) {
    children.add(child);
    child = (child.parentData! as StackParentData).nextSibling;
  }
  return children;
}

/// The number of edges in [node]'s subscriber list.
int _countSubs(ReactiveNode node) {
  var count = 0;
  for (Link? link = node.subs; link != null; link = link.nextSub) {
    count += 1;
  }
  return count;
}
