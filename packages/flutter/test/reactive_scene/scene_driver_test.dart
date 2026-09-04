// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/reactive_scene.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recording_compositor.dart';

/// A view that is nothing but a name and the real platform dispatcher, which is
/// all `SceneDriver.attachToView` touches.
class _FakeView implements ui.FlutterView {
  @override
  ui.PlatformDispatcher get platformDispatcher => ui.PlatformDispatcher.instance;

  @override
  double get devicePixelRatio => 1.0;

  @override
  int get viewId => 7;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late void Function()? previousScheduler;
  var framesRequested = 0;

  setUp(() {
    previousScheduler = signalFlushScheduler;
    framesRequested = 0;
    // Stand in for the platform's scheduleFrame, so that writes queue instead
    // of flushing synchronously, exactly as they do in standalone mode.
    signalFlushScheduler = () => framesRequested += 1;
  });

  tearDown(() {
    signalFlushScheduler = previousScheduler;
  });

  test('the driver drains the effect queue before it renders', () {
    final x = Signal<double>(0.0);
    final rect = RectNode(
      x: x.call,
      color: () => const ui.Color(0xFFFF0000),
      width: () => 10.0,
      height: () => 10.0,
    );
    final scene = ReactiveScene(rect);
    final compositor = RecordingCompositor();

    final driver = SceneDriver(
      scene,
      renderFrame: (ReactiveScene value) => value.composeFrame(compositor),
      onTick: (Duration elapsed) {
        x.value = elapsed.inMilliseconds.toDouble();
      },
    );

    driver.handleBeginFrame(const Duration(milliseconds: 16));
    expect(driver.elapsed, const Duration(milliseconds: 16));
    expect(
      compositor.pictures.length,
      0,
      reason: 'begin frame writes signals, it does not compose',
    );

    driver.handleDrawFrame();
    expect(compositor.pictures.length, 1);
    expect(compositor.lastDx, 16.0, reason: 'the frame sees the value written by onTick');

    driver.handleBeginFrame(const Duration(milliseconds: 32));
    driver.handleDrawFrame();
    expect(compositor.pictures.length, 2);
    expect(compositor.lastDx, 32.0);
    expect(rect.debugRecordCount, 1, reason: 'moving the node never re-recorded it');

    scene.dispose();
  });

  test('a tick runs its writes in one batch', () {
    final a = Signal<int>(0);
    final b = Signal<int>(0);
    var effectRuns = 0;
    final effect = Effect(() {
      a.value;
      b.value;
      effectRuns += 1;
    });
    expect(effectRuns, 1);

    final scene = ReactiveScene(GroupNode());
    final driver = SceneDriver(
      scene,
      renderFrame: (ReactiveScene value) => value.composeFrame(RecordingCompositor()),
      onTick: (Duration elapsed) {
        a.value += 1;
        b.value += 1;
      },
    );

    driver.handleBeginFrame(const Duration(milliseconds: 16));
    driver.handleDrawFrame();
    expect(effectRuns, 2, reason: 'two writes in one tick, one effect run');

    effect.dispose();
    scene.dispose();
  });

  test('a write outside a frame asks for one', () {
    final x = Signal<double>(0.0);
    final scene = ReactiveScene(
      RectNode(
        x: x.call,
        color: () => const ui.Color(0xFFFF0000),
        width: () => 10.0,
        height: () => 10.0,
      ),
    );
    scene.composeFrame(RecordingCompositor());
    framesRequested = 0;

    x.value = 5.0;
    expect(framesRequested, 1, reason: 'signalFlushScheduler is the platform scheduleFrame');

    scene.dispose();
  });

  test('attaching and detaching gives the platform callbacks back', () {
    final ui.PlatformDispatcher dispatcher = ui.PlatformDispatcher.instance;
    void previousPointer(ui.PointerDataPacket packet) {}
    final void Function()? outerScheduler = signalFlushScheduler;
    dispatcher.onPointerDataPacket = previousPointer;
    addTearDown(() => dispatcher.onPointerDataPacket = null);

    final scene = ReactiveScene(GroupNode());
    final driver = SceneDriver(scene, renderFrame: (ReactiveScene value) {});
    driver.attachToView(_FakeView());

    expect(dispatcher.onBeginFrame, isNotNull);
    expect(dispatcher.onDrawFrame, isNotNull);
    expect(signalFlushScheduler, isNot(outerScheduler));

    driver.detach();

    expect(dispatcher.onBeginFrame, isNull, reason: 'nobody owned frames before');
    expect(dispatcher.onDrawFrame, isNull);
    expect(dispatcher.onPointerDataPacket, same(previousPointer), reason: 'given back, not nulled');
    expect(signalFlushScheduler, same(outerScheduler));

    scene.dispose();
  });

  test('disposing the scene detaches the driver it attached', () {
    final ui.PlatformDispatcher dispatcher = ui.PlatformDispatcher.instance;
    final scene = ReactiveScene(GroupNode());
    scene.attachToView(_FakeView());
    expect(dispatcher.onBeginFrame, isNotNull);

    scene.dispose();

    expect(dispatcher.onBeginFrame, isNull);
    expect(dispatcher.onDrawFrame, isNull);
  });
}
