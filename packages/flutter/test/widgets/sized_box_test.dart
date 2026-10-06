// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SizedBox constructors', (WidgetTester tester) async {
    const a = SizedBox();
    expect(a.width?.value, isNull);
    expect(a.height?.value, isNull);

    const b = SizedBox(width: .fixed(10.0));
    expect(b.width?.value, 10.0);
    expect(b.height?.value, isNull);

    const c = SizedBox(width: .fixed(10.0), height: .fixed(20.0));
    expect(c.width?.value, 10.0);
    expect(c.height?.value, 20.0);

    final d = SizedBox.fromSize();
    expect(d.width?.value, isNull);
    expect(d.height?.value, isNull);

    final e = SizedBox.fromSize(size: const .fixed(Size(1.0, 2.0)));
    expect(e.width?.value, 1.0);
    expect(e.height?.value, 2.0);

    const f = SizedBox.expand();
    expect(f.width?.value, double.infinity);
    expect(f.height?.value, double.infinity);

    const g = SizedBox.shrink();
    expect(g.width?.value, 0.0);
    expect(g.height?.value, 0.0);
  });

  testWidgets('SizedBox - no child', (WidgetTester tester) async {
    final GlobalKey patient = GlobalKey();

    await tester.pumpWidget(Center(child: SizedBox(key: patient)));
    expect(patient.currentContext!.size, equals(Size.zero));

    await tester.pumpWidget(
      Center(
        child: SizedBox(key: patient, height: const .fixed(0.0)),
      ),
    );
    expect(patient.currentContext!.size, equals(Size.zero));

    await tester.pumpWidget(Center(child: SizedBox.shrink(key: patient)));
    expect(patient.currentContext!.size, equals(Size.zero));

    await tester.pumpWidget(
      Center(
        child: SizedBox(key: patient, width: const .fixed(100.0), height: const .fixed(100.0)),
      ),
    );
    expect(patient.currentContext!.size, equals(const Size(100.0, 100.0)));

    await tester.pumpWidget(
      Center(
        child: SizedBox(key: patient, width: const .fixed(1000.0), height: const .fixed(1000.0)),
      ),
    );
    expect(patient.currentContext!.size, equals(const Size(800.0, 600.0)));

    await tester.pumpWidget(Center(child: SizedBox.expand(key: patient)));
    expect(patient.currentContext!.size, equals(const Size(800.0, 600.0)));

    await tester.pumpWidget(Center(child: SizedBox.shrink(key: patient)));
    expect(patient.currentContext!.size, equals(Size.zero));
  });

  testWidgets('SizedBox - container child', (WidgetTester tester) async {
    final GlobalKey patient = GlobalKey();

    await tester.pumpWidget(
      Center(
        child: SizedBox(key: patient, child: Container()),
      ),
    );
    expect(patient.currentContext!.size, equals(const Size(800.0, 600.0)));

    await tester.pumpWidget(
      Center(
        child: SizedBox(key: patient, height: const .fixed(0.0), child: Container()),
      ),
    );
    expect(patient.currentContext!.size, equals(const Size(800.0, 0.0)));

    await tester.pumpWidget(
      Center(
        child: SizedBox.shrink(key: patient, child: Container()),
      ),
    );
    expect(patient.currentContext!.size, equals(Size.zero));

    await tester.pumpWidget(
      Center(
        child: SizedBox(
          key: patient,
          width: const .fixed(100.0),
          height: const .fixed(100.0),
          child: Container(),
        ),
      ),
    );
    expect(patient.currentContext!.size, equals(const Size(100.0, 100.0)));

    await tester.pumpWidget(
      Center(
        child: SizedBox(
          key: patient,
          width: const .fixed(1000.0),
          height: const .fixed(1000.0),
          child: Container(),
        ),
      ),
    );
    expect(patient.currentContext!.size, equals(const Size(800.0, 600.0)));

    await tester.pumpWidget(
      Center(
        child: SizedBox.expand(key: patient, child: Container()),
      ),
    );
    expect(patient.currentContext!.size, equals(const Size(800.0, 600.0)));

    await tester.pumpWidget(
      Center(
        child: SizedBox.shrink(key: patient, child: Container()),
      ),
    );
    expect(patient.currentContext!.size, equals(Size.zero));
  });

  testWidgets('SizedBox.square tests', (WidgetTester tester) async {
    await tester.pumpWidget(
      const SizedBox.square(dimension: .fixed(100), child: SizedBox.shrink()),
    );

    expect(
      tester.renderObject<RenderConstrainedBox>(find.byType(SizedBox).first).additionalConstraints,
      BoxConstraints.tight(const Size.square(100)),
    );
  });

  testWidgets('SizedBox does not crash at zero area', (WidgetTester tester) async {
    tester.view.physicalSize = Size.zero;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: SizedBox(child: Placeholder())),
      ),
    );
    expect(tester.getSize(find.byType(SizedBox)), Size.zero);
  });
}
