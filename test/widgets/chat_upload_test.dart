import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:fromsko_mobile/chat/message_view.dart';
import 'package:fromsko_mobile/state/conversation_input.dart';
import 'package:fromsko_mobile/state/app_state.dart' show BotRef;
import 'package:fromsko_mobile/state/upload_file.dart';
import 'package:fromsko_mobile/ui/tasks/chat_composer_action.dart';
import 'package:fromsko_mobile/ui/tasks/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_page_harness.dart';

const _path = '/srv/合成上传/合成 文档.pdf';
const _channel = MethodChannel('local.fromsko.mobile/platform');
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

class _BotState extends ChineseChatPageState {
  String session = 'session';
  @override
  List<BotRef> get bots => [
    BotRef('desktop', LinkBot(id: '合成Bot', name: '合成助手', session: session)),
  ];
}

void main() {
  testWidgets('历史独立文件引用显示文件名，不吞正文路径或代码', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      messageHost(state, {
        't': 'user',
        'text': '请看正文 @/tmp/a-other\n\n@"/电脑/中文 文件.pdf"',
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('中文 文件.pdf'), findsOneWidget);
    expect(find.textContaining('请看正文 @/tmp/a-other'), findsOneWidget);
    expect(find.textContaining('3 B'), findsNothing);
    expect(find.text('PDF'), findsOneWidget);
    state.answers[LinkMethods.read] = (_) => {'text': '合成内容'};
    await tester.tap(find.byKey(const ValueKey('file-attachment')));
    await tester.pumpAndSettle();
    expect(
      state.calls.where((call) => call.$1 == LinkMethods.read).first.$2['path'],
      '/电脑/中文 文件.pdf',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Bot 聊天里文件自成一条，不进绿气泡', (tester) async {
    final state = _BotState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageView(
              state: state,
              desktopId: 'desktop',
              item: const {'t': 'user', 'text': '看这个\n\n@"/电脑/中文 文件.pdf"'},
              bot: state.bots.single,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bubble = find.byKey(const ValueKey('bot-user-bubble'));
    expect(
      find.descendant(of: bubble, matching: find.text('看这个')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bubble,
        matching: find.byKey(const ValueKey('file-attachment')),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey(('bot-user-file', '/电脑/中文 文件.pdf'))),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'pickUploadFile') {
            return {
              'name': '合成 文档.pdf',
              'bytes': Uint8List.fromList([1, 2, 3]),
            };
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  String text(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  Future<void> pick(WidgetTester tester) async {
    await tester.tap(find.byTooltip('添加附件'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-upload')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final queued in [false, true]) {
    testWidgets('修改上传路径后${queued ? '本地排队' : '普通发送'}不带前缀相撞的旧mentions', (
      tester,
    ) async {
      final state = ChineseChatPageState();
      addTearDown(state.dispose);
      state.history.live = queued;
      await state.saveInputDraft(
        'desktop',
        'session',
        const InputDraft(text: '请看 @/tmp/a', mentions: {'/tmp/a'}),
      );
      await tester.pumpWidget(chatHost(state));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '请看 @/tmp/a-other.');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      if (queued) {
        expect(
          state.localQueue.messages('desktop', 'session').single.mentions,
          isEmpty,
        );
      } else {
        final send = state.calls
            .singleWhere((e) => e.$1 == LinkMethods.send)
            .$2;
        expect(send['mentions'], isEmpty);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('编辑历史句末标点路径时恢复精确mentions，改为前缀相撞路径后不再发送旧引用', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    state.history.items.add({'t': 'user', 'text': '旧消息 @/tmp/a.'});
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑并重新发送'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '改读 @/tmp/a-other.');
    await tester.pump();
    await tester.tap(find.byTooltip('重新发送'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '丢弃并发送'));
    await tester.pumpAndSettle();
    final edit = state.calls.singleWhere((e) => e.$1 == LinkMethods.edit).$2;
    expect(edit['mentions'], isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取消选普通文件不改文字图片和mentions草稿、不上传', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    final draft = InputDraft(
      text: '原文字 @/tmp/example.log',
      images: [DraftImage('合成图片.png', 'image/png', _png)],
      mentions: {'/tmp/example.log'},
    );
    await state.saveInputDraft('desktop', 'session', draft);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => null);
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await pick(tester);
    expect(text(tester), draft.text);
    expect(state.inputDraft('desktop', 'session').mentions, draft.mentions);
    expect(find.byKey(const ValueKey('draft-image-remove')), findsOneWidget);
    expect(state.calls.where((e) => e.$1 == LinkMethods.upload), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('上传进入现有草稿后再发送，图片与引用同时保留', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    state.answers[LinkMethods.upload] = (_) => {'path': _path};
    await state.saveInputDraft(
      'desktop',
      'session',
      InputDraft(
        text: '请检查文档',
        images: [DraftImage('合成图.png', 'image/png', _png)],
      ),
    );
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await pick(tester);
    expect(text(tester), '请检查文档');
    expect(find.text('合成 文档.pdf'), findsOneWidget);
    expect(find.byTooltip('移除文件'), findsOneWidget);
    expect(state.calls.where((e) => e.$1 == LinkMethods.send), isEmpty);
    expect(state.inputDraft('desktop', 'session').files.single.path, _path);
    expect(state.inputDraft('desktop', 'session').mentions, isEmpty);
    expect(state.inputDraft('desktop', 'session').images, hasLength(1));
    final upload = state.calls.singleWhere((e) => e.$1 == LinkMethods.upload);
    expect(upload.$2, {
      'project': 'project',
      'name': '合成 文档.pdf',
      'data': 'AQID',
    });
    // 先离开再打开：引用与图片走原来的 InputDraft，而非临时附件列表。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    expect(text(tester), isNot(contains(_path)));
    expect(find.text('合成 文档.pdf'), findsOneWidget);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final send = state.calls.singleWhere((e) => e.$1 == LinkMethods.send).$2;
    expect(send['mentions'], [_path]);
    expect(send['images'], hasLength(1));
    expect(text(tester), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('上传中禁重复选择发送，原文字图片不清空', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    final uploaded = Completer<Object?>();
    state.answers[LinkMethods.upload] = (_) => uploaded.future;
    await state.saveInputDraft(
      'desktop',
      'session',
      InputDraft(
        text: '原草稿',
        images: [DraftImage('合成图.png', 'image/png', _png)],
      ),
    );
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await pick(tester);
    expect(find.byKey(const ValueKey('file-upload-progress')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '添加附件',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(state.calls.where((e) => e.$1 == LinkMethods.send), isEmpty);
    expect(text(tester), '原草稿');
    expect(find.byKey(const ValueKey('draft-image-remove')), findsOneWidget);
    // 上传期间仍可编辑文字，完成时不能覆盖新文字。
    await tester.enterText(find.byType(TextField).first, '上传期间的新文字');
    uploaded.complete({'path': _path});
    await tester.pumpAndSettle();
    expect(text(tester), '上传期间的新文字');
    expect(find.text('合成 文档.pdf'), findsOneWidget);
    expect(state.calls.where((e) => e.$1 == LinkMethods.upload), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('明确unknown和超时不自动重试、不清草稿、不宣称成功', (tester) async {
    for (final error in [
      const LinkRemoteException(LinkErrors.unknown, '敏感路径不得回显'),
      TimeoutException('敏感令牌不得回显'),
    ]) {
      final state = ChineseChatPageState();
      addTearDown(state.dispose);
      state.answers[LinkMethods.upload] = (_) => throw error;
      await tester.pumpWidget(chatHost(state));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '不要丢失草稿');
      await pick(tester);
      expect(text(tester), '不要丢失草稿');
      expect(
        find.textContaining(
          error is LinkRemoteException ? '此电脑不支持文件上传，请更新' : '上传未确认',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('敏感'), findsNothing);
      await tester.pump(const Duration(seconds: 20));
      expect(
        state.calls.where((e) => e.$1 == LinkMethods.upload),
        hasLength(1),
      );
      expect(state.calls.where((e) => e.$1 == LinkMethods.send), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('Bot上传使用bot参数且会话切换时迟到结果不进入草稿', (tester) async {
    final state = _BotState();
    addTearDown(state.dispose);
    final uploaded = Completer<Object?>();
    state.answers[LinkMethods.upload] = (_) => uploaded.future;
    await tester.pumpWidget(chatHost(state, bot: '合成Bot'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '私聊草稿');
    await pick(tester);
    final params = state.calls
        .singleWhere((e) => e.$1 == LinkMethods.upload)
        .$2;
    expect(params['bot'], '合成Bot');
    expect(params.containsKey('project'), isFalse);
    state.session = '新合成会话';
    state.update();
    await tester.pumpAndSettle();
    uploaded.complete({'path': _path});
    await tester.pumpAndSettle();
    expect(text(tester), '私聊草稿');
    expect(state.inputDraft('desktop', 'bot:合成Bot').mentions, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('页面同位换电脑或会话以及销毁后上传返回均不串场', (tester) async {
    for (final change in ['电脑', '会话', '销毁']) {
      final state = ChineseChatPageState();
      addTearDown(state.dispose);
      final uploaded = Completer<Object?>();
      state.answers[LinkMethods.upload] = (_) => uploaded.future;
      await tester.pumpWidget(chatHost(state));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '旧草稿');
      await pick(tester);
      await tester.pumpWidget(
        change == '销毁'
            ? const SizedBox.shrink()
            : MaterialApp(
                home: ChatPage(
                  state: state,
                  desktopId: change == '电脑' ? '另一台合成电脑' : 'desktop',
                  sessionId: change == '会话' ? '另一段合成会话' : 'session',
                  projectId: 'project',
                  title: '合成对话',
                ),
              ),
      );
      uploaded.complete({'path': _path});
      await tester.pumpAndSettle();
      if (change != '销毁') expect(text(tester), isNot(contains(_path)));
      expect(state.inputDraft('desktop', 'session').mentions, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('排队及撤回编辑保留已上传文件引用和图片，不再上传', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    state.history.live = true;
    state.answers[LinkMethods.upload] = (_) => {'path': _path};
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '请读附件');
    await pick(tester);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(state.calls.where((e) => e.$1 == LinkMethods.send), isEmpty);
    expect(state.localQueue.messages('desktop', 'session').single.mentions, [
      _path,
    ]);
    await tester.tap(find.byTooltip('重新编辑'));
    await tester.pumpAndSettle();
    expect(text(tester), isNot(contains(_path)));
    expect(find.text('合成 文档.pdf'), findsOneWidget);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(state.localQueue.messages('desktop', 'session').single.mentions, [
      _path,
    ]);
    expect(state.calls.where((e) => e.$1 == LinkMethods.upload), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('选择器未返回时切换会话取消后续上传，原草稿保留', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    final selected = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) => selected.future);
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '原选择草稿');
    await pick(tester);
    await tester.pumpWidget(chatHost(state, session: '新合成会话'));
    await tester.pumpAndSettle();
    selected.complete({'name': '合成文件', 'bytes': Uint8List(0)});
    await tester.pumpAndSettle();
    expect(state.calls.where((e) => e.$1 == LinkMethods.upload), isEmpty);
    expect(text(tester), isEmpty);
    expect(state.inputDraft('desktop', 'session').text, '原选择草稿');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Bot成功上传引用原样进入草稿，用户发送才调用send', (tester) async {
    final state = _BotState();
    addTearDown(state.dispose);
    const path = r'C:\合成目录\合成 文件.log';
    state.answers[LinkMethods.upload] = (_) => {'path': path};
    await tester.pumpWidget(chatHost(state, bot: '合成Bot'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '私聊读附件');
    await pick(tester);
    expect(state.inputDraft('desktop', 'bot:合成Bot').files.single.path, path);
    expect(text(tester), '私聊读附件');
    expect(state.calls.where((e) => e.$1 == LinkMethods.send), isEmpty);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final send = state.calls.singleWhere((e) => e.$1 == LinkMethods.send).$2;
    expect(send['bot'], '合成Bot');
    expect(send['mentions'], [path]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tooLarge和缺失path不插引用、不清草稿', (tester) async {
    for (final response in <Object>[
      {'tooLarge': true},
      {},
    ]) {
      final state = ChineseChatPageState();
      addTearDown(state.dispose);
      state.answers[LinkMethods.upload] = (_) => response;
      await tester.pumpWidget(chatHost(state));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '必须保留草稿');
      await pick(tester);
      expect(text(tester), '必须保留草稿');
      expect(state.inputDraft('desktop', 'session').mentions, isEmpty);
      expect(
        find.textContaining(
          (response as Map)['tooLarge'] == true ? '8 MiB' : '上传未确认',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('发送期间保留的新草稿不会丢失带引号的已上传引用', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    state.answers[LinkMethods.upload] = (_) => {'path': _path};
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await pick(tester);
    state.sending = Completer<void>();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField).first,
      '更新文字 ${fileMentionText(_path)}',
    );
    state.sending!.complete();
    await tester.pumpAndSettle();
    expect(state.inputDraft('desktop', 'session').mentions, {_path});
    expect(text(tester), startsWith('更新文字'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('编辑历史绝对路径引用再上传可重新发送，原有草稿不丢失', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    const original = '/tmp/original.log';
    state.history.items.add({
      't': 'user',
      'text': '旧消息 ${fileMentionText(original)}',
    });
    state.answers[LinkMethods.upload] = (_) => {'path': _path};
    await state.saveInputDraft(
      'desktop',
      'session',
      const InputDraft(text: '编辑前草稿'),
    );
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑并重新发送'));
    await tester.pumpAndSettle();
    await pick(tester);
    expect(text(tester), contains(fileMentionText(original)));
    expect(text(tester), isNot(contains(_path)));
    expect(find.text('合成 文档.pdf'), findsOneWidget);
    await tester.tap(find.byTooltip('重新发送'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '丢弃并发送'));
    await tester.pumpAndSettle();
    final edit = state.calls.singleWhere((e) => e.$1 == LinkMethods.edit).$2;
    expect(edit['mentions'], [original, _path]);
    expect(text(tester), '编辑前草稿');
    expect(state.inputDraft('desktop', 'session').text, '编辑前草稿');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('上传成功只出卡片不改输入文字，发送后卡片清空且正文末尾带引用', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    state.answers[LinkMethods.upload] = (_) => {'path': _path};
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '看下这份文档');
    await pick(tester);
    // 输入框只保留用户写的文字，不插入 @ 路径。
    expect(text(tester), '看下这份文档');
    expect(text(tester), isNot(contains('@')));
    expect(find.byKey(const ValueKey('file-attachment')), findsOneWidget);
    expect(find.text('合成 文档.pdf'), findsOneWidget);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final send = state.calls.singleWhere((e) => e.$1 == LinkMethods.send).$2;
    expect(send['text'], endsWith(fileMentionText(_path)));
    expect(send['text'], '看下这份文档\n\n${fileMentionText(_path)}');
    expect(send['mentions'], [_path]);
    expect(find.byKey(const ValueKey('file-attachment')), findsNothing);
    expect(text(tester), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('电脑不支持上传时卡片说明原因且发送不可用，移除卡片后能发剩余文字', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    state.answers[LinkMethods.upload] = (_) =>
        throw const LinkRemoteException(LinkErrors.unknown, '敏感路径不得回显');
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '还剩这段文字');
    await pick(tester);
    expect(text(tester), '还剩这段文字');
    expect(find.byKey(const ValueKey('file-attachment')), findsOneWidget);
    expect(find.textContaining('此电脑不支持文件上传，请更新。'), findsOneWidget);
    expect(find.textContaining('敏感'), findsNothing);
    final action = tester.widget<ChatComposerAction>(
      find.byType(ChatComposerAction),
    );
    expect(action.enabled, isFalse);
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(state.calls.where((e) => e.$1 == LinkMethods.send), isEmpty);
    // 移除失败的卡片后，剩余文字可以正常发送。
    await tester.tap(find.byTooltip('移除文件'));
    await tester.pump();
    expect(find.byKey(const ValueKey('file-attachment')), findsNothing);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final send = state.calls.singleWhere((e) => e.$1 == LinkMethods.send).$2;
    expect(send['text'], '还剩这段文字');
    expect(send['mentions'], isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('上传中移除卡片后迟到的成功结果不会复活卡片或进入发送', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    final uploaded = Completer<Object?>();
    state.answers[LinkMethods.upload] = (_) => uploaded.future;
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '先撤回附件');
    await pick(tester);
    expect(find.byKey(const ValueKey('file-upload-progress')), findsOneWidget);
    await tester.tap(find.byTooltip('移除文件'));
    await tester.pump();
    expect(find.byKey(const ValueKey('file-attachment')), findsNothing);
    expect(state.inputDraft('desktop', 'session').files, isEmpty);
    uploaded.complete({'path': _path});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('file-attachment')), findsNothing);
    expect(state.inputDraft('desktop', 'session').files, isEmpty);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final send = state.calls.singleWhere((e) => e.$1 == LinkMethods.send).$2;
    expect(send['text'], '先撤回附件');
    expect(send['mentions'], isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('只有文件没有文字时也能发送，正文只有文件引用', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    state.answers[LinkMethods.upload] = (_) => {'path': _path};
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await pick(tester);
    expect(text(tester), isEmpty);
    expect(find.byKey(const ValueKey('file-attachment')), findsOneWidget);
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final send = state.calls.singleWhere((e) => e.$1 == LinkMethods.send).$2;
    expect(send['text'], fileMentionText(_path));
    expect(send['mentions'], [_path]);
    expect(find.byKey(const ValueKey('file-attachment')), findsNothing);
    expect(text(tester), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('编辑重发时末尾文件引用恢复为卡片，行内引用留在正文，重发内容不变', (tester) async {
    final state = ChineseChatPageState();
    addTearDown(state.dispose);
    final original = '请对比 @/tmp/a-other\n\n${fileMentionText(_path)}';
    state.history.items.add({'t': 'user', 'text': original});
    await tester.pumpWidget(chatHost(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑并重新发送'));
    await tester.pumpAndSettle();
    expect(text(tester), '请对比 @/tmp/a-other');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('composer-input-surface')),
        matching: find.byKey(const ValueKey('file-attachment')),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('重新发送'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '丢弃并发送'));
    await tester.pumpAndSettle();
    final edit = state.calls.singleWhere((e) => e.$1 == LinkMethods.edit).$2;
    expect(edit['text'], original);
    expect(edit['mentions'], unorderedEquals(['/tmp/a-other', _path]));
    expect(upload(state), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Iterable<(String, Map<String, Object?>)> upload(ChatPageState state) =>
    state.calls.where((e) => e.$1 == LinkMethods.upload);
