import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/chat/chat_models.dart';
import 'package:baocode_mobile/chat/message_view.dart';
import 'package:baocode_mobile/chat/widgets/image_deck.dart';
import 'package:baocode_mobile/link/link_store.dart';
import 'package:baocode_mobile/state/app_state.dart';
import 'package:baocode_mobile/ui/tasks/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _bot = BotRef('电脑', LinkBot(id: '宝', name: '小宝', session: '会话'));

class _State extends AppState {
  _State() : super(store: MemoryLinkStore());
  final history = SessionBuffer('电脑', '会话')..earlier = false;
  final calls = <String>[];
  final sent = <Map<String, Object?>>[];
  @override
  String tr(String zh, String en) => zh;
  @override
  bool isOnline(String desktop) => true;
  @override
  List<BotRef> get bots => [_bot];
  @override
  SessionBuffer buffer(String desktop, String session) => history;
  @override
  Future<void> openSession(String desktop, String session) async {}
  @override
  Future<void> closeSession(String desktop, String session) async {}
  @override
  Future<Object?> request(
    String desktop,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    calls.add(method);
    if (method == LinkMethods.send) sent.add(params);
    return {'session': '会话'};
  }

  void publish() {
    history.revision++;
    notifyListeners();
  }
}

void main() {
  testWidgets('Bot引用气泡和旁白隐藏语气，普通智能体与用户保留语气', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageView(
                state: state,
                desktopId: '电脑',
                bot: _bot,
                item: const AssistantTextItem(
                  '<bot_say ref="74">[whispers] 你好呀</bot_say><bot_narrate>[laughs] 点头</bot_narrate><bot_suggest>继续</bot_suggest>',
                ),
              ),
              MessageView(
                state: state,
                desktopId: '电脑',
                bot: _bot,
                item: const UserMessageItem(text: '用户 [laughs]'),
              ),
              MessageView(
                state: state,
                desktopId: '电脑',
                item: const AssistantTextItem('智能体 [laughs]'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.textContaining('你好呀'), findsWidgets);
    expect(find.textContaining('[whispers]'), findsNothing);
    expect(find.textContaining('用户 [laughs]'), findsOneWidget);
    expect(find.textContaining('智能体 [laughs]'), findsWidgets);
    expect(find.text('继续'), findsNothing);
  });

  testWidgets('仅图bot_send显示图片，失败的发送不展示成功气泡', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageView(
                state: state,
                desktopId: '电脑',
                bot: _bot,
                item: {
                  't': 'tool',
                  'tool': 'bot_send',
                  'status': 'succeeded',
                  'sent': '',
                  'images': [
                    {'data': base64Encode(png), 'type': 'image/png'},
                  ],
                },
              ),
              MessageView(
                state: state,
                desktopId: '电脑',
                bot: _bot,
                item: {
                  't': 'tool',
                  'tool': 'bot_send',
                  'status': 'failed',
                  'sent': '失败内容',
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ImageDeck), findsOneWidget);
    expect(find.textContaining('失败内容'), findsNothing);
    expect(find.byKey(const ValueKey('bot-answer-bubble')), findsNothing);
  });

  testWidgets('推荐点一下直接发送、长按只填输入框', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    state.settings.botSuggestions.add(('电脑', '宝'));
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          state: state,
          desktopId: '电脑',
          sessionId: '会话',
          botId: '宝',
          title: '小宝',
        ),
      ),
    );
    await tester.pumpAndSettle();
    state.history.items.addAll([
      {'t': 'user', 'text': '第一轮'},
      {
        't': 'text',
        'text': '<bot_say>你好</bot_say><bot_suggest>继续说说</bot_suggest><bot_suggest>换个角度</bot_suggest>',
      },
    ]);
    state.publish();
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey(('bot-suggestion', '继续说说')));
    expect(first, findsOneWidget);
    await tester.longPress(first);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '继续说说',
    );
    expect(state.sent, isEmpty);
    expect(first, findsNothing);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump();
    expect(first, findsNothing);
    state.history.items.addAll([
      {'t': 'user', 'text': '第二轮'},
      {'t': 'text', 'text': '<bot_suggest>先总结</bot_suggest>'},
    ]);
    state.publish();
    await tester.pumpAndSettle();
    final next = find.byKey(const ValueKey(('bot-suggestion', '先总结')));
    expect(next, findsOneWidget);
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(state.sent, hasLength(1));
    expect(state.sent.single['text'], '先总结');
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      isEmpty,
    );
    expect(next, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('草稿里有附件时不显示推荐，点推荐不会带走附件', (tester) async {
    const channel = MethodChannel('local.baocode.mobile/platform');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'pickUploadFile') {
        return {'name': '合成.pdf', 'bytes': Uint8List.fromList([1, 2, 3])};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final state = _State();
    addTearDown(state.dispose);
    state.settings.botSuggestions.add(('电脑', '宝'));
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          state: state,
          desktopId: '电脑',
          sessionId: '会话',
          botId: '宝',
          title: '小宝',
        ),
      ),
    );
    await tester.pumpAndSettle();
    state.history.items.addAll([
      {'t': 'user', 'text': '第一轮'},
      {'t': 'text', 'text': '<bot_suggest>继续说说</bot_suggest>'},
    ]);
    state.publish();
    await tester.pumpAndSettle();
    final chip = find.byKey(const ValueKey(('bot-suggestion', '继续说说')));
    expect(chip, findsOneWidget);
    await tester.tap(find.byTooltip('添加附件'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-upload')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('file-attachment')), findsOneWidget);
    expect(chip, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('群回合最后的私信不改变审批目标和计划的归属', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    state.history.items.addAll([
      {'t': 'user', 'text': '<bao-event>[group group-a] 群里的问题</bao-event>'},
      {'t': 'plan', 'path': '/合成计划.md', 'status': 'awaiting'},
      {
        't': 'tool',
        'tool': 'bot_send',
        'status': 'succeeded',
        'sent': '单独给你的私信',
      },
    ]);
    state.history.goal = {'condition': '群目标不可进私聊'};
    state.history.interaction = {
      'id': '群审批',
      't': 'question',
      'questions': [
        {
          'prompt': '群审批不可进私聊',
          'options': [
            {'label': '确认'},
          ],
        },
      ],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          state: state,
          desktopId: '电脑',
          sessionId: '会话',
          botId: '宝',
          title: '小宝',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('单独给你的私信'), findsWidgets);
    expect(find.text('群目标不可进私聊'), findsNothing);
    expect(find.text('群审批不可进私聊'), findsNothing);
    expect(find.text('开始执行计划'), findsNothing);
    state.history.items.addAll([
      {'t': 'user', 'text': '现在是私聊问题'},
      {'t': 'plan', 'path': '/合成私聊计划.md', 'status': 'awaiting'},
    ]);
    state.history.goal = {'condition': '私聊目标可见'};
    state.history.interaction = {
      'id': '私聊审批',
      't': 'question',
      'questions': [
        {
          'prompt': '私聊审批可见',
          'options': [
            {'label': '确认'},
          ],
        },
      ],
    };
    state.publish();
    await tester.pumpAndSettle();
    expect(find.text('私聊目标可见'), findsOneWidget);
    expect(find.text('私聊审批可见'), findsOneWidget);
    expect(find.text('开始执行计划'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('截断群窗口不泄漏，提示可恢复更早上下文', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    state.history.earlier = true;
    state.history.items.add({
      't': 'text',
      'text': '<bot_say>未知归属不能显示</bot_say>',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          state: state,
          desktopId: '电脑',
          sessionId: '会话',
          botId: '宝',
          title: '小宝',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('未知归属不能显示'), findsNothing);
    expect(find.byKey(const ValueKey('bot-history-context')), findsOneWidget);
    state.history.prepend({
      'items': [
        {'t': 'user', 'text': '此前的私聊问题'},
      ],
      'earlier': false,
    });
    state.publish();
    await tester.pumpAndSettle();
    expect(find.textContaining('未知归属不能显示'), findsWidgets);
    expect(find.byKey(const ValueKey('bot-history-context')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
