import 'dart:async';

import 'package:baocode_mobile/ui/widgets/pull_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({
  required Future<void> Function() onRefresh,
  Widget? header,
  int rows = 3,
}) => MaterialApp(
  home: Scaffold(
    body: PullRefresh(
      onRefresh: onRefresh,
      header: header,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < rows; i++) ListTile(title: Text('第 $i 行')),
        ],
      ),
    ),
  ),
);

double _opacity(WidgetTester tester, int index) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byKey(const ValueKey('pull-refresh-dots')),
            matching: find.byType(Opacity),
          )
          .at(index),
    )
    .opacity;

void main() {
  testWidgets('短距离下拉不刷新，也不显示灰点', (tester) async {
    var refreshes = 0;
    await tester.pumpWidget(_host(onRefresh: () async => refreshes++));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('pull-refresh-dots'))).height,
      0,
    );
    await tester.drag(find.text('第 0 行'), const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    expect(
      tester.getSize(find.byKey(const ValueKey('pull-refresh-dots'))).height,
      0,
    );
  });

  testWidgets('拉过阈值松手刷新一次，灰点时依次起伏，完成后收起', (tester) async {
    var refreshes = 0;
    final done = Completer<void>();
    await tester.pumpWidget(
      _host(
        onRefresh: () {
          refreshes++;
          return done.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.text('第 0 行'), const Offset(0, 120));
    await tester.pump();
    // 松手前就看得见：第一个点先亮。
    expect(find.byKey(const ValueKey('pull-refresh-dots')), findsOneWidget);
    expect(refreshes, 1);
    final first = _opacity(tester, 0);
    await tester.pump(const Duration(milliseconds: 160));
    expect(_opacity(tester, 0), isNot(first));
    done.complete();
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('pull-refresh-dots'))).height,
      0,
    );
  });

  testWidgets('下拉过程中灰点按距离逐个出现', (tester) async {
    final done = Completer<void>();
    await tester.pumpWidget(_host(onRefresh: () => done.future));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第 0 行')),
    );
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final early = [for (var i = 0; i < 3; i++) _opacity(tester, i)];
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    final late = [for (var i = 0; i < 3; i++) _opacity(tester, i)];
    // 刚开始只亮出第一个点，拉得更深第二三个才跟上。
    expect(early[0], greaterThan(0));
    expect(early[2], 0);
    expect(late[0], greaterThanOrEqualTo(early[0]));
    expect(late[1], greaterThan(0));
    expect(late[2], greaterThan(0));
    await gesture.up();
    done.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('刷新失败不把异常抛进界面，灰点照样收起', (tester) async {
    await tester.pumpWidget(
      _host(onRefresh: () async => throw StateError('合成失败')),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.text('第 0 行'), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('pull-refresh-dots'))).height,
      0,
    );
  });

  testWidgets('搜索框和列表一起跟手下拉，松手回到原位', (tester) async {
    await tester.pumpWidget(
      _host(
        onRefresh: () async {},
        header: const Padding(
          padding: EdgeInsets.all(8),
          child: Text('搜索', key: ValueKey('header')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('header'));
    final headerBefore = tester.getTopLeft(header);
    final rowBefore = tester.getTopLeft(find.text('第 0 行'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('第 0 行')),
    );
    await gesture.moveBy(const Offset(0, 40));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final moved = tester.getTopLeft(header).dy - headerBefore.dy;
    expect(moved, greaterThan(0));
    expect(
      tester.getTopLeft(find.text('第 0 行')).dy - rowBefore.dy,
      closeTo(moved, .01),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header), headerBefore);
  });

  testWidgets('拉过阈值震一下，来回拉也只在越过时震', (tester) async {
    var armed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PullRefresh(
            onRefresh: () async {},
            onArmed: () => armed++,
            child: ListView(children: const [ListTile(title: Text('行'))]),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.text('行')));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(armed, 0);
    await gesture.moveBy(const Offset(0, 80));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    expect(armed, 1);
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
