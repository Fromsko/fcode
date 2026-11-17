import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/models/user_facing_error.dart';
import 'package:baocode_mobile/link/phone_link.dart';
import 'package:baocode_mobile/state/app_state.dart';
import 'package:baocode_mobile/theme/app_theme.dart';
import 'package:baocode_mobile/ui/bots/bots_tab.dart';
import 'package:baocode_mobile/ui/conversations/chats_tab.dart';
import 'package:baocode_mobile/ui/files/files_tab.dart';
import 'package:baocode_mobile/ui/widgets/lucide_icon.dart';
import 'package:baocode_mobile/ui/widgets/mobile_widgets.dart' show ListRow;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends AppState {
  _State() : super(store: MemoryLinkStore()) {
    settings.language = 'zh';
  }

  bool online = true;
  bool? projectPinned = false;
  bool sessionPinned = false;
  bool hidden = false;
  bool deleted = false;
  bool fail = false;
  List<LinkBot> botList = const [];
  List<LinkGroup> groupList = const [];
  Completer<void>? pending;
  final calls = <(String, String, Map<String, Object?>)>[];

  @override
  String? get selectedDesktopId => 'desk';
  @override
  List<KeptDesktop> get desktops => const [
    KeptDesktop(id: 'desk', name: '测试电脑', publicKey: ''),
  ];
  @override
  bool isOnline(String desktopId) => online;
  @override
  List<BotRef> get bots => [for (final bot in botList) BotRef('desk', bot)];
  @override
  List<GroupRef> get groups => [
    for (final group in groupList) GroupRef('desk', group),
  ];
  @override
  Future<LinkState> refreshDesktopState(String desktop) async =>
      const LinkState(
        device: DeviceInfo(name: '测试电脑', kind: 'windows', system: '合成系统'),
      );
  @override
  List<ProjectRef> get projects => [
    if (!hidden)
      ProjectRef(
        'desk',
        ProjectInfo(
          id: 'project',
          name: '项目甲',
          path: '/project',
          pinned: projectPinned,
        ),
      ),
  ];
  @override
  List<SessionRef> get sessions => [
    if (!deleted)
      SessionRef(
        'desk',
        SessionSummary(
          id: 'session',
          project: 'project',
          title: '对话甲',
          updatedAt: DateTime(2026),
          pinned: sessionPinned,
        ),
      ),
    SessionRef(
      'desk',
      SessionSummary(
        id: 'other',
        project: 'project',
        title: '对话乙',
        updatedAt: DateTime(2025),
      ),
    ),
  ];
  @override
  Future<Object?> request(
    String desktop,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    calls.add((desktop, method, params));
    await pending?.future;
    if (fail) throw const UserFacingError('合成操作失败');
    if (method == LinkMethods.pinProject) {
      projectPinned = params['pinned'] as bool;
    }
    if (method == LinkMethods.hideProject) hidden = true;
    if (method == LinkMethods.pin) sessionPinned = params['pinned'] as bool;
    if (method == LinkMethods.delete) deleted = true;
    notifyListeners();
    return null;
  }
}

Widget _host(
  _State state, {
  bool project = false,
  bool files = false,
  bool botsTab = false,
  double scale = 1,
}) => MaterialApp(
  theme: MobileTheme.build(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: AnimatedBuilder(
    animation: state,
    builder: (_, _) => files
        ? FilesTab(state: state)
        : botsTab
        ? BotsTab(state: state)
        : project
        ? ProjectChatsPage(state: state, project: state.projects.first)
        : ChatsTab(state: state),
  ),
);

Finder _row(String title) => find.byWidgetPredicate(
  (widget) => widget is ListRow && widget.title.startsWith(title),
);

Finder get _menu => find.byKey(const ValueKey('dropdown-panel'));

/// 打开的长按菜单里各项的文字，从上到下。
List<String> _menuLabels(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(of: _menu, matching: find.byType(Text)),
  ))
    ?text.data,
];

/// 截下写进剪贴板的文字，测试结束还原。
List<String> _mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

Future<void> _press(WidgetTester tester, String title) async {
  await tester.longPress(_row(title));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String title, String item) async {
  await _press(tester, title);
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

const _assistant = LinkBot(id: 'xb', name: '小宝', assistant: true);
const _helper = LinkBot(id: 'hp', name: '帮手');

void main() {
  testWidgets('首页项目长按置顶和取消置顶，只更新所选项目', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    expect(find.text('置顶'), findsNothing);
    await _press(tester, '项目甲');
    expect(state.calls, isEmpty);
    expect(find.text('从列表移除'), findsOneWidget);
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(_menu, findsNothing);
    expect(state.calls.single.$1, 'desk');
    expect(state.calls.single.$2, LinkMethods.pinProject);
    expect(state.calls.single.$3, {'project': 'project', 'pinned': true});
    await _pick(tester, '项目甲', '取消置顶');
    expect(state.calls.last.$3, {'project': 'project', 'pinned': false});
  });

  testWidgets('从列表移除项目须确认且明确不删除文件和对话', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await _pick(tester, '项目甲', '从列表移除');
    expect(find.textContaining('不删除文件或对话'), findsOneWidget);
    expect(state.calls, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.calls, isEmpty);
    await _pick(tester, '项目甲', '从列表移除');
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await tester.pumpAndSettle();
    expect(state.calls.single.$2, LinkMethods.hideProject);
    expect(state.calls.single.$3, {'project': 'project'});
  });

  testWidgets('文件页项目也能长按，旧电脑不显示不支持的置顶', (tester) async {
    final state = _State()..projectPinned = null;
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, files: true));
    await _press(tester, '项目甲');
    expect(find.text('置顶'), findsNothing);
    expect(find.text('从列表移除'), findsOneWidget);
  });

  testWidgets('项目长按菜单和电脑一样排序，复制路径不请求电脑，离线只剩复制路径', (tester) async {
    final copied = _mockClipboard(tester);
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await _press(tester, '项目甲');
    expect(_menuLabels(tester), ['新对话', '浏览文件', '置顶', '复制路径', '全部归档', '从列表移除']);
    await tester.tap(find.text('复制路径'));
    await tester.pumpAndSettle();
    expect(copied, ['/project']);
    expect(find.text('已复制'), findsOneWidget);
    expect(state.calls, isEmpty);

    state.online = false;
    state.notifyListeners();
    await tester.pumpAndSettle();
    await _press(tester, '项目甲');
    expect(_menuLabels(tester), ['复制路径']);
  });

  testWidgets('全部归档须确认，确认后逐个归档该项目的对话', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await _pick(tester, '项目甲', '全部归档');
    expect(find.textContaining('2 段对话'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.calls, isEmpty);
    await _pick(tester, '项目甲', '全部归档');
    await tester.tap(find.widgetWithText(FilledButton, '归档'));
    await tester.pumpAndSettle();
    expect(
      [for (final call in state.calls) '${call.$2} ${call.$3['session']}'],
      ['${LinkMethods.archive} session', '${LinkMethods.archive} other'],
    );
  });

  testWidgets('项目长按能新建对话和浏览文件', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await _pick(tester, '项目甲', '浏览文件');
    expect(find.byType(FilesPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _pick(tester, '项目甲', '新对话');
    final draft = state.calls.where((call) => call.$2 == LinkMethods.draft);
    expect(draft.single.$3['project'], 'project');
  });

  testWidgets('项目内对话长按置顶与删除，取消删除不发请求', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, project: true));
    await _pick(tester, '对话甲', '置顶');
    expect(state.calls.single.$2, LinkMethods.pin);
    expect(state.calls.single.$3, {'session': 'session', 'pinned': true});
    await _press(tester, '对话甲');
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.tap(find.text('删除该聊天'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法撤销'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.calls, hasLength(1));
    await _pick(tester, '对话甲', '删除该聊天');
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(state.calls.last.$1, 'desk');
    expect(state.calls.last.$2, LinkMethods.delete);
    expect(state.calls.last.$3, {'session': 'session'});
    expect(find.text('对话甲'), findsNothing);
    expect(find.text('对话乙'), findsOneWidget);
  });

  testWidgets('首页置顶对话长按取消置顶后回到项目里，菜单没有放到首页', (tester) async {
    final state = _State()..sessionPinned = true;
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    expect(find.byKey(const ValueKey('pinned-desk-session')), findsOneWidget);
    await _press(tester, '对话甲');
    expect(find.text('放到首页'), findsNothing);
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();
    expect(state.calls.single.$3, {'session': 'session', 'pinned': false});
    expect(find.byKey(const ValueKey('pinned-desk-session')), findsNothing);
    expect(state.sessions.map((ref) => ref.session.id), contains('session'));
  });

  testWidgets('菜单贴着手指：下方放不下翻到上方，右边放不下收回来', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    Future<Rect> at(Offset point) async {
      await tester.longPressAt(point);
      await tester.pumpAndSettle();
      final rect = tester.getRect(_menu);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(_menu, findsNothing);
      return rect;
    }

    final row = tester.getRect(_row('项目甲'));
    final below = await at(row.center);
    expect(below.topLeft, row.center);

    final right = await at(Offset(396, row.center.dy));
    expect(right.right, lessThanOrEqualTo(392));

    // 同一套算法，把行挪到屏幕底部来测翻转。
    tester.view.physicalSize = Size(400, row.center.dy + 40);
    await tester.pumpAndSettle();
    final above = await at(tester.getRect(_row('项目甲')).center);
    expect(above.bottom, tester.getRect(_row('项目甲')).center.dy);
    expect(state.calls, isEmpty);
  });

  testWidgets('菜单打开时这一行高亮，关闭后恢复', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, project: true));
    Color? shade() => tester
        .widgetList<DecoratedBox>(
          find.ancestor(of: _row('对话甲'), matching: find.byType(DecoratedBox)),
        )
        .map((box) => (box.decoration as BoxDecoration).color)
        .firstOrNull;
    expect(shade(), isNull);
    await _press(tester, '对话甲');
    expect(shade(), isNotNull);
    await tester.tapAt(const Offset(2, 590));
    await tester.pumpAndSettle();
    expect(shade(), isNull);
  });

  testWidgets('离线时对话长按只剩复制会话 ID，失败后保留行并显示错误', (tester) async {
    final state = _State()..online = false;
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, project: true));
    await _press(tester, '对话甲');
    expect(_menuLabels(tester), ['复制会话 ID'], reason: '其余操作都要电脑在线');
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    state
      ..online = true
      ..fail = true;
    state.notifyListeners();
    await tester.pumpAndSettle();
    await _pick(tester, '对话甲', '置顶');
    expect(find.textContaining('合成操作失败'), findsOneWidget);
    expect(find.text('对话甲'), findsOneWidget);
  });

  testWidgets('对话长按菜单和电脑一样排序，复制会话 ID 不请求电脑', (tester) async {
    final copied = _mockClipboard(tester);
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, project: true));
    await _press(tester, '对话甲');
    expect(_menuLabels(tester), ['重命名', '置顶', '归档', '复制会话 ID', '删除该聊天']);
    await tester.tap(find.text('复制会话 ID'));
    await tester.pumpAndSettle();
    expect(copied, ['session']);
    expect(find.text('已复制'), findsOneWidget);
    expect(state.calls, isEmpty);
  });

  testWidgets('窄屏大字号不溢出，进行中的请求不会重复提交', (tester) async {
    tester.view.physicalSize = const Size(300, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _State()..pending = Completer<void>();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, project: true, scale: 1.8));
    await _press(tester, '对话甲');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    await _press(tester, '对话甲');
    expect(_menu, findsNothing);
    expect(state.calls, hasLength(1));
    state.pending!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('助理只能删聊天，须确认，不会被删除', (tester) async {
    final state = _State()..botList = const [_assistant];
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, botsTab: true));
    await _press(tester, '小宝');
    expect(find.text('删除该 Bot'), findsNothing);
    await tester.tap(find.text('删除该聊天'));
    await tester.pumpAndSettle();
    expect(state.calls, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(state.calls.single.$2, LinkMethods.clearBotChat);
    expect(state.calls.single.$3, {'bot': 'xb'});
  });

  testWidgets('Bot 长按置顶只存手机，普通 Bot 能删除并清掉置顶，也能进资料', (tester) async {
    final state = _State()..botList = const [_assistant, _helper];
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, botsTab: true));
    await _pick(tester, '帮手', '置顶');
    expect(state.settings.pinnedBots, {('desk', 'hp')});
    expect(state.calls, isEmpty);
    await _press(tester, '帮手');
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.tapAt(const Offset(2, 590));
    await tester.pumpAndSettle();
    await _pick(tester, '帮手', '取消置顶');
    expect(state.settings.pinnedBots, isEmpty);
    expect(state.calls, isEmpty);
    await _pick(tester, '帮手', '置顶');
    await _press(tester, '帮手');
    expect(find.text('Bot 资料'), findsOneWidget);
    await tester.tap(find.text('删除该 Bot'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(state.calls.single.$2, LinkMethods.deleteBot);
    expect(state.calls.single.$3, {'bot': 'hp'});
    expect(state.settings.pinnedBots, isEmpty);
  });

  testWidgets('离线时 Bot 仍能置顶，不显示删除', (tester) async {
    final state = _State()
      ..botList = const [_helper]
      ..online = false;
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, botsTab: true));
    await _press(tester, '帮手');
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('删除该 Bot'), findsNothing);
  });

  testWidgets('Bot 页把群聊和 Bot 混在一个列表，置顶在前，再按最近时间', (tester) async {
    final state = _State()
      ..botList = [
        LinkBot(id: 'old', name: '旧 Bot', updatedAt: DateTime(2026, 1)),
        LinkBot(id: 'new', name: '新 Bot', updatedAt: DateTime(2026, 8)),
      ]
      ..groupList = [
        LinkGroup(
          id: 'g',
          name: '群甲',
          last: LinkGroupMessage(
            seq: 1,
            at: DateTime(2026, 5),
            from: 'user',
            text: '群消息',
          ),
        ),
      ]
      ..settings.pinnedGroups.add(('desk', 'g'))
      ..settings.pinnedBots.add(('desk', 'old'));
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, botsTab: true));
    double top(String text) => tester.getTopLeft(_row(text)).dy;
    // 置顶的群和 Bot 在最前，彼此再按时间；其余按时间。
    expect(top('群甲'), lessThan(top('旧 Bot')));
    expect(top('旧 Bot'), lessThan(top('新 Bot')));
    // 不再有分组标题。
    expect(find.text('群聊'), findsNothing);
    expect(find.text('Bots'), findsNothing);
    expect(
      find.descendant(
        of: _row('群甲'),
        matching: find.byWidgetPredicate(
          (widget) => widget is LucideIcon && widget.name == 'pin',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('群聊长按置顶与取消置顶，只存手机不发请求', (tester) async {
    final state = _State()
      ..groupList = [const LinkGroup(id: 'g', name: '群甲', members: [])];
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, botsTab: true));
    await _pick(tester, '群甲', '置顶');
    expect(state.settings.pinnedGroups, {('desk', 'g')});
    expect(state.calls, isEmpty);
    await _pick(tester, '群甲', '取消置顶');
    expect(state.settings.pinnedGroups, isEmpty);
    expect(state.calls, isEmpty);
  });

  testWidgets('Bot 页右上角只有一个加号，菜单里发起群聊与添加 Bot', (tester) async {
    final state = _State()..botList = const [_helper];
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, botsTab: true));
    expect(find.byTooltip('新建'), findsOneWidget);
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    expect(find.text('发起群聊'), findsOneWidget);
    expect(find.text('添加 Bot'), findsOneWidget);
    await tester.tapAt(const Offset(2, 590));
    await tester.pumpAndSettle();
    expect(state.calls, isEmpty);
  });

  testWidgets('群聊长按能删除：确认后请求电脑、刷新并清掉置顶', (tester) async {
    final state = _State()
      ..groupList = [const LinkGroup(id: 'g', name: '群甲')]
      ..settings.pinnedGroups.add(('desk', 'g'));
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, botsTab: true));
    await _pick(tester, '群甲', '删除群聊');
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(state.calls.single.$2, LinkMethods.deleteGroup);
    expect(state.calls.single.$3, {'group': 'g'});
    expect(state.settings.pinnedGroups, isEmpty);
  });
}
