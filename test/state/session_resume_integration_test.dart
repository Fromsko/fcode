import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/link/phone_link.dart';
import 'package:baocode_mobile/state/app_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Computer {
  _Computer(this.network) {
    node = network.node(identity.id);
    node.incoming.listen((connection) {
      unawaited(LinkPeer.accept(connection, onRequest: handle).then(peers.add));
    });
  }

  final MemoryLinkNetwork network;
  final identity = LinkIdentity.generate();
  late final MemoryLinkNode node;
  final peers = <LinkPeer>[];
  final opens = <Map<String, Object?>>[];
  final history = <Object?>[
    for (var i = 0; i < 80; i++)
      {
        't': 'text',
        'text': '仅内存合成历史$i',
        '未来字段': {'乙': i, '甲': true},
      },
  ];
  bool trusted = false;
  bool legacy = false;
  int from = 0;
  int corruptOpens = 0;
  bool emptyRecovery = false;
  bool recovering = false;
  Completer<void>? recoveryGate;
  final recoveryStarted = Completer<void>();

  Map<String, Object?> get device => {
    'name': '仅内存合成电脑',
    'direct': true,
    'relays': <String>[],
    'addrs': ['127.0.0.1:47100'],
  };

  Map<String, Object?> snapshot({int start = 0}) => {
    'session': '同名合成会话',
    'start': start,
    'count': history.length - from,
    'items': history.sublist(from + start),
    'live': false,
    'earlier': from > 0,
  };

  Future<Object?> handle(String method, Map<String, Object?> params) async {
    switch (method) {
      case LinkMethods.hello:
        return {'device': device, if (!trusted) 'pairing': true};
      case LinkMethods.confirm:
        trusted = true;
        return null;
      case LinkMethods.state:
        return {'device': device, 'projects': [], 'bots': []};
      case LinkMethods.open:
        opens.add(params);
        if (corruptOpens > 0) {
          corruptOpens--;
          recovering = true;
          return {
            'session': '同名合成会话',
            'start': 999,
            'count': 999,
            'items': <Object?>[],
          };
        }
        if (recovering) {
          recovering = false;
          if (!recoveryStarted.isCompleted) recoveryStarted.complete();
          await recoveryGate?.future;
          if (emptyRecovery) return null;
        }
        final window = params['window'] as int;
        from = (history.length - window).clamp(0, history.length);
        var start = 0;
        if (params['have'] case final List have when !legacy) {
          while (start < have.length &&
              from + start < history.length &&
              have[start] == linkDigest(history[from + start])) {
            start++;
          }
        }
        return snapshot(start: start);
      case LinkMethods.earlier:
        final before = from;
        from = (from - (params['count'] as int)).clamp(0, history.length);
        return {'items': history.sublist(from, before), 'earlier': from > 0};
      case LinkMethods.close:
      case LinkMethods.unpair:
        return null;
      default:
        throw StateError('续传测试只允许合成配对和只读请求');
    }
  }

  Future<void> pair(PhoneLink phone) async {
    final attempt = await phone.pair(
      PairingOffer(
        name: '仅内存合成电脑',
        key: identity.publicKey,
        token: randomBytes(16),
        expires: DateTime.now().add(const Duration(minutes: 1)),
        addrs: ['127.0.0.1:47100'],
        direct: true,
      ).uri,
    );
    await phone.confirmPairing(attempt);
  }

  Future<void> close() async {
    for (final peer in peers) {
      await peer.close();
    }
    await node.close();
  }
}

class _Harness {
  _Harness() {
    computer = _Computer(network);
    phone = PhoneLink(
      store: store,
      nodeFactory: (identity, _) async => network.node(identity.id),
    );
    state = AppState(store: store, link: phone);
  }
  final network = MemoryLinkNetwork();
  final store = MemoryLinkStore();
  late final _Computer computer;
  late final PhoneLink phone;
  late final AppState state;

  Future<void> start() async {
    await state.initialize();
    await computer.pair(phone);
    await state.openSession(computer.identity.id, '同名合成会话');
    await pumpEventQueue();
  }

  Future<void> close() async {
    state.dispose();
    await computer.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channels = [
    MethodChannel('local.baocode.mobile/platform'),
    MethodChannel('local.baocode.mobile/discovery'),
  ];
  setUp(() {
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
  });
  tearDown(() {
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('真实连接断线后复用原始历史摘要，展开的分页和后续追加索引不丢失', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    final id = h.computer.identity.id;
    await h.state.loadEarlier(id, '同名合成会话');
    expect(h.state.buffer(id, '同名合成会话').items, h.computer.history);
    h.computer.history.last = {'t': 'text', 'text': '断线期间更改'};
    await h.phone.reconnect(id);
    await pumpEventQueue();
    expect(h.computer.opens.last['have'], hasLength(80));
    final buffer = h.state.buffer(id, '同名合成会话');
    expect(buffer.items, h.computer.history);
    expect(buffer.error, isNull);
    h.computer.peers.last.emit(LinkEvents.session, {
      'session': '同名合成会话',
      'start': 80,
      'count': 80,
      'items': <Object?>[],
      'partial': true,
      'append': {
        'index': 79,
        'path': ['text'],
        'text': '，继续追加',
      },
    });
    await pumpEventQueue();
    expect((buffer.items.last as Map)['text'], '断线期间更改，继续追加');
  });

  test('首包续传不匹配时清基线重开，完整快照返回前不得宣称同步成功', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    final id = h.computer.identity.id;
    final buffer = h.state.buffer(id, '同名合成会话');
    final previous = [...buffer.items];
    h.computer.corruptOpens = 1;
    h.computer.recoveryGate = Completer<void>();
    final refreshing = h.state.refreshSession(id, '同名合成会话');
    await h.computer.recoveryStarted.future.timeout(const Duration(seconds: 2));
    expect(h.computer.opens.last.containsKey('have'), isFalse);
    expect(buffer.items, previous);
    expect(buffer.loading, isTrue);
    h.computer.history.last = {'t': 'text', 'text': '完整重开后才可见'};
    h.computer.recoveryGate!.complete();
    await refreshing;
    await pumpEventQueue();
    expect(buffer.items.last, h.computer.history.last);
    expect(buffer.loading, isFalse);
    expect(buffer.error, isNull);
  });

  test('失配后完整重开仍返回空应答时必须报错并保留旧历史，不能误报同步成功', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    final id = h.computer.identity.id;
    final buffer = h.state.buffer(id, '同名合成会话');
    final previous = [...buffer.items];
    h.computer.corruptOpens = 1;
    h.computer.emptyRecovery = true;
    final before = h.computer.opens.length;
    await expectLater(
      h.state.refreshSession(id, '同名合成会话'),
      throwsA(isA<FormatException>()),
    );
    await pumpEventQueue();
    expect(h.computer.opens, hasLength(before + 2));
    expect(h.computer.opens.last.containsKey('have'), isFalse);
    expect(buffer.items, previous);
    expect(buffer.loading, isFalse);
    expect(buffer.error, isNotNull);
    h.computer.emptyRecovery = false;
    await h.state.refreshSession(id, '同名合成会话');
    expect(h.computer.opens.last.containsKey('have'), isFalse);
    expect(buffer.error, isNull);
  });

  test('旧电脑忽略摘要并返回全量首包时保持兼容', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    final id = h.computer.identity.id;
    h.computer.legacy = true;
    h.computer.history.last = {'t': 'text', 'text': '旧电脑全量更新'};
    await h.state.refreshSession(id, '同名合成会话');
    expect(h.computer.opens.last['have'], hasLength(60));
    final buffer = h.state.buffer(id, '同名合成会话');
    expect(buffer.items, h.computer.history.sublist(20));
    expect(buffer.error, isNull);
  });

  test('关闭后重开同一会话仍可续传，关闭后迟到增量不污染缓存', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    final id = h.computer.identity.id;
    await h.state.closeSession(id, '同名合成会话');
    h.computer.peers.last.emit(LinkEvents.session, {
      ...h.computer.snapshot(),
      'items': [
        {'t': 'text', 'text': '关闭后不能接收'},
      ],
      'count': 1,
    });
    await pumpEventQueue();
    await h.state.openSession(id, '同名合成会话');
    expect(h.computer.opens.last['have'], hasLength(60));
    expect(h.state.buffer(id, '同名合成会话').items, h.computer.history.sublist(20));
  });

  test('不同电脑的同名会话不交换续传摘要或历史', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    final other = _Computer(h.network);
    addTearDown(other.close);
    other.history.last = {'t': 'text', 'text': '另一台电脑的独立历史'};
    await other.pair(h.phone);
    await h.state.openSession(other.identity.id, '同名合成会话');
    expect(other.opens.single.containsKey('have'), isFalse);
    expect(
      h.state.buffer(other.identity.id, '同名合成会话').items.last,
      other.history.last,
    );
    expect(
      h.state.buffer(h.computer.identity.id, '同名合成会话').items.last,
      h.computer.history.last,
    );
  });

  test('取消配对后重新信任同一电脑不再携带旧会话摘要', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    final id = h.computer.identity.id;
    await h.state.closeSession(id, '同名合成会话');
    await h.phone.forget(id);
    await h.computer.pair(h.phone);
    await h.state.openSession(id, '同名合成会话');
    expect(h.computer.opens.last.containsKey('have'), isFalse);
    expect(h.state.buffer(id, '同名合成会话').error, isNull);
  });

  test('真实增量失配触发清基线全量重开，不能继续复用坏摘要', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    final before = h.computer.opens.length;
    h.computer.history.last = {'t': 'text', 'text': '增量失配后恢复'};
    h.computer.peers.last.emit(LinkEvents.session, {
      'session': '同名合成会话',
      'start': 61,
      'count': 61,
      'items': <Object?>[],
      'partial': true,
    });
    await pumpEventQueue(times: 40);
    expect(h.computer.opens, hasLength(before + 1));
    expect(h.computer.opens.last.containsKey('have'), isFalse);
    final buffer = h.state.buffer(h.computer.identity.id, '同名合成会话');
    expect(buffer.items.last, h.computer.history.last);
    expect(buffer.error, isNull);
  });
}
