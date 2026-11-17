import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/chat/widgets/pixel_loader.dart';
import 'package:baocode_mobile/link/link_store.dart';
import 'package:baocode_mobile/link/phone_link.dart'
    show DesktopLinkStatus, KeptDesktop;
import 'package:baocode_mobile/state/app_state.dart';
import 'package:baocode_mobile/ui/files/files_tab.dart';
import 'package:baocode_mobile/ui/focus/focus_shell.dart';
import 'package:baocode_mobile/ui/home_shell.dart';
import 'package:baocode_mobile/ui/tasks/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends AppState {
  _State() : super(store: MemoryLinkStore()) {
    settings
      ..language = 'zh'
      ..layout = 'focus'
      ..desktop = '甲';
  }
  final calls = <(String, Map<String, Object?>)>[];
  final removed = <String>{};

  /// 对话 3 的更新日期；调大它就是那段对话刚做完。
  int session3Day = 9;

  /// 置顶的对话。
  final pinnedIds = <String>{};

  /// 改过标题的对话；没改的叫「对话 + 编号」。
  final titles = <String, String>{};

  void remove(String id) {
    removed.add(id);
    notifyListeners();
  }

  @override
  List<KeptDesktop> get desktops => const [
    KeptDesktop(id: '甲', name: '电脑甲', publicKey: ''),
    KeptDesktop(id: '乙', name: '电脑乙', publicKey: ''),
  ];
  @override
  bool isOnline(String id) => true;
  @override
  DesktopLinkStatus linkStatus(String desktopId) => DesktopLinkStatus.online;
  @override
  List<ProjectRef> get projects => const [
    ProjectRef('甲', ProjectInfo(id: 'p', name: '项目一', path: '/p')),
    ProjectRef('甲', ProjectInfo(id: 'q', name: '项目二', path: '/q')),
    ProjectRef('乙', ProjectInfo(id: 'r', name: '项目三', path: '/r')),
  ];

  SessionRef _s(
    String desktop,
    String id,
    String project,
    int day, [
    LinkSessionStatus status = LinkSessionStatus.idle,
  ]) => SessionRef(
    desktop,
    SessionSummary(
      id: id,
      project: project,
      title: titles[id] ?? '对话$id',
      updatedAt: DateTime(2026, 11, day),
      status: status,
      pinned: pinnedIds.contains(id),
    ),
  );

  @override
  List<SessionRef> get sessions => [
    for (final ref in [
      _s('甲', '1', 'p', 10),
      _s('甲', '2', 'p', 8, LinkSessionStatus.needsInput),
      _s('甲', '3', 'q', session3Day),
      _s('乙', '4', 'r', 5),
    ])
      if (!removed.contains(ref.session.id)) ref,
  ];

  @override
  Future<Object?> request(
    String desktopId,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    calls.add((method, params));
    if (method == LinkMethods.draft) {
      if (draftAnswer case final answer?) return answer.future;
      return {'session': 'draft-${params['project']}'};
    }
    return null;
  }

  /// Set to hold the desktop's answer to a draft until a test gives it.
  Completer<Object?>? draftAnswer;

  @override
  Future<void> openSession(String desktopId, String sessionId) async {}
  final refreshed = <String>[];
  @override
  Future<void> refreshDesktop(String desktopId) async =>
      refreshed.add(desktopId);
  @override
  Future<void> closeSession(String desktopId, String sessionId) async {}
}

Future<_State> _pump(WidgetTester tester) async {
  final state = _State();
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: AnimatedBuilder(
        animation: state,
        builder: (_, _) => HomeShell(state: state),
      ),
    ),
  );
  await tester.pump();
  return state;
}

ChatPage _page(WidgetTester tester) =>
    tester.widget<ChatPage>(find.byType(ChatPage));

Finder _inPanel(String text) =>
    find.descendant(of: find.byType(Drawer), matching: find.text(text));

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-side-panel')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('打开侧边栏收起键盘，关上后输入框不会自己拿回焦点', (tester) async {
    await _pump(tester);
    await tester.pumpAndSettle();
    final input = find.byType(EditableText).first;
    await tester.tap(input);
    await tester.pump();
    expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);

    await _openPanel(tester);
    expect(tester.widget<EditableText>(input).focusNode.hasFocus, isFalse);
    // 点侧边栏外面的遮罩关上它。
    await tester.tapAt(
      Offset(
        tester.view.physicalSize.width / tester.view.devicePixelRatio - 10,
        300,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    expect(tester.widget<EditableText>(input).focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('侧边栏下拉刷新当前电脑，转圈从搜索行下面出来，内容不动', (tester) async {
    final state = await _pump(tester);
    await _openPanel(tester);
    final search = find.descendant(
      of: find.byType(Drawer),
      matching: find.text('搜索项目和对话'),
    );
    final searchBefore = tester.getTopLeft(search);
    final gesture = await tester.startGesture(
      tester.getCenter(_inPanel('对话1')),
    );
    await gesture.moveBy(const Offset(0, 40));
    await gesture.moveBy(const Offset(0, 160));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(search), searchBefore);
    final spinner = find.byType(RefreshProgressIndicator);
    expect(spinner, findsOneWidget);
    expect(
      tester.getTopLeft(spinner).dy,
      greaterThan(tester.getBottomLeft(search).dy),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.refreshed, ['甲']);
  });

  testWidgets('沉浸模式打开就是当前电脑最近的对话，没有底部标签栏', (tester) async {
    await _pump(tester);
    expect(find.byType(FocusShell), findsOneWidget);
    expect(_page(tester).sessionId, '1');
    expect(find.text('Bot'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('对话里按返回先打开侧边栏，侧边栏开着时连按两次才退出应用', (tester) async {
    final exits = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        exits.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    expect(_page(tester).sessionId, '1');
    expect(exits, isNot(contains('SystemNavigator.pop')));

    // 侧边栏开着：第一次只提示，过了两秒提示收起，再按还是只提示。
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('再按一次退出'), findsOneWidget);
    expect(exits, isNot(contains('SystemNavigator.pop')));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('再按一次退出'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(exits, isNot(contains('SystemNavigator.pop')));

    await tester.pump(const Duration(seconds: 1));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(exits, contains('SystemNavigator.pop'));
    expect(find.text('再按一次退出'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('等电脑回新对话时盖住屏幕，连点只建一个，慢了才转圈', (tester) async {
    final state = await _pump(tester);
    final answer = Completer<Object?>();
    state.draftAnswer = answer;
    final loader = find.descendant(
      of: find.byKey(const ValueKey('draft-cover')),
      matching: find.byType(PixelLoader),
    );
    await tester.tap(find.byKey(const ValueKey('chat-new-conversation')));
    await tester.pump();
    expect(find.byKey(const ValueKey('draft-cover')), findsOneWidget);
    expect(loader, findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('chat-new-conversation')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(loader, findsOneWidget);
    expect(state.calls.where((c) => c.$1 == LinkMethods.draft), hasLength(1));

    answer.complete({'session': 'draft-p'});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('draft-cover')), findsNothing);
    expect(_page(tester).sessionId, 'draft-p');
  });

  testWidgets('记住的上次对话优先，但只在当前电脑上才用', (tester) async {
    final state = _State()..settings.lastSession = ('甲', '3');
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: state,
          builder: (_, _) => HomeShell(state: state),
        ),
      ),
    );
    await tester.pump();
    expect(_page(tester).sessionId, '3');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('侧边栏按项目默认展开全部对话，点对话原地切换并记住', (tester) async {
    final state = await _pump(tester);
    await _openPanel(tester);
    for (final id in ['1', '2', '3']) {
      expect(find.byKey(ValueKey('side-session-甲-$id')), findsOneWidget);
    }
    expect(_inPanel('项目三'), findsNothing, reason: '只列当前电脑的项目');
    await tester.tap(find.byKey(const ValueKey('side-session-甲-3')));
    await tester.pumpAndSettle();
    expect(_page(tester).sessionId, '3');
    expect(state.settings.lastSession, ('甲', '3'));
    expect(find.byType(Drawer), findsNothing);
    expect(
      tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
      isFalse,
      reason: '原地切换，不叠新页面',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('置顶的对话自成一组在项目上面，标出项目，不再列在项目里，能折叠', (tester) async {
    final state = _State()..pinnedIds.add('3');
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: state,
          builder: (_, _) => HomeShell(state: state),
        ),
      ),
    );
    await tester.pump();
    await _openPanel(tester);
    final pinnedGroup = find.byKey(const ValueKey('side-group-pinned'));
    final line = find.byKey(const ValueKey('side-session-甲-3'));
    expect(line, findsOneWidget, reason: '同一段对话只出现一次');
    expect(find.descendant(of: pinnedGroup, matching: line), findsOneWidget);
    expect(
      find.descendant(
        of: pinnedGroup,
        matching: find.textContaining('项目二', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('side-pinned-header'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('side-project-甲-p'))).dy,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('side-pinned-header')));
    await tester.pumpAndSettle();
    expect(line, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('置顶对话标题太长时先截标题，项目名完整显示', (tester) async {
    final state = _State()
      ..pinnedIds.add('3')
      ..titles['3'] = '获取最新代码并整理这次改动的说明' * 3;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: state,
          builder: (_, _) => HomeShell(state: state),
        ),
      ),
    );
    await tester.pump();
    await _openPanel(tester);
    final line = find.byKey(const ValueKey('side-session-甲-3'));
    RenderParagraph paragraph(Finder text) => tester.renderObject(
      find.descendant(of: line, matching: text),
    );
    expect(paragraph(find.text('项目二')).didExceedMaxLines, isFalse);
    expect(
      paragraph(find.text(state.titles['3']!)).didExceedMaxLines,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点项目标题折叠它的对话，再点展开', (tester) async {
    await _pump(tester);
    await _openPanel(tester);
    await tester.tap(_inPanel('项目一'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('side-session-甲-1')), findsNothing);
    expect(find.byKey(const ValueKey('side-session-甲-3')), findsOneWidget);
    await tester.tap(_inPanel('项目一'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('side-session-甲-1')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('项目展开时只有对话前的状态点，折叠后项目名旁合成一个同色的点', (tester) async {
    await _pump(tester);
    await _openPanel(tester);
    final error = Theme.of(tester.element(find.byType(Drawer)))
        .colorScheme
        .error;
    Finder dots(Finder of) => find.descendant(
      of: of,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).shape == BoxShape.circle &&
            (widget.decoration! as BoxDecoration).color == error,
      ),
    );
    final header = find.byKey(const ValueKey('side-project-甲-p'));
    expect(dots(header), findsNothing);
    expect(
      dots(find.byKey(const ValueKey('side-session-甲-2'))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byType(Badge)),
      findsNothing,
    );
    await tester.tap(_inPanel('项目一'));
    await tester.pumpAndSettle();
    expect(dots(header), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('项目右边的加号在该项目开新对话，原地打开草稿', (tester) async {
    final state = await _pump(tester);
    await _openPanel(tester);
    await tester.tap(find.byKey(const ValueKey('side-new-甲-q')));
    await tester.pumpAndSettle();
    expect(state.calls.last.$1, LinkMethods.draft);
    expect(state.calls.last.$2, {'project': 'q'});
    expect(_page(tester).sessionId, 'draft-q');
    expect(_page(tester).projectId, 'q');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('对话页右上角新对话在当前项目原地开草稿', (tester) async {
    final state = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('chat-new-conversation')));
    await tester.pumpAndSettle();
    expect(state.calls.last.$1, LinkMethods.draft);
    expect(state.calls.last.$2, {'project': 'p'});
    expect(_page(tester).sessionId, 'draft-p');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切换电脑后侧边栏换成它的项目，并打开它最近的对话', (tester) async {
    final state = await _pump(tester);
    state.selectDesktop('乙');
    await tester.pumpAndSettle();
    expect(_page(tester).sessionId, '4');
    await _openPanel(tester);
    expect(_inPanel('项目三'), findsOneWidget);
    expect(_inPanel('项目一'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('开着的对话被删掉后换到最近的一段', (tester) async {
    final state = await _pump(tester);
    expect(_page(tester).sessionId, '1');
    state.remove('1');
    await tester.pumpAndSettle();
    expect(_page(tester).sessionId, '3');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('打开时自动显示的对话固定住，别的对话做完也不跳过去', (tester) async {
    final state = await _pump(tester);
    expect(_page(tester).sessionId, '1');
    state
      ..session3Day = 12
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(_page(tester).sessionId, '1');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('侧边栏里长按对话没有「放到首页」，其余菜单都在', (tester) async {
    await _pump(tester);
    await _openPanel(tester);
    await tester.longPress(find.byKey(const ValueKey('side-session-甲-2')));
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('归档'), findsOneWidget);
    expect(find.text('放到首页'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('侧边栏里复制会话 ID，提示在最上层，不被侧边栏盖住', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _pump(tester);
    await _openPanel(tester);
    await tester.longPress(find.byKey(const ValueKey('side-session-甲-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制会话 ID'));
    await tester.pump();
    final hint = find.text('已复制');
    expect(hint, findsOneWidget);
    // 在哪个 Scaffold 里都会被侧边栏盖住；最上层的 Overlay 才看得见。
    expect(
      find.ancestor(of: hint, matching: find.byType(Scaffold)),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 4));
    expect(hint, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('侧边栏顶部只有 Bot 和文件入口，打开原有页面', (tester) async {
    await _pump(tester);
    await _openPanel(tester);
    // 新对话在对话页右上角和各项目的加号里，侧边栏顶上不再重复。
    expect(_inPanel('新对话'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('side-files')));
    await tester.pumpAndSettle();
    expect(find.byType(FilesTab), findsOneWidget);
    expect(
      tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('往上滑时入口滚走，项目标题吸在顶上', (tester) async {
    tester.view.physicalSize = const Size(360, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester);
    await _openPanel(tester);
    final list = find.descendant(
      of: find.byType(Drawer),
      matching: find.byType(CustomScrollView),
    );
    final top = tester.getTopLeft(list).dy;
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('side-bots')).hitTestable(),
      findsNothing,
      reason: '入口滚到了标题上面',
    );
    final header = find.byKey(const ValueKey('side-project-甲-p'));
    expect(header, findsOneWidget);
    expect(tester.getTopLeft(header).dy, closeTo(top, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('界面模式和上次对话能存下来再读回', () {
    final settings = AppSettings()
      ..layout = 'focus'
      ..lastSession = ('甲', '1');
    final read = AppSettings.fromJson(settings.toJson());
    expect(read.focusLayout, isTrue);
    expect(read.lastSession, ('甲', '1'));
    expect(AppSettings.fromJson({'layout': '别的'}).layout, 'list');
    expect(AppSettings.fromJson({}).lastSession, isNull);
  });
}
