// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_widgets.dart';

void checkTree(WidgetTester tester, List<BoxDecoration> expectedDecorations) {
  final MultiChildRenderObjectElement element = tester.element(
    find.byElementPredicate((Element element) => element is MultiChildRenderObjectElement),
  );
  expect(element, isNotNull);
  expect(element.renderObject, isA<RenderStack>());
  final renderObject = element.renderObject as RenderStack;
  try {
    RenderObject? child = renderObject.firstChild;
    for (final decoration in expectedDecorations) {
      expect(child, isA<RenderDecoratedBox>());
      final decoratedBox = child! as RenderDecoratedBox;
      expect(decoratedBox.decoration, equals(decoration));
      final decoratedBoxParentData = decoratedBox.parentData! as StackParentData;
      child = decoratedBoxParentData.nextSibling;
    }
    expect(child, isNull);
  } catch (e) {
    debugPrint(renderObject.toStringDeep());
    rethrow;
  }
}

void main() {
  testWidgets('MultiChildRenderObjectElement control test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(decoration: .fixed(kBoxDecorationA)),
          DecoratedBox(decoration: .fixed(kBoxDecorationB)),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationB, kBoxDecorationC]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(decoration: .fixed(kBoxDecorationA)),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationC]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(decoration: .fixed(kBoxDecorationA)),
          DecoratedBox(key: Key('b'), decoration: .fixed(kBoxDecorationB)),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationB, kBoxDecorationC]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(key: Key('b'), decoration: .fixed(kBoxDecorationB)),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
          DecoratedBox(key: Key('a'), decoration: .fixed(kBoxDecorationA)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationB, kBoxDecorationC, kBoxDecorationA]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(key: Key('a'), decoration: .fixed(kBoxDecorationA)),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
          DecoratedBox(key: Key('b'), decoration: .fixed(kBoxDecorationB)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationC, kBoxDecorationB]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[DecoratedBox(decoration: .fixed(kBoxDecorationC))],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationC]);

    await tester.pumpWidget(const Stack(textDirection: TextDirection.ltr));

    checkTree(tester, <BoxDecoration>[]);
  });

  testWidgets('MultiChildRenderObjectElement with stateless widgets', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(decoration: .fixed(kBoxDecorationA)),
          DecoratedBox(decoration: .fixed(kBoxDecorationB)),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationB, kBoxDecorationC]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(decoration: .fixed(kBoxDecorationA)),
          DummyWidget(child: DecoratedBox(decoration: .fixed(kBoxDecorationB))),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationB, kBoxDecorationC]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(decoration: .fixed(kBoxDecorationA)),
          DummyWidget(
            child: DummyWidget(child: DecoratedBox(decoration: .fixed(kBoxDecorationB))),
          ),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationB, kBoxDecorationC]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DummyWidget(
            child: DummyWidget(child: DecoratedBox(decoration: .fixed(kBoxDecorationB))),
          ),
          DummyWidget(child: DecoratedBox(decoration: .fixed(kBoxDecorationA))),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationB, kBoxDecorationA, kBoxDecorationC]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DummyWidget(child: DecoratedBox(decoration: .fixed(kBoxDecorationB))),
          DummyWidget(child: DecoratedBox(decoration: .fixed(kBoxDecorationA))),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationB, kBoxDecorationA, kBoxDecorationC]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DummyWidget(
            key: Key('b'),
            child: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
          ),
          DummyWidget(
            key: Key('a'),
            child: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
          ),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationB, kBoxDecorationA]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DummyWidget(
            key: Key('a'),
            child: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
          ),
          DummyWidget(
            key: Key('b'),
            child: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
          ),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationB]);

    await tester.pumpWidget(const Stack(textDirection: TextDirection.ltr));

    checkTree(tester, <BoxDecoration>[]);
  });

  testWidgets('MultiChildRenderObjectElement with stateful widgets', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(decoration: .fixed(kBoxDecorationA)),
          DecoratedBox(decoration: .fixed(kBoxDecorationB)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationB]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          FlipWidget(
            left: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
            right: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
          ),
          DecoratedBox(decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationA, kBoxDecorationC]);

    flipStatefulWidget(tester);
    await tester.pump();

    checkTree(tester, <BoxDecoration>[kBoxDecorationB, kBoxDecorationC]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          FlipWidget(
            left: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
            right: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
          ),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationB]);

    flipStatefulWidget(tester);
    await tester.pump();

    checkTree(tester, <BoxDecoration>[kBoxDecorationA]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          FlipWidget(
            key: Key('flip'),
            left: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
            right: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          DecoratedBox(key: Key('c'), decoration: .fixed(kBoxDecorationC)),
          FlipWidget(
            key: Key('flip'),
            left: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
            right: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
          ),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationC, kBoxDecorationA]);

    flipStatefulWidget(tester);
    await tester.pump();

    checkTree(tester, <BoxDecoration>[kBoxDecorationC, kBoxDecorationB]);

    await tester.pumpWidget(
      const Stack(
        textDirection: TextDirection.ltr,
        children: <Widget>[
          FlipWidget(
            key: Key('flip'),
            left: DecoratedBox(decoration: .fixed(kBoxDecorationA)),
            right: DecoratedBox(decoration: .fixed(kBoxDecorationB)),
          ),
          DecoratedBox(key: Key('c'), decoration: .fixed(kBoxDecorationC)),
        ],
      ),
    );

    checkTree(tester, <BoxDecoration>[kBoxDecorationB, kBoxDecorationC]);
  });
}

class DummyWidget extends StatelessWidget {
  const DummyWidget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
