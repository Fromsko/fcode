import 'dart:convert';

import 'package:fromsko_mobile/chat/chat_models.dart';
import 'package:fromsko_mobile/chat/chat_output.dart';
import 'package:fromsko_mobile/link/chat_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> user(String text) => {'t': 'user', 'text': text};
Map<String, Object?> reply(String text) => {'t': 'text', 'text': text};
Map<String, Object?> sent({
  String text = '',
  String status = 'succeeded',
  bool image = false,
}) => {
  't': 'tool',
  'tool': 'bot_send',
  'status': status,
  'sent': text,
  if (image)
    'images': [
      {
        'data': base64Encode([1, 2, 3]),
        'type': 'image/png',
      },
    ],
};

void main() {
  test('带引用属性的公开片段保留引用，建议和接力不混入正文', () {
    const text =
        '<bot_say ref=" #74 ">[whispers] 你好</bot_say>'
        '<bot_narrate>轻轻点头</bot_narrate><bot_suggest>继续说说</bot_suggest>'
        '<bot_next>另一位</bot_next>';
    expect(ChatCodec.botPartsOf(text).first.ref, 74);
    expect(ChatCodec.botSays(text), ['你好']);
    expect(ChatCodec.botVisibleText(text), '你好\n轻轻点头');
    expect(ChatCodec.botSuggestions(text), ['继续说说']);
    expect(ChatCodec.botVisibleText('<bot_suggest>继续</bot_suggest>'), isEmpty);
    expect(ChatCodec.botVisibleText('<bot_say ref="1">还未写完'), isEmpty);
    expect(ChatCodec.botVisibleText('旧电脑的无标签回复'), '旧电脑的无标签回复');
  });

  test('推荐只取闭合短文字，去重并最多三条', () {
    expect(
      ChatCodec.botSuggestions(
        '<bot_suggest>继续</bot_suggest><bot_suggest>继续</bot_suggest>'
        '<bot_suggest><bot_say>内部</bot_say></bot_suggest>'
        '<bot_suggest>多行\n内容</bot_suggest>'
        '<bot_suggest>${'长' * 121}</bot_suggest>'
        '<bot_suggest>换个角度</bot_suggest><bot_suggest>先总结</bot_suggest>'
        '<bot_suggest>第四条</bot_suggest><bot_suggest>未闭合',
      ),
      ['继续', '换个角度', '先总结'],
    );
  });

  test('成功发送重建私聊文字与仅图消息，失败运行中均不算发送', () {
    final text = ChatCodec.decode(sent(text: '  给你的私信  '))!;
    expect(ChatCodec.botSentToUser(text), '给你的私信');
    final image = ChatCodec.decode(sent(image: true))!;
    expect(ChatCodec.botSentToUser(image), '');
    expect(ChatCodec.encode(image)['sent'], '');
    expect(ChatCodec.botSentToUser(ChatCodec.decode(sent())), isNull);
    for (final status in ['failed', 'running']) {
      expect(
        ChatCodec.botSentToUser(
          ChatCodec.decode(sent(text: '不应显示', image: true, status: status)),
        ),
        isNull,
      );
    }
  });

  test('群回合不进私聊，跨场所成功私信单独可见且原始索引不变', () {
    final items = <Object?>[
      user('<bao-event>[group group-a] 群里的问题</bao-event>'),
      reply('<bot_say>群回答</bot_say>'),
      sent(text: '只给你'),
      sent(image: true),
      reply('<bot_narrate>仍是群里的旁白</bot_narrate>'),
      user('用户在私聊问'),
      reply('旧格式私聊回复'),
      user('<bao-event>私聊内部事件</bao-event>'),
      reply('<bot_say>内部事件后的私聊</bot_say>'),
    ];
    final original = jsonEncode(items);
    expect(botRows(items).where((row) => !row.isFold).map((row) => row.index), [
      2,
      3,
      5,
      6,
      8,
    ]);
    expect(jsonEncode(items), original);
    expect(ChatCodec.botPlaces(decodeItems(items)), [
      'group-a',
      'group-a',
      null,
      null,
      'group-a',
      null,
      null,
      null,
      null,
    ]);
  });

  test('截断窗口前缀默认未知，前插上下文后重新归属但不改消息', () {
    final tail = <Object?>[
      reply('未知来源的回复'),
      sent(image: true),
      user('明确私聊'),
      reply('私聊回答'),
    ];
    expect(botRows(tail, startsAtBeginning: false).map((row) => row.index), [
      1,
      2,
      3,
    ]);
    final groupPrefix = <Object?>[
      user('<bao-event>[group group-a] 群问题</bao-event>'),
      ...tail,
    ];
    expect(botRows(groupPrefix).map((row) => row.index), [2, 3, 4]);
    final privatePrefix = <Object?>[user('更早的私聊问题'), ...tail];
    expect(botRows(privatePrefix).map((row) => row.index), [0, 1, 2, 3, 4]);
    expect((tail.first as Map)['text'], '未知来源的回复');
  });

  test('普通用户正文含内部事件仍保留，用户语气标记不经过Bot输出过滤', () {
    final user = UserMessageItem(
      text: '用户正文<bao-event>内部通知</bao-event>后续正文 [laughs]',
    );
    expect(shownInBotChat(user), isTrue);
    expect(ChatCodec.withoutBotEvents(user.text), '用户正文后续正文 [laughs]');
  });

  test('推荐按轮次与会话隔离，关闭重开和点击后不复活，群回合无建议', () {
    final tracker = BotReplySuggestions();
    var epoch = 0;
    Object conversation = '私聊甲';
    var enabled = true;
    final items = <Object?>[];
    List<String> current() => tracker.update(
      conversation: conversation,
      epoch: epoch,
      enabled: enabled,
      live: false,
      items: items,
    );
    expect(current(), isEmpty);
    items.addAll([user('第一轮'), reply('<bot_suggest>继续说说</bot_suggest>')]);
    expect(current(), ['继续说说']);
    tracker.dismiss();
    expect(current(), isEmpty);
    items.addAll([user('第二轮'), reply('<bot_suggest>换个角度</bot_suggest>')]);
    expect(current(), ['换个角度']);
    enabled = false;
    epoch++;
    expect(current(), isEmpty);
    enabled = true;
    epoch++;
    expect(current(), isEmpty);
    items.addAll([user('第三轮'), reply('<bot_suggest>先总结</bot_suggest>')]);
    expect(current(), ['先总结']);
    conversation = '私聊乙';
    expect(current(), isEmpty);
    items.addAll([
      user('<bao-event>[group group-a] 群问题</bao-event>'),
      reply('<bot_suggest>不合法场所</bot_suggest>'),
    ]);
    expect(current(), isEmpty);
  });
}
