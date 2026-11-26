import 'package:fromsko_mobile/ui/tasks/chat_composer_action.dart';
import 'package:fromsko_mobile/ui/tasks/chat_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('加号在左、发送在右，只有能发时发送才亮；给了停止就换成停止', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var sent = 0, added = 0, stopped = 0;
    Future<void> pump({bool canSend = false, bool stop = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChatInputBar(
                tr: (zh, en) => zh,
                controller: controller,
                focusNode: focus,
                hint: '发消息…',
                canSend: canSend,
                busy: false,
                onSend: () => sent++,
                onAdd: () => added++,
                stop: stop ? () => stopped++ : null,
              ),
            ),
          ),
        );

    await pump();
    final plus = find.byTooltip('添加附件');
    final field = find.byType(TextField);
    final send = find.byTooltip('发送');
    expect(plus, findsOneWidget);
    expect(send, findsOneWidget);
    expect(tester.getRect(plus).left, lessThan(tester.getRect(field).left));
    expect(tester.getRect(send).left, greaterThan(tester.getRect(field).right));
    expect(
      tester.widget<ChatComposerAction>(find.byType(ChatComposerAction)).enabled,
      isFalse,
    );
    await tester.tap(send);
    expect(sent, 0);
    await tester.tap(plus);
    expect(added, 1);

    await pump(canSend: true);
    expect(
      tester.widget<ChatComposerAction>(find.byType(ChatComposerAction)).enabled,
      isTrue,
    );
    await tester.tap(send);
    expect(sent, 1);

    await pump(stop: true);
    expect(find.byTooltip('发送'), findsNothing);
    await tester.tap(find.byTooltip('停止生成'));
    expect(stopped, 1);
  });
}
