import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一个 mesh 节点的快照。
class MeshPeer {
  const MeshPeer({
    required this.name,
    required this.virtualIp,
    required this.url,
    required this.latencyMs,
    required this.direct,
    required this.cost,
    required this.rxBytes,
    required this.txBytes,
  });

  final String name;
  final String virtualIp;
  final String url;
  final double latencyMs;
  final bool direct;
  final int cost;
  final int rxBytes;
  final int txBytes;

  factory MeshPeer.fromJson(Map<dynamic, dynamic> j) => MeshPeer(
    name: '${j['name'] ?? ''}',
    virtualIp: '${j['virtualIp'] ?? ''}',
    url: '${j['url'] ?? ''}',
    latencyMs: (j['latencyMs'] as num?)?.toDouble() ?? -1,
    direct: j['direct'] == true,
    cost: (j['cost'] as num?)?.toInt() ?? -1,
    rxBytes: (j['rxBytes'] as num?)?.toInt() ?? 0,
    txBytes: (j['txBytes'] as num?)?.toInt() ?? 0,
  );

  String get latencyLabel =>
      latencyMs < 0 ? '—' : '${latencyMs.toStringAsFixed(1)} ms';
  String get linkLabel => direct ? '直连' : '中继';
}

/// 一次流量采样（相对上一次的增量）。
class MeshTrafficSample {
  const MeshTrafficSample({
    required this.virtualIp,
    required this.name,
    required this.rxDelta,
    required this.txDelta,
    required this.at,
  });

  final String virtualIp;
  final String name;
  final int rxDelta;
  final int txDelta;
  final DateTime at;

  factory MeshTrafficSample.fromJson(Map<dynamic, dynamic> j) =>
      MeshTrafficSample(
        virtualIp: '${j['virtualIp'] ?? ''}',
        name: '${j['name'] ?? ''}',
        rxDelta: (j['rxDelta'] as num?)?.toInt() ?? 0,
        txDelta: (j['txDelta'] as num?)?.toInt() ?? 0,
        at: DateTime.now(),
      );
}

/// 一次连通性探测结果。
class MeshProbeResult {
  const MeshProbeResult({
    required this.host,
    required this.port,
    required this.ok,
    required this.latencyMs,
    required this.error,
  });

  final String host;
  final int port;
  final bool ok;
  final int latencyMs;
  final String error;

  factory MeshProbeResult.fromJson(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return MeshProbeResult(
        host: '${m['host'] ?? ''}',
        port: (m['port'] as num?)?.toInt() ?? 0,
        ok: m['ok'] == true,
        latencyMs: (m['latency_ms'] as num?)?.toInt() ?? -1,
        error: '${m['error'] ?? ''}',
      );
    } catch (_) {
      return MeshProbeResult(
        host: '',
        port: 0,
        ok: false,
        latencyMs: -1,
        error: raw,
      );
    }
  }
}

/// EasyTier 官方公共节点（共享中继）。用它是公开契约，不含任何私有网络信息。
///
/// 用户可以在界面上改成自己的节点，这里只是「没填时用它」的默认值。
const defaultEasyTierPeers = <String>['tcp://public.easytier.top:11010'];

/// 组网配置：网络名 / 密钥 / 虚拟 IP / 主机名 / peer 列表。
class MeshConfig {
  const MeshConfig({
    this.networkName = 'easytier',
    this.secret = '',
    this.ipv4 = '10.126.126.1/24',
    this.hostname = '',
    this.peers = defaultEasyTierPeers,
  });

  final String networkName;
  final String secret;
  final String ipv4;
  final String hostname;
  final List<String> peers;

  bool get isValid =>
      networkName.trim().isNotEmpty &&
      secret.trim().isNotEmpty &&
      ipv4.contains('/') &&
      peers.any((p) => p.trim().isNotEmpty);

  MeshConfig copyWith({
    String? networkName,
    String? secret,
    String? ipv4,
    String? hostname,
    List<String>? peers,
  }) => MeshConfig(
    networkName: networkName ?? this.networkName,
    secret: secret ?? this.secret,
    ipv4: ipv4 ?? this.ipv4,
    hostname: hostname ?? this.hostname,
    peers: peers ?? this.peers,
  );
}

/// EasyTier 组网控制器：原生桥的 Dart 侧门面。
///
/// 状态由原生主动推送（EventChannel），这里只做缓存和分发；
/// 流量采样在 Dart 侧累积成历史，原生只给增量。
class MeshController extends ChangeNotifier {
  MeshController._();

  static final MeshController instance = MeshController._();

  static const _methods = MethodChannel('local.fromsko.mobile/mesh');
  static const _events = EventChannel('local.fromsko.mobile/mesh_state');

  StreamSubscription<dynamic>? _sub;
  bool _started = false;

  String _engine = 'IDLE';
  String _message = '';
  String _selfIp = '';
  List<MeshPeer> _peers = const [];
  List<Map<dynamic, dynamic>> _routes = const [];
  Map<dynamic, dynamic> _stats = const {};

  /// 每个 IP 的本次会话累计流量。
  final Map<String, MeshTrafficSample> _traffic = {};
  final List<MeshTrafficSample> _trafficHistory = [];

  String get engine => _engine;
  String get message => _message;
  String get selfIp => _selfIp;
  List<MeshPeer> get peers => List.unmodifiable(_peers);
  List<Map<dynamic, dynamic>> get routes => List.unmodifiable(_routes);
  Map<dynamic, dynamic> get stats => _stats;
  bool get running => _engine == 'RUNNING';

  /// 每个节点的累计流量（本次会话）。
  List<MeshTrafficSample> get traffic => List.unmodifiable(_traffic.values);

  /// 最近 200 条采样，按时间正序。
  List<MeshTrafficSample> get trafficHistory =>
      List.unmodifiable(_trafficHistory);

  int get totalRx => _traffic.values.fold(0, (a, s) => a + s.rxDelta);
  int get totalTx => _traffic.values.fold(0, (a, s) => a + s.txDelta);

  Future<void> ensureListening() async {
    if (_started) return;
    _started = true;
    _sub = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) {
        _engine = 'ERROR';
        _message = '$e';
        notifyListeners();
      },
    );
    await refresh();
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    final m = Map<dynamic, dynamic>.from(raw);
    if (m.containsKey('engine')) _engine = '${m['engine']}';
    if (m.containsKey('message')) _message = '${m['message'] ?? ''}';
    if (m.containsKey('self')) _selfIp = '${m['self'] ?? ''}';
    if (m.containsKey('peers')) {
      _peers = (m['peers'] as List<dynamic>)
          .map((e) => MeshPeer.fromJson(e as Map))
          .toList();
    }
    if (m.containsKey('routes')) {
      _routes = (m['routes'] as List<dynamic>)
          .map((e) => Map<dynamic, dynamic>.from(e as Map))
          .toList();
    }
    if (m.containsKey('stats')) {
      _stats = Map<dynamic, dynamic>.from(m['stats'] as Map);
    }
    _accumulateTraffic(m['samples']);
    notifyListeners();
  }

  void _accumulateTraffic(dynamic samples) {
    if (samples is! List) return;
    for (final s in samples) {
      if (s is! Map) continue;
      final sample = MeshTrafficSample.fromJson(s);
      if (sample.rxDelta == 0 && sample.txDelta == 0) continue;
      final prev = _traffic[sample.virtualIp];
      _traffic[sample.virtualIp] = MeshTrafficSample(
        virtualIp: sample.virtualIp,
        name: sample.name,
        rxDelta: (prev?.rxDelta ?? 0) + sample.rxDelta,
        txDelta: (prev?.txDelta ?? 0) + sample.txDelta,
        at: sample.at,
      );
      _trafficHistory.add(sample);
    }
    while (_trafficHistory.length > 200) {
      _trafficHistory.removeAt(0);
    }
  }

  Future<void> refresh() async {
    try {
      final raw = await _methods.invokeMethod<dynamic>('status');
      if (raw is Map) _onEvent(raw);
    } catch (_) {
      // 原生未就绪时静默，等事件流推。
    }
  }

  /// 申请系统 VPN 授权。返回 true 表示已授权可直接启动。
  Future<bool> prepareVpn() async {
    try {
      return await _methods.invokeMethod<bool>('prepareVpn') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 启动组网。返回 null 表示受理成功，否则是错误描述。
  Future<String?> start(MeshConfig cfg) async {
    if (!cfg.isValid) return '配置不完整';
    try {
      return await _methods.invokeMethod<String>('start', {
        'networkName': cfg.networkName,
        'secret': cfg.secret,
        'ipv4': cfg.ipv4,
        'hostname': cfg.hostname,
        'peers': cfg.peers,
      });
    } catch (e) {
      return '$e';
    }
  }

  Future<void> stop() async {
    await _methods.invokeMethod<void>('stop');
    _traffic.clear();
    _trafficHistory.clear();
    notifyListeners();
  }

  /// 对指定节点做 TCP 连通性探测（真建连）。
  Future<MeshProbeResult> probe(
    String host,
    int port, {
    int timeoutMs = 2000,
  }) async {
    final raw = await _methods.invokeMethod<String>('probe', {
      'host': host,
      'port': port,
      'timeoutMs': timeoutMs,
    });
    return MeshProbeResult.fromJson(raw ?? '{}');
  }

  /// 对指定节点做 HTTP GET（验证应用层，不止握手）。
  Future<MeshProbeResult> httpGet(
    String host,
    int port,
    String path, {
    int timeoutMs = 3000,
  }) async {
    final raw = await _methods.invokeMethod<String>('httpGet', {
      'host': host,
      'port': port,
      'path': path,
      'timeoutMs': timeoutMs,
    });
    return MeshProbeResult.fromJson(raw ?? '{}');
  }

  /// 批量探测所有在线节点（端口自定义）。
  Future<List<MeshProbeResult>> probeAll(int port) async {
    final out = <MeshProbeResult>[];
    for (final p in _peers) {
      if (p.virtualIp.isEmpty) continue;
      out.add(await probe(p.virtualIp, port));
    }
    return out;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
