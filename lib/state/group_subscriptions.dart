import 'dart:async';
import 'dart:math' as math;

import 'package:bao_link/bao_link.dart';

import '../models/session_buffer.dart';
import 'session_subscriptions.dart' show SessionRequest;

class GroupBuffer {
  final List<LinkGroupMessage> messages = [];
  bool loading = false, loadingEarlier = false, more = false;
  bool unsupported = false;

  /// 打开/刷新失败：整页不可用。
  String? error;

  /// 只影响取更早的那一页，列表和输入都还能用。
  String? earlierError;
  int revision = 0;

  void merge(Iterable<LinkGroupMessage> incoming, {bool replace = false}) {
    final bySeq = <int, LinkGroupMessage>{
      if (!replace)
        for (final message in messages) message.seq: message,
      for (final message in incoming) message.seq: message,
    };
    messages
      ..clear()
      ..addAll(bySeq.values.toList()..sort((a, b) => a.seq.compareTo(b.seq)));
    revision++;
  }
}

/// 群消息有独立 seq，不借用或删改会话 Mirror 的 wire 数组。
class GroupSubscriptions {
  GroupSubscriptions({
    required this.request,
    required this.onChanged,
    required this.tr,
  });
  final SessionRequest request;
  final void Function() onChanged;
  final String Function(String, String) tr;
  final _lanes = <(String, String), _GroupLane>{};
  bool _disposed = false;

  GroupBuffer buffer(String desktop, String group) =>
      _lanes.putIfAbsent((desktop, group), _GroupLane.new).buffer;

  Future<void> retain(String desktop, String group) {
    final lane = _lanes.putIfAbsent((desktop, group), _GroupLane.new);
    lane.owners++;
    return lane.owners == 1
        ? _open(desktop, group, lane)
        : lane.opening ?? Future.value();
  }

  Future<void> refresh(String desktop, String group) {
    final lane = _lanes[(desktop, group)];
    if (lane == null || lane.owners == 0) return Future.value();
    return lane.opening ?? _open(desktop, group, lane);
  }

  Future<void> refreshRetained(
    bool Function(String desktop) isOnline, {
    bool Function(String desktop, String group)? keepCurrent,
  }) async {
    await Future.wait([
      for (final entry in _lanes.entries.toList())
        if (entry.value.owners > 0 &&
            isOnline(entry.key.$1) &&
            !(keepCurrent?.call(entry.key.$1, entry.key.$2) == true &&
                entry.value.hasBaseline &&
                entry.value.buffer.error == null))
          refresh(entry.key.$1, entry.key.$2),
    ]);
  }

  Future<void> _open(
    String desktop,
    String group,
    _GroupLane lane, {
    bool retry = false,
  }) {
    final generation = ++lane.generation;
    lane.pending.clear();
    if (!retry) {
      lane.retry?.cancel();
      lane.retry = null;
      lane.retries = 0;
      lane.buffer
        ..loading = true
        ..error = null
        ..earlierError = null;
    }
    _changed();
    // close 和重新 open 串行，不让旧页面迟到的 close 关闭新订阅。
    final operation = lane.operations.then((_) async {
      if (!_current(lane, generation)) return;
      final loaded = List.of(lane.buffer.messages);
      final baseline = lane.hasBaseline && loaded.isNotEmpty;
      try {
        final result = objectMap(
          await request(desktop, LinkMethods.openGroup, {
            'group': group,
            // 已经翻出来的不再全要：这一页接得上就只补新的。
            'count': !baseline ? (loaded.length > 50 ? loaded.length : 50) : 50,
          }),
        );
        if (!_current(lane, generation)) return;
        final messages = _messages(result);
        lane.hasBaseline = true;
        lane.retries = 0;
        lane.buffer.unsupported = false;
        if (baseline && _overlaps(loaded, messages)) {
          // `more` 说的是最老那一页，补新消息时不动它。
          lane.buffer.merge([...messages, ...lane.pending]);
        } else {
          lane.buffer
            ..merge([...messages, ...lane.pending], replace: true)
            ..more = result['more'] == true;
        }
        lane.buffer.error = null;
      } on Object catch (error) {
        if (!_current(lane, generation)) return;
        lane.buffer.unsupported =
            error is LinkRemoteException &&
            (error.code == LinkErrors.unknown ||
                error.code == LinkErrors.unsupported);
        lane.buffer.error = lane.buffer.unsupported
            ? tr(
                '此电脑不支持群聊，请更新电脑端。',
                'This desktop does not support groups. Update it first.',
              )
            : tr(
                '群消息未更新，请核对连接后重试。',
                'Group messages were not refreshed. Check the connection and retry.',
              );
        if (!lane.buffer.unsupported) {
          _retryLater(desktop, group, lane, generation);
        }
      } finally {
        if (_current(lane, generation)) {
          lane.pending.clear();
          lane.buffer.loading = false;
          _changed();
        }
      }
    });
    lane.operations = operation.catchError((Object _) {});
    final opening = operation.whenComplete(() {
      if (lane.generation == generation) lane.opening = null;
    });
    lane.opening = opening;
    return opening;
  }

  /// 网络抖一下就在同一条连接上再试，最多三次；错误提示一直留着。
  void _retryLater(
    String desktop,
    String group,
    _GroupLane lane,
    int generation,
  ) {
    if (lane.retries >= 3) return;
    lane.retry?.cancel();
    lane.retry = Timer(Duration(seconds: 2 << lane.retries), () {
      lane.retry = null;
      if (!_current(lane, generation)) return;
      lane.retries++;
      unawaited(_open(desktop, group, lane, retry: true));
    });
  }

  void accept(String desktop, Object? value) {
    final params = objectMap(value);
    final group = params['group'];
    if (group is! String) return;
    final lane = _lanes[(desktop, group)];
    if (lane == null || lane.owners == 0 || !lane.connected) return;
    try {
      final incoming = _messages(params);
      if (lane.buffer.loading) {
        lane.pending.addAll(incoming);
      } else {
        lane.buffer.merge(incoming);
      }
      _changed();
    } on FormatException {
      lane.buffer.error = tr(
        '群消息格式无效，请重新加载。',
        'Invalid group messages. Reload the group.',
      );
      _changed();
    }
  }

  Future<void> earlier(String desktop, String group) async {
    final lane = _lanes[(desktop, group)];
    if (lane == null ||
        lane.owners == 0 ||
        lane.buffer.loading ||
        lane.buffer.loadingEarlier ||
        !lane.buffer.more ||
        lane.buffer.messages.isEmpty) {
      return;
    }
    final generation = lane.generation;
    final before = lane.buffer.messages.first.seq;
    lane.buffer
      ..loadingEarlier = true
      ..earlierError = null;
    _changed();
    try {
      final result = objectMap(
        await request(desktop, LinkMethods.earlierGroup, {
          'group': group,
          'before': before,
          'count': 50,
        }),
      );
      if (!_current(lane, generation)) return;
      lane.buffer
        ..merge(_messages(result))
        ..more = result['more'] == true;
    } on Object {
      if (_current(lane, generation)) {
        lane.buffer.earlierError = tr(
          '更早的群消息未加载，请重试。',
          'Earlier group messages could not be loaded. Retry.',
        );
      }
    } finally {
      if (_current(lane, generation)) {
        lane.buffer.loadingEarlier = false;
        _changed();
      }
    }
  }

  Future<void> release(String desktop, String group) {
    final lane = _lanes[(desktop, group)];
    if (lane == null || lane.owners == 0) return Future.value();
    if (--lane.owners > 0) return Future.value();
    final generation = ++lane.generation;
    lane.opening = null;
    lane.retry?.cancel();
    lane.retry = null;
    lane.pending.clear();
    lane.buffer
      ..loading = false
      ..loadingEarlier = false;
    final operation = lane.operations.then((_) async {
      if (!lane.connected || _disposed || lane.generation != generation) return;
      try {
        await request(desktop, LinkMethods.closeGroup, {'group': group});
      } on Object {
        /* 不重放。 */
      }
    });
    lane.operations = operation;
    return operation;
  }

  void connectionChanged(String desktop, {required bool online}) {
    for (final entry in _lanes.entries.where(
      (entry) => entry.key.$1 == desktop,
    )) {
      final lane = entry.value;
      lane.connected = online;
      lane.hasBaseline = false;
      lane.generation++;
      lane.opening = null;
      lane.retry?.cancel();
      lane.retry = null;
      lane.retries = 0;
      lane.pending.clear();
      // 新连接不能等旧连接上永远不返回的请求。
      lane.operations = Future.value();
      lane.buffer
        ..loading = false
        ..loadingEarlier = false;
      if (online && lane.owners > 0) {
        unawaited(_open(desktop, entry.key.$2, lane));
      }
    }
    _changed();
  }

  void forget(String desktop) {
    for (final lane
        in _lanes.entries
            .where((e) => e.key.$1 == desktop)
            .map((e) => e.value)) {
      lane.generation++;
      lane.owners = 0;
      lane.retry?.cancel();
      lane.retry = null;
    }
    _lanes.removeWhere((key, _) => key.$1 == desktop);
  }

  bool _current(_GroupLane lane, int generation) =>
      !_disposed &&
      lane.connected &&
      lane.owners > 0 &&
      lane.generation == generation;
  void _changed() {
    if (!_disposed) onChanged();
  }

  void dispose() {
    _disposed = true;
    for (final lane in _lanes.values) {
      lane.retry?.cancel();
      lane.retry = null;
    }
    _lanes.clear();
  }

  /// 返回的这一页接得上已翻出来的范围，且重合的序号内容一致。
  static bool _overlaps(
    List<LinkGroupMessage> loaded,
    List<LinkGroupMessage> page,
  ) {
    if (loaded.isEmpty || page.isEmpty) return false;
    final loadedFirst = loaded.map((m) => m.seq).reduce(math.min);
    final loadedLast = loaded.map((m) => m.seq).reduce(math.max);
    final oldest = page.map((m) => m.seq).reduce(math.min);
    if (oldest < loadedFirst || oldest > loadedLast + 1) return false;
    final known = {for (final message in loaded) message.seq: message};
    for (final message in page) {
      final before = known[message.seq];
      if (before != null &&
          (before.text != message.text || before.from != message.from)) {
        return false;
      }
    }
    return true;
  }

  static List<LinkGroupMessage> _messages(Map<String, Object?> result) {
    if (result['messages'] is! List) throw const FormatException('缺少群消息');
    return [
      for (final item in result['messages'] as List)
        if (item is Map<String, Object?>)
          LinkGroupMessage.fromJson(item)
        else
          throw const FormatException('群消息格式无效'),
    ];
  }
}

class _GroupLane {
  final buffer = GroupBuffer();
  final pending = <LinkGroupMessage>[];
  int owners = 0, generation = 0, retries = 0;
  bool connected = true, hasBaseline = false;
  Future<void> operations = Future.value();
  Future<void>? opening;
  Timer? retry;
}

/// 身份已确认，但电脑未确认请求中的整份群设置。
class GroupSettingsUnconfirmed implements Exception {
  const GroupSettingsUnconfirmed();
}

/// 整份保存，创建未确认时由 AppState 持有，退出表单也不自动重建。
class GroupProfileSaver {
  GroupProfileSaver({required this.request, required this.desktop, this.saved});
  final SessionRequest request;
  final String desktop;
  LinkGroup? saved;
  bool creationUnconfirmed = false, busy = false;
  void useExisting(LinkGroup group) {
    if (busy || group.id.isEmpty) throw StateError('不能绑定群聊');
    saved = group;
    creationUnconfirmed = false;
  }

  Future<LinkGroup> save({
    required String name,
    required List<String> members,
    required int passes,
    required String rules,
    required int gap,
  }) async {
    if (busy || creationUnconfirmed) throw StateError('请先核对上次创建结果');
    busy = true;
    final creating = saved == null;
    final expectedPasses = passes == 0
        ? 0
        : passes.clamp(linkGroupLeastPasses, 1 << 20);
    final expectedGap = gap < 0 ? 0 : gap;
    final expectedMembers = members.toSet();
    try {
      final result = objectMap(
        await request(desktop, LinkMethods.saveGroup, {
          'group': ?saved?.id,
          'name': name.trim(),
          'members': expectedMembers.toList(),
          'passes': expectedPasses,
          'rules': rules.trim(),
          'gap': expectedGap,
        }),
      );
      if (result['group'] is! Map<String, Object?>) {
        throw const FormatException('群保存结果未确认');
      }
      final actual = LinkGroup.fromJson(
        result['group'] as Map<String, Object?>,
      );
      if (actual.id.isEmpty || (!creating && actual.id != saved!.id)) {
        throw const FormatException('群保存身份未确认');
      }
      saved = actual;
      // 电脑会剔除已删掉的 Bot，所以成员只要求是送去的那些里的。
      if ((name.trim().isNotEmpty && actual.name != name.trim()) ||
          !actual.members.every(expectedMembers.contains) ||
          actual.passes != expectedPasses ||
          actual.rules != rules.trim() ||
          actual.gap != expectedGap) {
        throw const GroupSettingsUnconfirmed();
      }
      return actual;
    } on LinkRemoteException {
      rethrow;
    } on Object {
      if (creating && saved == null) creationUnconfirmed = true;
      rethrow;
    } finally {
      busy = false;
    }
  }
}
