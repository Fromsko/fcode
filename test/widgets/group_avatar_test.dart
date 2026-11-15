import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/link/link_store.dart';
import 'package:baocode_mobile/state/app_state.dart';
import 'package:baocode_mobile/ui/bots/bots_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends AppState {
  _State() : super(store: MemoryLinkStore());
  List<BotRef> botList = const [];
  @override
  List<BotRef> get bots => botList;
}

LinkGroup _group(List<String> members) =>
    LinkGroup(id: 'g', name: '群', members: members);

Future<void> _pump(WidgetTester tester, _State state, GroupRef ref) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GroupAvatar(state: state, ref: ref),
          ),
        ),
      ),
    );

void main() {
  testWidgets('群头像画出认得出来的成员头像', (tester) async {
    final state = _State()
      ..botList = const [
        BotRef('d', LinkBot(id: 'a', name: '甲')),
        BotRef('d', LinkBot(id: 'b', name: '乙')),
        BotRef('d', LinkBot(id: 'c', name: '丙')),
      ];
    addTearDown(state.dispose);
    await _pump(tester, state, GroupRef('d', _group(['a', 'b', 'c'])));
    expect(find.byType(BotAvatar), findsNWidgets(3));
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    expect(find.text('丙'), findsOneWidget);
  });

  testWidgets('认不出的成员跳过；一个都没有时是群图标', (tester) async {
    final state = _State()
      ..botList = const [BotRef('d', LinkBot(id: 'a', name: '甲'))];
    addTearDown(state.dispose);
    await _pump(tester, state, GroupRef('d', _group(['a', 'gone'])));
    expect(find.byType(BotAvatar), findsOneWidget);

    await _pump(tester, state, GroupRef('d', _group(['gone'])));
    expect(find.byType(BotAvatar), findsNothing);
    expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
  });

  testWidgets('超过九个只画九个', (tester) async {
    final state = _State()
      ..botList = [
        for (var i = 0; i < 12; i++)
          BotRef('d', LinkBot(id: 'b$i', name: 'Bot$i')),
      ];
    addTearDown(state.dispose);
    await _pump(
      tester,
      state,
      GroupRef('d', _group([for (var i = 0; i < 12; i++) 'b$i'])),
    );
    expect(find.byType(BotAvatar), findsNWidgets(9));
  });
}
