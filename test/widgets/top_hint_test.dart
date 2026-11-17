import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode_mobile/ui/widgets/top_hint.dart';

Future<BuildContext> _pump(WidgetTester tester, {double keyboard = 0}) async {
  tester.view
    ..physicalSize = const Size(400, 800)
    ..devicePixelRatio = 1
    ..viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (inner) {
          context = inner;
          return const Scaffold();
        },
      ),
    ),
  );
  return context;
}

void main() {
  testWidgets('连着提示两次，只留后一条，不叠在一起', (tester) async {
    final context = await _pump(tester);
    showTopHint(context, '第一条');
    await tester.pump();
    showTopHint(context, '第二条');
    await tester.pump();
    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('第二条'), findsNothing);
  });

  testWidgets('键盘弹出时，提示浮在键盘上面', (tester) async {
    final context = await _pump(tester, keyboard: 300);
    showTopHint(context, '请填写名字');
    await tester.pump();
    final hint = tester.getRect(find.byKey(const ValueKey('top-hint')));
    expect(hint.bottom, lessThan(800 - 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长提示折成多行，左右不顶到屏幕边', (tester) async {
    final context = await _pump(tester);
    showTopHint(context, '这是一条很长的提示，' * 8);
    await tester.pump();
    final hint = tester.getRect(find.byKey(const ValueKey('top-hint')));
    expect(hint.left, greaterThan(0));
    expect(hint.right, lessThan(400));
    expect(hint.height, greaterThan(40));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
