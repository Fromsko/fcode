import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:fromsko_mobile/link/phone_link.dart';
import 'package:fromsko_mobile/state/app_state.dart';
import 'package:fromsko_mobile/state/background_connection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Link extends PhoneLink {
  _Link() : super(store: MemoryLinkStore());
  int checks = 0, generation = 0;

  /// 探测期间连接断了一次又接上：真实恢复里代次就是这样变的。
  bool reconnectDuringCheck = false;
  @override
  Future<void> initialize() async {}
  @override
  int connectionGenerationOf(String desktopId) => generation;
  final online = <String>{'desk'};
  @override
  Set<String> get onlineIds => online;
  @override
  List<KeptDesktop> get desktops => const [
    KeptDesktop(id: 'desk', name: '合成电脑', publicKey: ''),
  ];
  @override
  void networkChanged() {}
  @override
  Future<void> verifyConnections({
    Duration timeout = const Duration(seconds: 4),
    Duration quietFor = const Duration(seconds: 2),
  }) async {
    checks++;
    if (reconnectDuringCheck) {
      reconnectDuringCheck = false;
      // 断线再连上：离线一瞬再上线，订阅层据此重开。
      online.remove('desk');
      notifyListeners();
      online.add('desk');
      generation++;
      notifyListeners();
    }
  }
}

class _State extends AppState {
  _State(_Link link, {super.background, MemoryLinkStore? store})
    : super(store: store ?? MemoryLinkStore(), link: link);
  final opens = <String>[];
  Completer<void>? pending;
  bool fail = false;
  String text = '旧内容';
  bool online = true;
  @override
  bool isOnline(String desktopId) => online;
  @override
  Future<Object?> request(
    String desktopId,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    if (method == LinkMethods.close) return null;
    if (method != LinkMethods.open) {
      if (method == LinkMethods.state) {
        return {
          'device': {'name': '合成电脑'},
          'projects': <Object?>[],
          'bots': <Object?>[],
        };
      }
      throw StateError('这里只允许同步读取：$method');
    }
    opens.add(params['session']! as String);
    await pending?.future;
    if (fail) throw StateError('会话同步失败');
    return {
      'session': params['session'],
      'start': 0,
      'count': 1,
      'items': [
        {'t': 'text', 'text': text},
      ],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platform = MethodChannel('local.fromsko.mobile/platform');
  const discovery = MethodChannel('local.fromsko.mobile/discovery');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(platform, (_) async => null);
    messenger.setMockMethodCallHandler(discovery, (_) async => null);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(platform, null);
    messenger.setMockMethodCallHandler(discovery, null);
  });

  test('冷启动时设置开着而服务没跑：在前台把它启动起来', () async {
    final nativeCalls = <String>[];
    var running = false;
    messenger.setMockMethodCallHandler(BackgroundConnection.channel, (
      call,
    ) async {
      nativeCalls.add(call.method);
      if (call.method == 'start') running = true;
      if (call.method == 'takeUserStopped') return false;
      return {'running': running, 'networkWatching': true};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        BackgroundConnection.channel,
        null,
      ),
    );
    final state = _State(_Link())..settings.keepBackgroundConnection = true;
    addTearDown(state.dispose);
    await state.initialize();
    expect(state.startupError, isNull);
    expect(nativeCalls, ['status', 'takeUserStopped', 'start']);
    expect(state.settings.keepBackgroundConnection, isTrue);
    expect(state.background.running, isTrue);
  });

  test('用户在通知上按过停止：冷启动不再按设置拉起', () async {
    final nativeCalls = <String>[];
    messenger.setMockMethodCallHandler(BackgroundConnection.channel, (
      call,
    ) async {
      nativeCalls.add(call.method);
      if (call.method == 'takeUserStopped') return true;
      return {'running': false, 'networkWatching': true};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        BackgroundConnection.channel,
        null,
      ),
    );
    final store = MemoryLinkStore();
    final state = _State(_Link(), store: store)
      ..settings.keepBackgroundConnection = true;
    addTearDown(state.dispose);
    await state.initialize();
    expect(nativeCalls, ['status', 'takeUserStopped']);
    expect(state.settings.keepBackgroundConnection, isFalse);
    expect(
      jsonDecode((await store.read('settings'))!)['keepBackgroundConnection'],
      isFalse,
      reason: '停止要存下来，下次冷启动不再自己打开',
    );
  });

  test('短暂切应用且同一连接基线完整时，合并探测但不重复拉快照', () async {
    final link = _Link();
    final state = _State(link);
    addTearDown(state.dispose);
    await state.openSession('desk', 'active');
    state.opens.clear();
    state.setForeground(false);
    state.setForeground(true);
    await Future.wait([state.resume(), state.resume()]);
    expect(state.opens, isEmpty);
    expect(link.checks, 1);
    expect(state.buffer('desk', 'active').items.single, {
      't': 'text',
      'text': '旧内容',
    });
    expect(state.buffer('desk', 'active').loading, isFalse);
  });

  test('连接代次变化时仍拉快照，不能只信在线状态', () async {
    var now = DateTime(2026);
    final link = _Link();
    final state = _State(
      link,
      background: BackgroundConnection(now: () => now),
    );
    addTearDown(state.dispose);
    await state.openSession('desk', 'active');
    state.opens.clear();
    state.setForeground(false);
    now = now.add(const Duration(minutes: 2));
    state.setForeground(true);
    // 后台间隔不确定不影响判断：探测通过、代次未变，就信这条连接。
    await state.resume();
    expect(state.opens, isEmpty);
    state.setForeground(false);
    link.reconnectDuringCheck = true;
    state.setForeground(true);
    await state.resume();
    expect(state.opens, ['active']);
  });

  test('同一连接恢复后不再重开会话，探测期间重连过才重开', () async {
    final link = _Link();
    final state = _State(link);
    addTearDown(state.dispose);
    await state.openSession('desk', 'active');
    state.opens.clear();
    state.setForeground(false);
    state.setForeground(true);
    await state.resume();
    expect(state.opens, isEmpty);
    state.setForeground(false);
    link.reconnectDuringCheck = true;
    state.setForeground(true);
    await state.resume();
    expect(state.opens, ['active']);
  });

  test('切网后即使连接代次没有变化，也不能跳过内容核对', () async {
    final state = _State(_Link());
    addTearDown(state.dispose);
    await state.openSession('desk', 'active');
    state.opens.clear();
    state.setForeground(false);
    state.networkChanged();
    state.setForeground(true);
    await state.resume();
    expect(state.opens, ['active']);
  });

  test('未建立完整基线时，短暂切换也会重试，不把旧缓存当成已同步', () async {
    final state = _State(_Link())..fail = true;
    addTearDown(state.dispose);
    await expectLater(state.openSession('desk', 'active'), throwsStateError);
    state.opens.clear();
    state.fail = false;
    state.setForeground(false);
    state.setForeground(true);
    await state.resume();
    expect(state.opens, ['active']);
    expect(state.buffer('desk', 'active').error, isNull);
  });

  test('同一连接下重复唤醒不再开订阅，也不拉无订阅缓存', () async {
    final link = _Link();
    final state = _State(link);
    addTearDown(state.dispose);
    await state.openSession('desk', 'active');
    state.buffer('desk', 'closed').items.add({'t': 'text', 'text': '旧缓存'});
    state.opens.clear();
    state.text = '最新内容';
    final first = state.resume();
    final second = state.resume();
    await Future.wait([first, second]);
    expect(state.opens, isEmpty);
    expect(link.checks, 1);
    expect(state.buffer('desk', 'active').loading, isFalse);
    expect(state.buffer('desk', 'active').items.single, {
      't': 'text',
      'text': '旧内容',
    });
    expect(state.buffer('desk', 'closed').items.single, {
      't': 'text',
      'text': '旧缓存',
    });
  });

  test('连接换了之后回前台同步一次，重复唤醒合并且不重开', () async {
    final link = _Link();
    final state = _State(link);
    addTearDown(state.dispose);
    await state.openSession('desk', 'active');
    state.opens.clear();
    state.text = '最新内容';
    state.pending = Completer<void>();
    link.reconnectDuringCheck = true;
    final first = state.resume();
    final second = state.resume();
    await Future<void>.delayed(Duration.zero);
    expect(state.opens, ['active']);
    expect(link.checks, 1);
    expect(state.buffer('desk', 'active').loading, isTrue);
    expect(state.buffer('desk', 'active').items.single, {
      't': 'text',
      'text': '旧内容',
    });
    state.pending!.complete();
    await Future.wait([first, second]);
    expect(state.buffer('desk', 'active').items.single, {
      't': 'text',
      'text': '最新内容',
    });
    expect(state.buffer('desk', 'active').loading, isFalse);
  });

  test('回前台同步失败保留旧内容与错误，不自动重放请求', () async {
    final link = _Link();
    final state = _State(link);
    addTearDown(state.dispose);
    await state.openSession('desk', 'active');
    state.opens.clear();
    state.fail = true;
    link.reconnectDuringCheck = true;
    await state.resume();
    final buffer = state.buffer('desk', 'active');
    expect(state.opens, ['active']);
    expect(buffer.items.single, {'t': 'text', 'text': '旧内容'});
    expect(buffer.loading, isFalse);
    // 界面显示归类后的一句话，原始异常不再直接铺在界面上。
    expect(buffer.error, isNotEmpty);
    expect(buffer.error, isNot(contains('会话同步失败')));
  });
}
