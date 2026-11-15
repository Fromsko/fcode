import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/chat/message_view.dart';
import 'package:baocode_mobile/chat/widgets/image_deck.dart';
import 'package:baocode_mobile/link/link_store.dart';
import 'package:baocode_mobile/state/app_state.dart';
import 'package:baocode_mobile/ui/bots/group_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const group = LinkGroup(
  id: '群',
  name: '合成群',
  members: ['宝'],
  passes: 8,
  gap: 2,
  rules: '轮流说话',
);
const ref = GroupRef('电脑', group);
const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';

Future<_State> _pumpInfo(WidgetTester tester, {LinkGroup? group}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final state = _State();
  if (group != null) state.current = group;
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: GroupInfoPage(
        state: state,
        desktop: '电脑',
        group: group ?? ref.group,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

class _State extends AppState {
  _State() : super(store: MemoryLinkStore());
  final calls = <(String, Map<String, Object?>)>[];
  bool failSend = false;
  @override
  String tr(String zh, String en) => zh;
  @override
  bool isOnline(String desktop) => true;
  LinkGroup current = group;
  @override
  List<GroupRef> get groups => [GroupRef('电脑', current)];
  @override
  List<BotRef> get bots => const [
    BotRef('电脑', LinkBot(id: '宝', name: '小宝')),
    BotRef('电脑', LinkBot(id: '贝', name: '小贝')),
  ];
  @override
  Future<LinkState> refreshDesktopState(String desktop) async =>
      const LinkState(
        device: DeviceInfo(name: '电脑', kind: 'windows', system: '合成系统'),
        groups: [group],
      );
  @override
  Future<Object?> request(
    String desktop,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    calls.add((method, params));
    switch (method) {
      case LinkMethods.openGroup:
        return {
          'messages': [
            {'seq': 1, 'at': 1000, 'from': 'user', 'text': '群里的问题'},
            {
              'seq': 2,
              'at': 2000,
              'from': '宝',
              'text': '<bot_say ref="1">[whispers] 群里的回复</bot_say>',
              'images': ['合成图.png'],
            },
            {'seq': 3, 'at': 3000, 'from': '@app', 'text': '小宝加入群聊'},
          ],
          'more': true,
        };
      case LinkMethods.earlierGroup:
        return {'messages': [], 'more': false};
      case LinkMethods.groupImage:
        return {'data': png, 'type': 'image/png'};
      case LinkMethods.sendGroup:
        if (failSend) throw TimeoutException('仅合成发送超时');
        return {'seq': 4};
      case LinkMethods.saveGroup:
        final saved = {'id': '群', ...params}..remove('group');
        current = LinkGroup.fromJson(saved);
        return {'group': saved};
      default:
        return null;
    }
  }
}

/// 群图片先读失败，点重试后才给。
class _FailImageState extends _State {
  bool fail = true;

  @override
  Future<Object?> request(
    String desktop,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (method == LinkMethods.groupImage && fail) {
      calls.add((method, params));
      throw TimeoutException('仅合成图片超时');
    }
    return super.request(desktop, method, params);
  }
}

/// 翻页请求挂着不回，看加载中的浮层。
class _EarlierState extends _State {
  final earlier = Completer<void>();
  int earlierCalls = 0;

  @override
  Future<Object?> request(
    String desktop,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (method == LinkMethods.openGroup) {
      return {
        'messages': [
          for (var seq = 51; seq <= 80; seq++)
            {'seq': seq, 'at': seq * 1000, 'from': 'user', 'text': '第$seq条群消息'},
        ],
        'more': true,
      };
    }
    if (method == LinkMethods.earlierGroup) {
      earlierCalls++;
      await earlier.future;
      return {
        'messages': [
          for (var seq = 1; seq <= 50; seq++)
            {'seq': seq, 'at': seq * 1000, 'from': 'user', 'text': '第$seq条群消息'},
        ],
        'more': false,
      };
    }
    return super.request(desktop, method, params);
  }
}

/// 翻页失败：之后继续上滑不再自动请求，只有点浮层上的重试才再试。
class _FailingEarlierState extends _State {
  int earlierCalls = 0;
  bool fail = true;

  @override
  Future<Object?> request(
    String desktop,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (method == LinkMethods.openGroup) {
      return {
        'messages': [
          for (var seq = 51; seq <= 80; seq++)
            {'seq': seq, 'at': seq * 1000, 'from': 'user', 'text': '第$seq条群消息'},
        ],
        'more': true,
      };
    }
    if (method == LinkMethods.earlierGroup) {
      earlierCalls++;
      if (fail) throw TimeoutException('仅合成翻页超时');
      return {
        'messages': [
          for (var seq = 1; seq <= 50; seq++)
            {'seq': seq, 'at': seq * 1000, 'from': 'user', 'text': '第$seq条群消息'},
        ],
        'more': false,
      };
    }
    return super.request(desktop, method, params);
  }
}

class _ScrollState extends _State {
  @override
  Future<Object?> request(
    String desktop,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (method == LinkMethods.openGroup || method == LinkMethods.earlierGroup) {
      final first = method == LinkMethods.openGroup ? 51 : 1;
      final last = method == LinkMethods.openGroup ? 80 : 50;
      return {
        'messages': [
          for (var seq = first; seq <= last; seq++)
            {'seq': seq, 'at': seq * 1000, 'from': 'user', 'text': '第$seq条群消息'},
        ],
        'more': method == LinkMethods.openGroup,
      };
    }
    return super.request(desktop, method, params);
  }
}

/// 长短不一的消息：边滚边排版时列表的总长估计会变。
class _MixedState extends _State {
  @override
  Future<Object?> request(
    String desktop,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (method == LinkMethods.openGroup) {
      return {
        'messages': [
          for (var seq = 1; seq <= 60; seq++)
            {
              'seq': seq,
              'at': seq * 1000,
              'from': 'user',
              'text': seq % 3 == 0 ? '长消息$seq ' * 40 : '第$seq条',
            },
        ],
        'more': false,
      };
    }
    return super.request(desktop, method, params);
  }
}

void main() {
  testWidgets('手指往上拖时不被拉回底部', (tester) async {
    final state = _MixedState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('group-history'));
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position.extentAfter, closeTo(0, 1));
    final gesture = await tester.startGesture(tester.getCenter(list));
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    expect(position.extentAfter, greaterThan(800));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.extentAfter, greaterThan(800));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('群新消息跟随底部，阅读旧消息不抢滚动，翻页保留位置', (tester) async {
    final state = _ScrollState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('group-history'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.extentAfter, closeTo(0, 1));
    void incoming(int seq) => state.groupChats.accept('电脑', {
      'group': '群',
      'messages': [
        {'seq': seq, 'at': seq * 1000, 'from': 'user', 'text': '第$seq条群消息'},
      ],
    });
    incoming(81);
    await tester.pumpAndSettle();
    expect(position.extentAfter, closeTo(0, 1));
    await tester.drag(list, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(position.extentAfter, greaterThan(100));
    final pixels = position.pixels;
    incoming(82);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(pixels, 1));
    position.jumpTo(0);
    await tester.pumpAndSettle();
    await state.groupChats.earlier('电脑', '群');
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    // 到头了不再在顶上留一行提示。
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('没有更早消息'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('上滑到顶自动取更早消息：显示加载中，回来浮层消失，到头不留提示', (tester) async {
    final state = _EarlierState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('group-history'));
    expect(find.text('更早消息'), findsNothing);
    expect(state.earlierCalls, 0);

    await tester.drag(list, const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(state.earlierCalls, 1);
    expect(find.text('加载中…'), findsOneWidget);

    // 加载中再滑一次也不重复请求。
    await tester.drag(list, const Offset(0, 50));
    await tester.pumpAndSettle();
    expect(state.earlierCalls, 1);

    state.earlier.complete();
    await tester.pumpAndSettle();
    expect(find.text('加载中…'), findsNothing);
    final buffer = state.groupChats.buffer('电脑', '群');
    expect(buffer.messages.length, 80);
    expect(buffer.more, isFalse);

    // 已经到头：滑到最前也不请求，不出现「没有更早消息」。
    await tester.drag(list, const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(find.textContaining('第1条群消息'), findsWidgets);
    expect(state.earlierCalls, 1);
    expect(find.text('没有更早消息'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('群翻页失败后继续上滑不再自动请求，点重试才重试', (tester) async {
    final state = _FailingEarlierState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('group-history'));
    await tester.drag(list, const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(state.earlierCalls, 1);
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('更早的群消息未加载'), findsOneWidget);

    // 失败后再上滑：停在错误上，不自动重试。
    await tester.drag(list, const Offset(0, 10000));
    await tester.pumpAndSettle();
    await tester.drag(list, const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(state.earlierCalls, 1);

    state.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(state.earlierCalls, 2);
    expect(find.text('重试'), findsNothing);
    final buffer = state.groupChats.buffer('电脑', '群');
    expect(buffer.messages.length, 80);
    expect(buffer.more, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('群图片缓存后重进页面不再请求，加载时占住图片高度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = _State();
    addTearDown(state.dispose);
    int imageCalls() =>
        state.calls.where((call) => call.$1 == LinkMethods.groupImage).length;
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    // 第一帧还在取图：占位和 ImageDeck 差不多高，不跳。
    await tester.pump();
    final placeholder = find.byKey(const ValueKey('group-image-placeholder'));
    if (placeholder.evaluate().isNotEmpty) {
      expect(tester.getSize(placeholder).height, greaterThan(100));
    }
    await tester.pumpAndSettle();
    expect(find.byType(ImageDeck), findsOneWidget);
    expect(imageCalls(), 1);
    final height = tester.getSize(find.byType(ImageDeck)).height;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pump();
    // 重进时图片已经在内存里，同步画出来，高度和之前一样。
    expect(find.byType(ImageDeck), findsOneWidget);
    expect(find.byKey(const ValueKey('group-image-placeholder')), findsNothing);
    expect(tester.getSize(find.byType(ImageDeck)).height, height);
    await tester.pumpAndSettle();
    expect(imageCalls(), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('别的会话变了不重画整页，群消息变了才重画', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    final element = tester.element(find.byKey(const ValueKey('group-history')));
    final title = tester.element(find.text('合成群（2）'));

    // 别处（会话、别的电脑）只 notify：这一页保持原样。
    state.notifyListeners();
    await tester.pump();
    expect(
      identical(
        tester.element(find.byKey(const ValueKey('group-history'))),
        element,
      ),
      isTrue,
    );
    expect(identical(tester.element(find.text('合成群（2）')), title), isTrue);

    // 群里有新消息：重画，并显示出来。
    state.groupChats.accept('电脑', {
      'group': '群',
      'messages': [
        {'seq': 9, 'at': 9000, 'from': 'user', 'text': '群里的新消息'},
      ],
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('群里的新消息'), findsWidgets);
    expect(
      tester
          .widget<ListView>(find.byKey(const ValueKey('group-history')))
          .semanticChildCount,
      4,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('群图片读取失败仍可点按钮重试', (tester) async {
    final state = _FailImageState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ImageDeck), findsNothing);
    expect(find.text('电脑没有及时回应，请检查网络后重试。'), findsOneWidget);
    state.fail = false;
    await tester.tap(find.text('电脑没有及时回应，请检查网络后重试。'));
    await tester.pumpAndSettle();
    expect(find.byType(ImageDeck), findsOneWidget);
    expect(
      state.calls.where((call) => call.$1 == LinkMethods.groupImage),
      hasLength(2),
    );
    // 取到之后缓存里有了：再画一次不再请求。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ImageDeck), findsOneWidget);
    expect(
      state.calls.where((call) => call.$1 == LinkMethods.groupImage),
      hasLength(2),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<_State> pumpChat(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('群消息复用气泡、图片与引用，系统行不当Bot消息，关页面退订', (tester) async {
    final state = await pumpChat(tester);
    expect(find.text('合成群（2）'), findsOneWidget);
    expect(find.textContaining('群里的回复'), findsWidgets);
    expect(find.textContaining('[whispers]'), findsNothing);
    expect(find.text('小宝加入群聊'), findsOneWidget);
    expect(find.byType(ImageDeck), findsOneWidget);
    expect(
      state.calls.where((call) => call.$1 == LinkMethods.groupImage).single.$2,
      {'group': '群', 'image': '合成图.png'},
    );
    expect(find.byKey(const ValueKey('bot-user-bubble')), findsOneWidget);
    expect(find.byKey(const ValueKey('bot-answer-bubble')), findsOneWidget);
    final botBubble = find.byKey(const ValueKey('bot-answer-bubble'));
    expect(
      tester.getTopLeft(find.text('小宝')).dy,
      lessThan(tester.getTopLeft(botBubble).dy),
    );
    expect(find.text('我: 群里的问题'), findsOneWidget);
    final divider = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<(String, int)> &&
          (widget.key! as ValueKey<(String, int)>).value.$1 == 'group-divider',
    );
    expect(divider, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(
      state.calls.where((call) => call.$1 == LinkMethods.closeGroup),
      hasLength(1),
    );
  });

  testWidgets('长按 AI 的气泡弹出复制和引用，不弹系统选字', (tester) async {
    await pumpChat(tester);
    await tester.longPress(find.byKey(const ValueKey('bot-answer-bubble')));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消引用'), findsOneWidget);
  });

  testWidgets('@选成员插入名字，引用可取消再选，发送带引用和去重id', (tester) async {
    final state = await pumpChat(tester);
    await tester.longPress(find.byKey(const ValueKey('bot-user-bubble')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(find.text('我: 群里的问题'), findsWidgets);
    final composer = find.byKey(const ValueKey('group-composer'));
    await tester.enterText(composer, '你好');
    await tester.pump();
    await tester.enterText(composer, '你好@');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey(('group-mention', '宝'))));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, '你好@小宝 ');
    await tester.enterText(composer, '你好@小宝 确定修改');
    await tester.pump();
    await tester.tap(find.byTooltip('取消引用'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消引用'), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('bot-user-bubble')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final sent = state.calls
        .singleWhere((call) => call.$1 == LinkMethods.sendGroup)
        .$2;
    expect(sent['text'], '你好@小宝 确定修改');
    expect(sent['ref'], 1);
    expect(sent['id'], isA<String>());
    expect((sent['id'] as String).length, greaterThan(16));
    expect(sent.containsKey('suggest'), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('粘贴一次插入多个字符里的@不弹成员列表', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('group-composer')), 'a@b');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(('group-mention', '宝'))), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('群成员正在输入时，末尾出现带名字的输入气泡', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = _State()
      ..current = const LinkGroup(
        id: '群',
        name: '合成群',
        members: ['宝'],
        typing: ['宝'],
      );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(BotTypingBubble), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(BotTypingBubble),
        matching: find.text('小宝'),
      ),
      findsOneWidget,
    );
    final dots = find.descendant(
      of: find.byType(BotTypingBubble),
      matching: find.byType(Opacity),
    );
    expect(dots, findsNWidgets(3));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('群加号面板只有相册和拍摄，点输入框回到键盘', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    final plus = find.byTooltip('添加附件');
    final field = find.byKey(const ValueKey('group-composer'));

    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(plus);
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('chat-actions'));
    expect(panel, findsOneWidget);
    expect(find.byKey(const ValueKey('chat-action-album')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-action-camera')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-action-upload')), findsNothing);
    expect(find.byKey(const ValueKey('chat-action-file')), findsNothing);

    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('加号面板开着时返回先收起面板，再按才离开', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => GroupChatPage(state: state, ref: ref),
                  ),
                ),
                child: const Text('打开群聊'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开群聊'));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('chat-actions'));
    expect(panel, findsNothing);

    await tester.tap(find.byTooltip('添加附件'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);

    // 返回：面板收起，页面还在。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(find.byKey(const ValueKey('group-composer')), findsOneWidget);

    // 再返回：这才离开。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-composer')), findsNothing);
    expect(find.text('打开群聊'), findsOneWidget);
  });

  testWidgets('群发送超时保留草稿，不自动重放，显式重试保留同一去重id', (tester) async {
    final state = _State()..failSend = true;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: GroupChatPage(state: state, ref: ref),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('group-composer')),
      '合成待确认内容',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final first = state.calls
        .singleWhere((call) => call.$1 == LinkMethods.sendGroup)
        .$2;
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('group-composer')))
          .controller!
          .text,
      '合成待确认内容',
    );
    expect(find.textContaining('发送未确认'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(
      state.calls.where((call) => call.$1 == LinkMethods.sendGroup),
      hasLength(1),
    );
    state.failSend = false;
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final sent = state.calls
        .where((call) => call.$1 == LinkMethods.sendGroup)
        .last
        .$2;
    expect(sent['id'], first['id']);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('group-composer')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('聊天信息页列出成员与群设置，群规未设置时说明', (tester) async {
    final state = await _pumpInfo(tester);
    expect(find.text('群成员 (1)'), findsOneWidget);
    expect(find.text('小宝'), findsOneWidget);
    expect(find.text('群聊名称'), findsOneWidget);
    expect(find.text('群规'), findsOneWidget);
    expect(find.text('轮流说话'), findsOneWidget);
    expect(find.text('最多传话次数'), findsOneWidget);
    expect(find.text('8 次'), findsOneWidget);
    expect(find.text('回复间隔'), findsOneWidget);
    expect(find.text('2 秒'), findsOneWidget);
    expect(find.text('删除群聊'), findsOneWidget);
    const bare = LinkGroup(id: '群', name: '', members: ['宝'], passes: 8);
    state.current = bare;
    await tester.pumpWidget(
      MaterialApp(
        home: GroupInfoPage(state: state, desktop: '电脑', group: bare),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未设置'), findsOneWidget);
    expect(find.text('立即'), findsOneWidget);
  });

  testWidgets('选择传话次数后立即整份保存', (tester) async {
    final state = await _pumpInfo(tester);
    await tester.tap(find.text('最多传话次数'));
    await tester.pumpAndSettle();
    expect(find.text('不限'), findsOneWidget);
    await tester.tap(find.text('10 次'));
    await tester.pumpAndSettle();
    final saved = state.calls
        .singleWhere((call) => call.$1 == LinkMethods.saveGroup)
        .$2;
    expect(saved, {
      'group': '群',
      'name': '合成群',
      'members': ['宝'],
      'passes': 10,
      'rules': '轮流说话',
      'gap': 2,
    });
    expect(find.text('10 次'), findsOneWidget);
  });

  testWidgets('自定义回复间隔走对话框并保存秒数', (tester) async {
    final state = await _pumpInfo(tester);
    await tester.tap(find.text('回复间隔'));
    await tester.pumpAndSettle();
    expect(find.text('自定义'), findsOneWidget);
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '45');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    final saved = state.calls
        .singleWhere((call) => call.$1 == LinkMethods.saveGroup)
        .$2;
    expect(saved['gap'], 45);
    expect(find.text('45 秒'), findsOneWidget);
  });

  testWidgets('发起群聊至少选两个 Bot 才能完成', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => startGroupChat(context, state, '电脑'),
                child: const Text('开始'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.text('发起群聊'), findsOneWidget);
    final done = find.text('完成');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '完成'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('小宝'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '完成'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('小贝'));
    await tester.pumpAndSettle();
    await tester.tap(done);
    await tester.pumpAndSettle();
    final saved = state.calls
        .singleWhere((call) => call.$1 == LinkMethods.saveGroup)
        .$2;
    expect(saved['members'], ['宝', '贝']);
    expect(saved['passes'], 8);
    expect(find.textContaining('群里的问题'), findsWidgets);
  });
}
