// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_widgets.dart';

void main() {
  testWidgets('Stateful widget smoke test', (WidgetTester tester) async {
    void checkTree(BoxDecoration expectedDecoration) {
      final SingleChildRenderObjectElement element = tester.element(
        find.byElementPredicate(
          (Element element) =>
              element is SingleChildRenderObjectElement && element.renderObject is! RenderView,
        ),
      );
      expect(element, isNotNull);
      expect(element.renderObject, isA<RenderDecoratedBox>());
      final renderObject = element.renderObject as RenderDecoratedBox;
      expect(renderObject.decoration, equals(expectedDecoration));
    }

    await tester.pumpWidget(
      const FlipWidget(
        left: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
        right: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
      ),
    );

    checkTree(kBoxDecorationA);

    await tester.pumpWidget(
      const FlipWidget(
        left: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
        right: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
      ),
    );

    checkTree(kBoxDecorationB);

    flipStatefulWidget(tester);

    await tester.pump();

    checkTree(kBoxDecorationA);

    await tester.pumpWidget(
      const FlipWidget(
        left: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
        right: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
      ),
    );

    checkTree(kBoxDecorationB);
  });

  testWidgets("Don't rebuild subwidgets", (WidgetTester tester) async {
    await tester.pumpWidget(
      const FlipWidget(
        key: Key('rebuild test'),
        left: TestBuildCounter(),
        right: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
      ),
    );

    expect(TestBuildCounter.buildCount, equals(1));

    flipStatefulWidget(tester);

    await tester.pump();

    expect(TestBuildCounter.buildCount, equals(1));
  });
}
