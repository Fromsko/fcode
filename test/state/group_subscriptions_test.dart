import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/link/phone_link.dart';
import 'package:baocode_mobile/state/app_state.dart';
import 'package:baocode_mobile/state/group_subscriptions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> message(int seq, [String text = '群消息']) => {
  'seq': seq,
  'at': seq * 1000,
  'from': '宝',
  'text': '<bot_say>$text</bot_say>',
};

class _Harness {
  final network = MemoryLinkNetwork();
  final store = MemoryLinkStore();
  final identity = LinkIdentity.generate();
  late final node = network.node(identity.id);
  late final phone = PhoneLink(
    store: store,
    nodeFactory: (identity, _) async => network.node(identity.id),
  );
  late final state = AppState(store: store, link: phone);
  final peers = <LinkPeer>[];
  final calls = <(String, Map<String, Object?>)>[];
  FutureOr<Object?> Function(String, Map<String, Object?>)? handle;
  bool trusted = false;
  Map<String, Object?> get device => {
    'name': '合成电脑',
    'direct': true,
    'relays': <String>[],
    'addrs': ['127.0.0.1:47100'],
  };
  Future<Object?> _request(String method, Map<String, Object?> params) async {
    calls.add((method, params));
    switch (method) {
      case LinkMethods.hello:
        return {'device': device, if (!trusted) 'pairing': true};
      case LinkMethods.confirm:
        trusted = true;
        return null;
      case LinkMethods.state:
        return {
          'device': device,
          'groups': [
            const LinkGroup(id: '群', name: '合成群', members: ['宝']).toJson(),
          ],
        };
      case LinkMethods.closeGroup:
        return null;
      default:
        if (handle case final action?) return action(method, params);
        throw StateError('未预期的合成请求');
    }
  }

  Future<void> start() async {
    node.incoming.listen(
      (connection) => unawaited(
        LinkPeer.accept(connection, onRequest: _request).then(peers.add),
      ),
    );
    await state.initialize();
    final attempt = await phone.pair(
      PairingOffer(
        name: '合成电脑',
        key: identity.publicKey,
        token: randomBytes(16),
        expires: DateTime.now().add(const Duration(minutes: 1)),
        addrs: ['127.0.0.1:47100'],
        direct: true,
      ).uri,
    );
    await phone.confirmPairing(attempt);
    await pumpEventQueue();
  }

  Future<void> close() async {
    state.dispose();
    for (final peer in peers) {
      await peer.close();
    }
    await node.close();
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

  test('真实Peer到AppState：早到群事件与打开响应合并，翻页按seq去重排序', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    h.handle = (method, params) async {
      if (method == LinkMethods.openGroup) {
        h.peers.single.emit(LinkEvents.group, {
          'group': '群',
          'messages': [message(6), message(5)],
        });
        await pumpEventQueue();
        return {
          'messages': [message(4), message(5)],
          'more': true,
        };
      }
      if (method == LinkMethods.earlierGroup) {
        expect(params['before'], 4);
        h.peers.single.emit(LinkEvents.group, {
          'group': '群',
          'messages': [message(7)],
        });
        return {
          'messages': [message(3), message(4)],
          'more': false,
        };
      }
      throw StateError('未预期请求');
    };
    await h.state.groupChats.retain(h.identity.id, '群');
    final buffer = h.state.groupChats.buffer(h.identity.id, '群');
    expect(buffer.messages.map((m) => m.seq), [4, 5, 6]);
    await h.state.groupChats.earlier(h.identity.id, '群');
    await pumpEventQueue();
    expect(buffer.messages.map((m) => m.seq), [3, 4, 5, 6, 7]);
    expect(buffer.more, isFalse);
    await h.state.groupChats.release(h.identity.id, '群');
    expect(
      h.calls.where((call) => call.$1 == LinkMethods.closeGroup),
      hasLength(1),
    );
    expect(h.state.groups.single.group.name, '合成群');
    // LinkState 按官方规则省略空 bots；群聊存在不代表必须有 bots 键。
    final snapshot = await h.state.refreshDesktopState(h.identity.id);
    expect(snapshot.bots, isEmpty);
    expect(snapshot.groups.single.name, '合成群');
  });

  test('真实群RPC：图片读取与带全局去重id及引用的发送保留wire参数', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    h.handle = (method, params) {
      if (method == LinkMethods.groupImage) {
        expect(params, {'group': '群', 'image': '合成图片.png'});
        return {
          'type': 'image/png',
          'data': base64Encode([1, 2, 3]),
        };
      }
      if (method == LinkMethods.sendGroup) {
        expect(params['ref'], 74);
        expect(params['id'], '全局唯一合成标识');
        expect(params.containsKey('suggest'), isFalse);
        expect(params['images'], isNotEmpty);
        return {'seq': 75};
      }
      throw StateError('未预期请求');
    };
    final image = objectMap(
      await h.state.request(h.identity.id, LinkMethods.groupImage, {
        'group': '群',
        'image': '合成图片.png',
      }),
    );
    expect(base64Decode(image['data'] as String), [1, 2, 3]);
    final result = objectMap(
      await h.state.request(h.identity.id, LinkMethods.sendGroup, {
        'group': '群',
        'text': '@小宝 确定修改',
        'ref': 74,
        'id': '全局唯一合成标识',
        'images': [
          {
            'data': base64Encode([1, 2, 3]),
            'type': 'image/png',
          },
        ],
      }),
    );
    expect(result['seq'], 75);
  });

  test('断线代际丢弃旧open响应，新订阅不被迟到close关闭', () async {
    final old = Completer<Object?>();
    var opens = 0;
    final calls = <String>[];
    final groups = GroupSubscriptions(
      request: (_, method, params) async {
        calls.add(method);
        if (method == LinkMethods.openGroup) {
          if (++opens == 1) return old.future;
          return {
            'messages': [message(9, '新连接')],
            'more': false,
          };
        }
        return null;
      },
      onChanged: () {},
      tr: (zh, _) => zh,
    );
    addTearDown(groups.dispose);
    final first = groups.retain('电脑', '群');
    await pumpEventQueue();
    final closing = groups.release('电脑', '群');
    groups.connectionChanged('电脑', online: false);
    groups.connectionChanged('电脑', online: true);
    await groups.retain('电脑', '群');
    old.complete({
      'messages': [message(1, '旧连接')],
      'more': true,
    });
    await first;
    await closing;
    expect(groups.buffer('电脑', '群').messages.single.seq, 9);
    expect(calls.where((call) => call == LinkMethods.closeGroup), isEmpty);
  });

  test('仅明确unknown或unsupported降级，超时不当作不支持', () async {
    for (final error in [
      const LinkRemoteException(LinkErrors.unknown, '合成旧端'),
      TimeoutException('合成超时'),
    ]) {
      final groups = GroupSubscriptions(
        request: (_, _, _) async => throw error,
        onChanged: () {},
        tr: (zh, _) => zh,
      );
      await groups.retain('电脑', '群');
      final buffer = groups.buffer('电脑', '群');
      expect(buffer.unsupported, error is LinkRemoteException);
      expect(buffer.error, isNotNull);
      groups.dispose();
    }
  });

  test('翻页失败只记在earlierError，不占用整页的error，重试时清掉', () async {
    var fail = true;
    final groups = GroupSubscriptions(
      request: (_, method, params) async {
        if (method == LinkMethods.openGroup) {
          return {
            'messages': [message(6), message(7)],
            'more': true,
          };
        }
        if (method == LinkMethods.earlierGroup) {
          if (fail) throw TimeoutException('合成超时');
          return {
            'messages': [message(5)],
            'more': false,
          };
        }
        return null;
      },
      onChanged: () {},
      tr: (zh, _) => zh,
    );
    addTearDown(groups.dispose);
    await groups.retain('电脑', '群');
    final buffer = groups.buffer('电脑', '群');
    await groups.earlier('电脑', '群');
    expect(buffer.earlierError, '更早的群消息未加载，请重试。');
    expect(buffer.error, isNull);
    expect(buffer.loadingEarlier, isFalse);
    fail = false;
    await groups.earlier('电脑', '群');
    expect(buffer.earlierError, isNull);
    expect(buffer.error, isNull);
    expect(buffer.messages.map((m) => m.seq), [5, 6, 7]);
  });

  test('群聊重开保留已展开窗口，可靠后台回前台可复用当前基线', () async {
    final counts = <int>[];
    final groups = GroupSubscriptions(
      request: (_, method, params) async {
        if (method == LinkMethods.openGroup) {
          final count = params['count'] as int;
          counts.add(count);
          return {
            'messages': [
              for (var seq = 101 - count; seq <= 100; seq++) message(seq),
            ],
            'more': count < 100,
          };
        }
        if (method == LinkMethods.earlierGroup) {
          return {
            'messages': [for (var seq = 1; seq <= 50; seq++) message(seq)],
            'more': false,
          };
        }
        return null;
      },
      onChanged: () {},
      tr: (zh, _) => zh,
    );
    addTearDown(groups.dispose);
    await groups.retain('电脑', '群');
    await groups.earlier('电脑', '群');
    expect(groups.buffer('电脑', '群').messages.length, 100);
    // 重开只补最近 50 条；接得上就合并，已翻出来的更早消息留着。
    await groups.refreshRetained((_) => true);
    expect(counts, [50, 50]);
    expect(groups.buffer('电脑', '群').messages.first.seq, 1);
    expect(groups.buffer('电脑', '群').messages.length, 100);
    await groups.refreshRetained((_) => true, keepCurrent: (_, _) => true);
    expect(counts, [50, 50]);
    await groups.release('电脑', '群');
    await groups.refreshRetained((_) => true);
    expect(counts, [50, 50]);
  });

  testWidgets('短暂失败后在同一条连接上按 2/4/8 秒重试，成功后不再重试', (tester) async {
    final opens = <int>[];
    final groups = GroupSubscriptions(
      request: (_, method, _) async {
        if (method == LinkMethods.openGroup) {
          opens.add(opens.length);
          if (opens.length < 3) throw TimeoutException('合成超时');
          return {
            'messages': [message(9)],
            'more': false,
          };
        }
        return null;
      },
      onChanged: () {},
      tr: (zh, _) => zh,
    );
    addTearDown(groups.dispose);
    await groups.retain('电脑', '群');
    final buffer = groups.buffer('电脑', '群');
    expect(opens, hasLength(1));
    expect(buffer.error, isNotNull);
    expect(buffer.loading, isFalse);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(opens, hasLength(2));
    expect(buffer.error, isNotNull);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(opens, hasLength(3));
    expect(buffer.messages.single.seq, 9);
    expect(buffer.error, isNull);

    // 成功就清零：再次失败仍从 2 秒开始。
    await tester.pump(const Duration(seconds: 10));
    expect(opens, hasLength(3));
  });

  testWidgets('重试三次仍失败就停手，错误留给人手动重试', (tester) async {
    var opens = 0;
    final groups = GroupSubscriptions(
      request: (_, method, _) async {
        if (method == LinkMethods.openGroup) {
          opens++;
          throw TimeoutException('合成超时');
        }
        return null;
      },
      onChanged: () {},
      tr: (zh, _) => zh,
    );
    addTearDown(groups.dispose);
    await groups.retain('电脑', '群');
    for (final wait in [2, 4, 8]) {
      await tester.pump(Duration(seconds: wait));
      await tester.pump();
    }
    expect(opens, 4);
    await tester.pump(const Duration(seconds: 30));
    expect(opens, 4);
    expect(groups.buffer('电脑', '群').error, isNotNull);
  });

  testWidgets('断线时不重试，旧连接的计时器随代际作废', (tester) async {
    var opens = 0;
    final groups = GroupSubscriptions(
      request: (_, method, _) async {
        if (method == LinkMethods.openGroup) {
          opens++;
          throw TimeoutException('合成超时');
        }
        return null;
      },
      onChanged: () {},
      tr: (zh, _) => zh,
    );
    addTearDown(groups.dispose);
    await groups.retain('电脑', '群');
    groups.connectionChanged('电脑', online: false);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(opens, 1);
  });

  testWidgets('重开只取 50 条，接得上的页合并不replace并保留更早标记', (tester) async {
    final counts = <int>[];
    var opens = 0;
    final groups = GroupSubscriptions(
      request: (_, method, params) async {
        if (method == LinkMethods.openGroup) {
          counts.add(params['count'] as int);
          if (++opens == 1) {
            return {
              'messages': [for (var seq = 51; seq <= 100; seq++) message(seq)],
              'more': true,
            };
          }
          if (opens == 2) {
            return {
              'messages': [for (var seq = 96; seq <= 120; seq++) message(seq)],
              // 电脑确实说还有更早的；合并时这一页不改变已加载的最老标记。
              'more': true,
            };
          }
          return {
            'messages': [for (var seq = 96; seq <= 120; seq++) message(seq)],
            'more': false,
          };
        }
        if (method == LinkMethods.earlierGroup) {
          return {
            'messages': [for (var seq = 1; seq <= 50; seq++) message(seq)],
            'more': false,
          };
        }
        return null;
      },
      onChanged: () {},
      tr: (zh, _) => zh,
    );
    addTearDown(groups.dispose);
    await groups.retain('电脑', '群');
    await groups.earlier('电脑', '群');
    final buffer = groups.buffer('电脑', '群');
    expect(buffer.messages.length, 100);
    expect(buffer.more, isFalse);
    expect(counts, [50]);
    // 已有基线时重开只要 50 条，而不是把翻出来的 100 条全要一遍。
    final refreshing = groups.refresh('电脑', '群');
    // 翻页没等这个测试的计时器：await 前先让请求走完。
    await refreshing;
    expect(counts, [50, 50]);
    final seqs = buffer.messages.map((m) => m.seq).toList();
    expect(seqs.first, 1);
    expect(seqs.last, 120);
    expect(seqs.length, 120);
    // 合并时沿用已翻出来的最老那一页：还有更早的。
    expect(buffer.more, isFalse);
    expect(buffer.error, isNull);
  });

  testWidgets('返回的页和已加载的断开或内容对不上时整页替换', (tester) async {
    for (final mismatched in [false, true]) {
      var opens = 0;
      final groups = GroupSubscriptions(
        request: (_, method, _) async {
          if (method != LinkMethods.openGroup) return null;
          if (++opens == 1) {
            return {
              'messages': [for (var seq = 51; seq <= 100; seq++) message(seq)],
              'more': true,
            };
          }
          return {
            'messages': mismatched
                ? [
                    for (var seq = 96; seq <= 120; seq++)
                      message(seq, seq == 100 ? '改过的内容' : '群消息'),
                  ]
                : [for (var seq = 200; seq <= 220; seq++) message(seq)],
            'more': opens > 2,
          };
        },
        onChanged: () {},
        tr: (zh, _) => zh,
      );
      await groups.retain('电脑', '群');
      await groups.refresh('电脑', '群');
      final buffer = groups.buffer('电脑', '群');
      expect(buffer.messages.first.seq, mismatched ? 96 : 200);
      expect(buffer.messages.length, mismatched ? 25 : 21);
      groups.dispose();
    }
  });

  test('连续新建两群不复用已经成功创建的身份', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    var saves = 0;
    h.handle = (method, params) {
      expect(method, LinkMethods.saveGroup);
      expect(params.containsKey('group'), isFalse);
      return {
        'group': {...params, 'id': '合成群-${++saves}'},
      };
    };
    final first = h.state.groupProfileSaver(h.identity.id);
    await first.save(name: '群甲', members: ['宝'], passes: 8, rules: '', gap: 0);
    final second = h.state.groupProfileSaver(h.identity.id);
    expect(second, isNot(same(first)));
    await second.save(name: '群乙', members: ['宝'], passes: 8, rules: '', gap: 0);
    expect(first.saved!.id, '合成群-1');
    expect(second.saved!.id, '合成群-2');
  });

  test('旧电脑忽略新群设置时不报成功，已返回的身份仍保留', () async {
    final saver = GroupProfileSaver(
      desktop: '电脑',
      request: (_, _, _) async => {
        'group': const LinkGroup(
          id: '已创建',
          name: '合成群',
          members: ['宝'],
        ).toJson(),
      },
    );
    await expectLater(
      saver.save(name: '合成群', members: ['宝'], passes: 0, rules: '不要抢话', gap: 5),
      throwsA(isA<Exception>()),
    );
    expect(saver.saved!.id, '已创建');
    expect(saver.creationUnconfirmed, isFalse);
  });

  test('保存按官方规则规范化并允许空名由电脑生成', () async {
    final saver = GroupProfileSaver(
      desktop: '电脑',
      request: (_, _, params) async {
        expect(params['passes'], 1 << 20);
        return {
          'group': {
            ...params,
            'id': '合成群',
            'name': '电脑生成的名称',
            'rules': '轮流接话',
            'members': ['宝'],
          },
        };
      },
    );
    final saved = await saver.save(
      name: '',
      members: ['宝', '宝'],
      passes: 1 << 22,
      rules: ' 轮流接话 ',
      gap: 0,
    );
    expect(saved.name, '电脑生成的名称');
    expect(saved.rules, '轮流接话');
  });

  test('电脑剔除已删的 Bot 时照样算保存成功，多出的成员仍算未确认', () async {
    var returned = ['宝'];
    final saver = GroupProfileSaver(
      desktop: '电脑',
      saved: const LinkGroup(id: '群', name: '合成群', members: ['宝', '已删']),
      request: (_, _, params) async => {
        'group': {...params, 'id': '群', 'members': returned},
      },
    );
    final saved = await saver.save(
      name: '合成群',
      members: ['宝', '已删'],
      passes: 10,
      rules: '',
      gap: 0,
    );
    expect(saved.members, ['宝']);
    returned = ['宝', '外人'];
    await expectLater(
      saver.save(name: '合成群', members: ['宝'], passes: 10, rules: '', gap: 0),
      throwsA(isA<GroupSettingsUnconfirmed>()),
    );
  });

  test('创建群未确认由AppState保留，重开页面不重复创建，保存完整字段', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.start();
    var saves = 0;
    h.handle = (method, params) {
      expect(method, LinkMethods.saveGroup);
      saves++;
      expect(params['name'], '');
      expect(params['members'], ['宝']);
      expect(params['passes'], 0);
      expect(params['gap'], 2);
      expect(params['rules'], '轮流说话');
      return null; // 已发送但未返回有效身份，不自动重新创建。
    };
    final saver = h.state.groupProfileSaver(h.identity.id);
    await expectLater(
      saver.save(name: '', members: ['宝'], passes: 0, rules: '轮流说话', gap: 2),
      throwsFormatException,
    );
    final reopened = h.state.groupProfileSaver(h.identity.id);
    expect(reopened, same(saver));
    expect(reopened.creationUnconfirmed, isTrue);
    await expectLater(
      reopened.save(name: '', members: ['宝'], passes: 0, rules: '轮流说话', gap: 2),
      throwsStateError,
    );
    expect(saves, 1);
    reopened.useExisting(const LinkGroup(id: '已创建', name: '合成群'));
    expect(reopened.creationUnconfirmed, isFalse);
  });
}
