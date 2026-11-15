import 'package:bao_link/bao_link.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _snapshot(
  List<Object?> items, {
  int start = 0,
  int? count,
}) => {
  'session': '合成会话',
  'start': start,
  'count': count ?? start + items.length,
  'items': items,
  'live': false,
};

void main() {
  test('续传首包使用原始未知字段重建全部历史并正常化返回值', () async {
    final mirror = LinkSessionMirror();
    final original = <Object?>[
      {
        't': '未来类型',
        '未知字段': {'顺序乙': 2, '顺序甲': 1},
      },
      {'t': 'text', 'text': '断线前'},
    ];
    mirror.opened(_snapshot(original));
    final (client, server) = MemoryLinkConnection.pair();
    final accepting = LinkPeer.accept(
      server,
      onRequest: (method, params) {
        expect(params['have'], ['f05443a5a665b1eb', '44e31fe03ebac164']);
        return _snapshot([
          {'t': 'text', 'text': '断线后'},
        ], start: 1);
      },
    );
    final phone = await LinkPeer.connect(client, mirror: mirror);
    final desktop = await accepting;
    addTearDown(phone.close);
    addTearDown(desktop.close);
    final events = <LinkEvent>[];
    final subscription = phone.events.listen(events.add);
    addTearDown(subscription.cancel);
    final result = await phone.call(LinkMethods.open, {'session': '合成会话'});
    await pumpEventQueue();
    expect(
      result,
      _snapshot([
        original.first,
        {'t': 'text', 'text': '断线后'},
      ]),
    );
    expect(events.single.name, LinkEvents.session);
    expect(events.single.data, result);
  });

  test('官方摘要按原始键序和UTF16双哈希处理中文及扩展汉字', () {
    expect(linkDigest(null), '77074ba47c72c9de');
    expect(linkDigest({'text': '中文与非基本平面字符𠮷'}), '2f2b034fa32a98fd');
    expect(linkDigest({'a': 1, 'b': 2}), '5314055b038d2e6f');
    expect(linkDigest({'b': 2, 'a': 1}), '07cc4fefccfd3f6f');
  });

  test('保留历史与每次报价独立，报价之后的增量不会改变首包前缀', () {
    final mirror = LinkSessionMirror();
    mirror.keep('合成会话', ['报价前']);
    expect(mirror.have('合成会话'), hasLength(1));
    mirror.keep('合成会话', ['报价后但尚未发送']);
    expect(mirror.opened(_snapshot([], start: 1)), _snapshot(['报价前']));
    mirror.have('合成会话');
    mirror.apply(_snapshot(['已收到增量']));
    expect(mirror.opened(_snapshot([], start: 1)), _snapshot(['报价前']));
  });

  test('旧电脑返回零起点全量时覆盖缓存，空历史同样可正常化', () {
    final mirror = LinkSessionMirror();
    mirror.keep('合成会话', ['旧缓存']);
    mirror.have('合成会话');
    expect(mirror.opened(_snapshot(['全量新历史'])), _snapshot(['全量新历史']));
    mirror.have('合成会话');
    expect(mirror.opened(_snapshot([])), _snapshot([]));
    expect(mirror.have('合成会话'), isNull);
  });

  test('关闭会话仅保留最近三十二份历史，重新保留会更新淘汰次序', () {
    final mirror = LinkSessionMirror();
    for (var i = 0; i < 33; i++) {
      final session = '合成会话$i';
      mirror.opened({
        ..._snapshot(['原始历史$i']),
        'session': session,
      });
      mirror.closed(session);
    }
    expect(mirror.have('合成会话0'), isNull);
    expect(mirror.have('合成会话1'), hasLength(1));
    expect(mirror.have('合成会话32'), hasLength(1));
    mirror.keep('合成会话1', ['最近使用']);
    mirror.keep('合成会话33', ['新历史']);
    expect(mirror.have('合成会话2'), isNull);
    expect(mirror.have('合成会话1'), hasLength(1));
    expect(mirror.stale({'session': '合成会话1'}), isTrue);
  });

  test('非法首包起点数量或补丁都清理报价和历史，下次不携带坏基线', () {
    final invalid = <Map<String, Object?>>[
      _snapshot([], start: -1),
      _snapshot([], start: 2),
      _snapshot([], start: 1, count: 2),
      {..._snapshot([]), 'items': null},
      {..._snapshot([]), 'count': null},
      {..._snapshot([]), 'partial': true},
      {
        ..._snapshot([]),
        'append': {'text': '非法补丁'},
      },
    ];
    for (final update in invalid) {
      final mirror = LinkSessionMirror();
      mirror.keep('合成会话', ['旧缓存']);
      mirror.have('合成会话');
      expect(mirror.opened(update), isNull);
      expect(mirror.have('合成会话'), isNull);
      expect(mirror.opened(_snapshot(['全量恢复'])), _snapshot(['全量恢复']));
    }
  });

  test('坏增量和追加补丁失配后清除基线，不能继续报价旧历史', () {
    final invalid = <Map<String, Object?>>[
      {..._snapshot([], start: 2), 'partial': true},
      {..._snapshot([], start: 1), 'count': 3, 'partial': true},
      {
        ..._snapshot([], start: 1),
        'partial': true,
        'append': {
          'index': 0,
          'path': ['不存在'],
          'text': '失配',
        },
      },
    ];
    for (final update in invalid) {
      final mirror = LinkSessionMirror();
      mirror.opened(
        _snapshot([
          {'text': '原始内容'},
        ]),
      );
      mirror.have('合成会话');
      expect(mirror.apply(update), isNull);
      expect(mirror.have('合成会话'), isNull);
    }
  });

  test('真实Peer遇到不能重建的首包只返回空结果并发出重新同步', () async {
    final mirror = LinkSessionMirror();
    mirror.keep('合成会话', ['只有一条']);
    final (client, server) = MemoryLinkConnection.pair();
    final accepting = LinkPeer.accept(
      server,
      onRequest: (_, _) => _snapshot([], start: 2),
    );
    final phone = await LinkPeer.connect(client, mirror: mirror);
    final desktop = await accepting;
    addTearDown(phone.close);
    addTearDown(desktop.close);
    final event = phone.events.first;
    expect(await phone.call(LinkMethods.open, {'session': '合成会话'}), isNull);
    expect((await event).name, LinkEvents.resync);
    expect(mirror.have('合成会话'), isNull);
  });

  test('空应答和错会话首包同样清理请求会话，不污染另一份历史', () async {
    for (final answer in [
      null,
      {
        ..._snapshot(['错误会话历史']),
        'session': '另一会话',
      },
    ]) {
      final mirror = LinkSessionMirror();
      mirror.keep('合成会话', ['原始缓存']);
      mirror.keep('另一会话', ['独立缓存']);
      final (client, server) = MemoryLinkConnection.pair();
      final accepting = LinkPeer.accept(server, onRequest: (_, _) => answer);
      final phone = await LinkPeer.connect(client, mirror: mirror);
      final desktop = await accepting;
      addTearDown(phone.close);
      addTearDown(desktop.close);
      final event = phone.events.first;
      expect(await phone.call(LinkMethods.open, {'session': '合成会话'}), isNull);
      expect((await event).data, {'session': '合成会话'});
      expect(mirror.have('合成会话'), isNull);
      expect(mirror.have('另一会话'), hasLength(1));
    }
  });
}
