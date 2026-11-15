import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/link/link_store.dart';
import 'package:baocode_mobile/state/app_state.dart';
import 'package:baocode_mobile/state/bot_settings.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends AppState {
  _State() : super(store: MemoryLinkStore());
  final calls = <Map<String, Object?>>[];
  @override
  bool isOnline(String desktop) => true;
  @override
  Future<Object?> request(
    String desktop,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    calls.add(params);
    return {'session': '会话'};
  }
}

void main() {
  test('主动联系默认开启，仅关闭时序列化，不混同旧智能体动态和限额', () {
    final old = LinkBot.fromJson({'id': '宝', 'name': '小宝'});
    expect(old.writesFirst, isTrue);
    expect(old.toJson().containsKey('writesFirst'), isFalse);
    final bot = LinkBot.fromJson({
      'id': '宝',
      'name': '小宝',
      'writesFirst': false,
      'abilities': ['proactive'],
      'proactive': {'perDay': 2, 'quietFrom': 1, 'quietTo': 3},
    });
    expect(bot.writesFirst, isFalse);
    expect(bot.toJson()['writesFirst'], isFalse);
    expect(bot.abilities, contains(BotAbility.proactive));
    expect(bot.proactive.perDay, 2);
  });

  test('保存主动联系需回读一致，旧电脑忽略false不假报成功也不重复创建', () async {
    final calls = <Map<String, Object?>>[];
    final saver = BotProfileSaver(
      desktopId: '电脑',
      request: (_, _, fields) async {
        calls.add(fields);
        return {
          'bot': {'id': '已创建', 'name': '小宝'},
        };
      },
    );
    await expectLater(
      saver.save({'name': '小宝'}, chatOnly: false, writesFirst: false),
      throwsA(isA<BotWritesFirstUnconfirmed>()),
    );
    expect(saver.botId, '已创建');
    expect(saver.creationUnconfirmed, isFalse);
    await expectLater(
      saver.save({'name': '小宝'}, chatOnly: false, writesFirst: false),
      throwsA(isA<BotWritesFirstUnconfirmed>()),
    );
    expect(calls.last['bot'], '已创建');
    expect(calls.first['writesFirst'], isFalse);
  });

  test('开关写入超时为结果未确认，不认为接口不支持且创建不重试', () async {
    var writes = 0;
    final saver = BotProfileSaver(
      desktopId: '电脑',
      request: (_, _, _) async {
        writes++;
        throw TimeoutException('仅合成超时');
      },
    );
    await expectLater(
      saver.save({'name': '小宝'}, chatOnly: false, writesFirst: false),
      throwsA(isA<TimeoutException>()),
    );
    await expectLater(
      saver.save({'name': '小宝'}, chatOnly: false, writesFirst: false),
      throwsStateError,
    );
    expect(writes, 1);
    String zh(String zh, String _) => zh;
    expect(
      botSaveFailureMessage(TimeoutException('仅合成超时'), zh),
      contains('未确认'),
    );
  });

  test('推荐本地设置按电脑与Bot隔离并往返序列化', () {
    final settings = AppSettings()..botSuggestions.add(('电脑甲', '小宝'));
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.botSuggestions.contains(('电脑甲', '小宝')), isTrue);
    expect(restored.botSuggestions.contains(('电脑乙', '小宝')), isFalse);
    expect(restored.botSuggestions.contains(('电脑甲', '另一个')), isFalse);
    expect(AppSettings.fromJson({}).botSuggestions, isEmpty);
  });

  test('Bot发送读取当前本地开关，普通智能体不带suggest', () async {
    final state = _State();
    addTearDown(state.dispose);
    await state.sendMessage('电脑', bot: '宝', text: '你好');
    expect(state.calls.last['suggest'], isFalse);
    await state.setBotSuggestionsEnabled('电脑', '宝', true);
    await state.sendMessage('电脑', bot: '宝', text: '继续');
    expect(state.calls.last['suggest'], isTrue);
    await state.sendMessage('另一台', bot: '宝', text: '你好');
    expect(state.calls.last['suggest'], isFalse);
    await state.sendMessage('电脑', session: '普通会话', text: '确定修改');
    expect(state.calls.last.containsKey('suggest'), isFalse);
  });

  test('排队消息也在真正发送时读取最新开关', () async {
    final state = _State();
    addTearDown(state.dispose);
    state.buffer('电脑', '会话').live = true;
    final queued = state.localQueue.add('电脑', '会话', bot: '宝', text: '排队内容');
    await state.setBotSuggestionsEnabled('电脑', '宝', true);
    state.buffer('电脑', '会话').live = false;
    expect(await state.localQueue.sendNow('电脑', '会话', queued.id), isTrue);
    expect(state.calls.last['suggest'], isTrue);
  });
}
