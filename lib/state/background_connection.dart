import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 服务状态与后台事件循环连续性；不创建第二条电脑连接。
class BackgroundConnection extends ChangeNotifier {
  BackgroundConnection({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const channel = MethodChannel('local.baocode.mobile/background');
  final DateTime Function() _now;
  bool running = false;

  Object? error;
  VoidCallback? onNetworkChanged;

  /// [userStopped] 为 true 是用户在通知上按了停止，false 是系统结束的。
  void Function(bool userStopped)? onStopped;
  void Function(String desktopId, String sessionId)? onOpenTarget;
  DateTime? _started, _lastTick;
  Timer? _pulse;
  bool _continuous = false, _valid = false, _disposed = false;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    channel.setMethodCallHandler(_handle);
    try {
      _status(await channel.invokeMapMethod<String, Object?>('status'));
    } on MissingPluginException {
      // 无 Android 宿主时保活不可用，普通连接与恢复仍可使用。
    } on Object catch (failure) {
      reportError(failure);
    }
  }

  Future<void> _handle(MethodCall call) async {
    if (_disposed) return;
    if (call.method == 'networkChanged') {
      invalidate();
      onNetworkChanged?.call();
    } else if (call.method == 'openConversation') {
      final data = call.arguments;
      if (data is Map &&
          data['desktopId'] is String &&
          data['sessionId'] is String) {
        onOpenTarget?.call(
          data['desktopId'] as String,
          data['sessionId'] as String,
        );
      }
    } else if (call.method == 'statusChanged') {
      final data = call.arguments;
      final wasRunning = running;
      _status(data is Map ? data : null);
      if (wasRunning && !running) {
        onStopped?.call(data is Map && data['userStopped'] == true);
      }
    }
  }

  Future<void> start({
    required String title,
    required String body,
    required String stopLabel,
    String? shortText,
    String? desktopId,
    String? sessionId,
  }) async {
    try {
      final result = await channel.invokeMapMethod<String, Object?>('start', {
        'title': title,
        'body': body,
        'stopLabel': stopLabel,
        'shortText': ?shortText,
        'desktopId': ?desktopId,
        'sessionId': ?sessionId,
      });
      if (result?['running'] != true) {
        throw PlatformException(code: 'background_not_started');
      }
      error = null;
      _status(result);
    } on Object catch (failure) {
      reportError(failure);
      rethrow;
    }
  }

  /// 摘要变了才改通知；服务没在跑就什么也不做。失败不打扰用户。
  Future<void> update(Map<String, Object?> summary) async {
    if (_disposed || !running) return;
    try {
      await channel.invokeMethod<void>('update', summary);
    } on MissingPluginException {
      /* 无宿主的测试环境没有该插件。 */
    } on PlatformException {
      /* 摘要更新失败不影响连接。 */
    }
  }

  /// 用户在通知上按过「停止」而当时 Dart 没醒着：启动时读一次并清掉，
  /// 免得又被设置里的「开着」拉起来。
  Future<bool> takeUserStopped() async {
    try {
      return await channel.invokeMethod<bool>('takeUserStopped') == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      final result = await channel.invokeMapMethod<String, Object?>('stop');
      if (result?['running'] != false) {
        throw PlatformException(code: 'background_not_stopped');
      }
      error = null;
      _status(result);
    } on Object catch (failure) {
      reportError(failure);
      rethrow;
    }
  }

  void _status(Map? data) {
    if (_disposed) return;
    running = data?['running'] == true;
    if (data?['networkWatching'] == false) {
      error = PlatformException(code: 'network_unavailable');
      invalidate();
    }
    if (!running) {
      _continuous = false;
      _pulse?.cancel();
      _pulse = null;
    }
    notifyListeners();
  }

  void reportError(Object failure) {
    if (_disposed) return;
    error = failure;
    invalidate();
    notifyListeners();
  }

  void beginBackground() {
    _pulse?.cancel();
    _started = _lastTick = _now();
    _valid = true;
    _continuous = running;
    if (running) {
      _pulse = Timer.periodic(const Duration(seconds: 5), (_) {
        final now = _now();
        if (!_recent(now, _lastTick, const Duration(seconds: 12))) {
          _continuous = false;
        }
        _lastTick = now;
      });
    }
  }

  void invalidate() => _valid = false;

  /// 短暂切换或服务持续运行且事件循环未停顿，才允许复用同一连接的完整基线。
  bool finishBackground() {
    final now = _now();
    final reusable =
        _started != null &&
        _valid &&
        (_recent(now, _started, const Duration(seconds: 10)) ||
            (running &&
                _continuous &&
                _recent(now, _lastTick, const Duration(seconds: 12))));
    _pulse?.cancel();
    _pulse = null;
    _started = null;
    _valid = false;
    return reusable;
  }

  bool _recent(DateTime now, DateTime? before, Duration limit) {
    if (before == null) return false;
    final elapsed = now.difference(before);
    return !elapsed.isNegative && elapsed <= limit;
  }

  @override
  void dispose() {
    _disposed = true;
    _pulse?.cancel();
    if (_initialized) channel.setMethodCallHandler(null);
    super.dispose();
  }
}
