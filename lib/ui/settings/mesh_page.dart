import 'dart:async';

import 'package:flutter/material.dart';

import '../../link/link_store.dart';
import '../../mesh/mesh_controller.dart';
import '../../mesh/mesh_store.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../widgets/lucide_icon.dart';
import '../widgets/mobile_widgets.dart';

/// 组网设置页：EasyTier 的配置、状态、节点、流量与连通性探测。
class MeshPage extends StatefulWidget {
  const MeshPage({super.key, required this.state});
  final AppState state;

  @override
  State<MeshPage> createState() => _MeshPageState();
}

class _MeshPageState extends State<MeshPage> {
  final MeshController _mesh = MeshController.instance;
  MeshStore? _store;
  Timer? _ticker;

  final _netName = TextEditingController();
  final _secret = TextEditingController();
  final _ipv4 = TextEditingController();
  final _hostname = TextEditingController();
  final _peers = TextEditingController();

  bool _busy = false;

  /// 每个节点的探测结果：IP → 一行结论。按节点就近显示，不堆在页尾。
  final Map<String, String> _probes = {};
  final Set<String> _probing = {};

  /// 探测用的端口，默认 SSH；改它就能探别的服务。
  int _probePort = 22;

  /// 配置卡是否展开。null 表示「跟随连接状态」：断开时展开，连上后收起。
  bool? _configOpen;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final store = await MeshStore.load(PlatformLinkStore());
    if (!mounted) return;
    final cfg = store.config;
    _netName.text = cfg.networkName;
    _secret.text = cfg.secret;
    _ipv4.text = cfg.ipv4;
    _hostname.text = cfg.hostname;
    _peers.text = cfg.peers.join('\n');
    setState(() => _store = store);
    await _mesh.ensureListening();
    // 每 2 秒刷新一次，让延迟与流量走字。
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && _mesh.running) _mesh.refresh();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _netName.dispose();
    _secret.dispose();
    _ipv4.dispose();
    _hostname.dispose();
    _peers.dispose();
    super.dispose();
  }

  MeshConfig _readForm() => MeshConfig(
    networkName: _netName.text.trim(),
    secret: _secret.text,
    ipv4: _ipv4.text.trim(),
    hostname: _hostname.text.trim(),
    peers: _peers.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(),
  );

  Future<void> _start() async {
    final cfg = _readForm();
    if (!cfg.isValid) {
      _snack('配置不完整：网络名、密钥、带掩码的 IP、至少一个 peer 都要填');
      return;
    }
    setState(() => _busy = true);
    try {
      final authorized = await _mesh.prepareVpn();
      if (!authorized) {
        _snack('请在系统弹窗里允许 VPN，然后再点一次启动');
        return;
      }
      await _store?.save(cfg);
      final err = await _mesh.start(cfg);
      if (err != null) {
        _snack('启动失败：$err');
      } else {
        _snack('已受理，正在建链…');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await _mesh.stop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _probePeer(MeshPeer p) async {
    if (p.virtualIp.isEmpty) return;
    setState(() => _probing.add(p.virtualIp));
    try {
      final r = await _mesh.probe(p.virtualIp, _probePort);
      if (!mounted) return;
      setState(() {
        _probes[p.virtualIp] = r.ok
            ? ':$_probePort 通 · ${r.latencyMs}ms'
            : ':$_probePort 不通';
      });
    } finally {
      if (mounted) setState(() => _probing.remove(p.virtualIp));
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Scaffold(
      appBar: AppBar(title: Text(s.tr('组网', 'Mesh'))),
      body: ListenableBuilder(
        listenable: _mesh,
        builder: (context, _) {
          final running = _mesh.running;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
            children: [
              _statusCard(s),
              const SizedBox(height: 16),
              // 连上时节点在最前面；没连时先给配置，别让人对着空列表。
              if (running) ...[
                _peersCard(s),
                const SizedBox(height: 16),
                _trafficCard(s),
                const SizedBox(height: 16),
                _configCard(s, running),
              ] else
                _configCard(s, running),
            ],
          );
        },
      ),
    );
  }

  Widget _statusCard(AppState s) {
    final running = _mesh.running;
    final scheme = Theme.of(context).colorScheme;
    final accent = switch (_mesh.engine) {
      'RUNNING' => const Color(0xFF07C160),
      'ERROR' => scheme.error,
      'STARTING' => const Color(0xFFFFA726),
      _ => scheme.onSurfaceVariant,
    };
    return GroupCard(
      children: [
        ListTile(
          isThreeLine: running,
          leading: LucideIcon('route', size: 26, color: accent),
          title: Text(
            running
                ? s.tr('已连接', 'Connected')
                : switch (_mesh.engine) {
                    'STARTING' => s.tr('连接中…', 'Connecting…'),
                    'ERROR' => s.tr('连接失败', 'Failed'),
                    _ => s.tr('未连接', 'Not connected'),
                  },
            style: TextStyle(fontWeight: FontWeight.w600, color: accent),
          ),
          subtitle: running
              ? Text(
                  '${s.tr('本机', 'This device')} ${_mesh.selfIp.ifEmpty('—')}'
                  ' · ${_mesh.peers.length} ${s.tr('个节点', 'peers')}'
                  '\n↓${_fmt(_mesh.totalRx)} ↑${_fmt(_mesh.totalTx)}',
                )
              : Text(
                  _mesh.message.ifEmpty(
                    s.tr('填好网络名和密钥后连接', 'Set a network name and secret, then connect'),
                  ),
                  maxLines: 3,
                ),
          trailing: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : FilledButton(
                  onPressed: running ? _stop : _start,
                  style: FilledButton.styleFrom(
                    backgroundColor: running ? scheme.surfaceContainerHighest : accent,
                    foregroundColor: running ? scheme.onSurface : Colors.black,
                    minimumSize: const Size(76, 40),
                  ),
                  child: Text(running ? s.tr('断开', 'Stop') : s.tr('连接', 'Connect')),
                ),
        ),
      ],
    );
  }

  Widget _peersCard(AppState s) {
    final peers = _mesh.peers;
    final scheme = Theme.of(context).colorScheme;
    if (peers.isEmpty) {
      return GroupCard(
        children: [
          ListTile(
            leading: const LucideIcon('refresh-cw', size: 20),
            title: Text(s.tr('正在发现节点…', 'Looking for peers…')),
            subtitle: Text(
              s.tr('刚连上时通常几秒内出现', 'Usually appears within a few seconds'),
            ),
          ),
        ],
      );
    }
    return GroupCard(
      children: [
        ListTile(
          dense: true,
          title: Text(s.tr('节点', 'Peers'), style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            s.tr('点一行测这个端口的连通性', 'Tap a row to probe this port'),
          ),
          trailing: SizedBox(
            width: 84,
            child: TextFormField(
              initialValue: '$_probePort',
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: MobileType.aside),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                border: const OutlineInputBorder(),
                hintText: '22',
              ),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0 && n < 65536) {
                  _probePort = n;
                  _probes.clear();
                }
              },
            ),
          ),
        ),
        for (final p in peers) _peerRow(s, p, scheme),
      ],
    );
  }

  Widget _peerRow(AppState s, MeshPeer p, ColorScheme scheme) {
    final probing = _probing.contains(p.virtualIp);
    final result = _probes[p.virtualIp];
    final failed = result != null && result.contains('"'"'不通'"'"');
    return ListTile(
      onTap: () => _probePeer(p),
      leading: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: (p.direct ? const Color(0xFF07C160) : scheme.onSurfaceVariant)
              .withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(10),
        ),
        child: LucideIcon(
          p.direct ? '"'"'zap'"'"' : '"'"'infinity'"'"',
          size: 18,
          color: p.direct ? const Color(0xFF07C160) : scheme.onSurfaceVariant,
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              p.name.ifEmpty(p.virtualIp),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            p.latencyLabel,
            style: TextStyle(
              fontSize: MobileType.aside,
              fontWeight: FontWeight.w600,
              color: p.latencyMs >= 0 && p.latencyMs < 50
                  ? const Color(0xFF07C160)
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          children: [
            Text(
              p.virtualIp.ifEmpty('—'),
              style: TextStyle(fontSize: MobileType.aside, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            Text(
              p.linkLabel,
              style: TextStyle(fontSize: MobileType.aside, color: scheme.onSurfaceVariant),
            ),
            if (result != null) ...[
              const SizedBox(width: 8),
              Text(
                result,
                style: TextStyle(
                  fontSize: MobileType.aside,
                  color: failed ? scheme.error : const Color(0xFF07C160),
                ),
              ),
            ],
          ],
        ),
      ),
      trailing: probing
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const LucideIcon('activity', size: 16),
    );
  }

  Widget _trafficCard(AppState s) {
    final rows = _mesh.traffic;
    return GroupCard(
      children: [
        ListTile(
          title: Text(s.tr('流量记录', 'Traffic')),
          subtitle: Text(
            '收 ${_fmt(_mesh.totalRx)} · 发 ${_fmt(_mesh.totalTx)}',
          ),
        ),
        for (final t in rows)
          ListTile(
            dense: true,
            title: Text(t.name.ifEmpty(t.virtualIp)),
            subtitle: Text(t.virtualIp),
            trailing: Text(
              '↓${_fmt(t.rxDelta)} ↑${_fmt(t.txDelta)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _configCard(AppState s, bool running) {
    // 连上后配置默认收起：屏幕上留给节点和流量。断开时自动展开。
    final expanded = _configOpen ?? !running;
    return GroupCard(
      children: [
        ListTile(
          onTap: () => setState(() => _configOpen = !expanded),
          title: Text(
            s.tr('网络配置', 'Network'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            expanded
                ? (running
                    ? s.tr('运行中不可改，先断开', 'Stop first to edit')
                    : s.tr('改完点连接生效', 'Takes effect on connect'))
                : '${_netName.text} · ${_ipv4.text}'
                      '${_hostname.text.isEmpty ? '' : ' · ${_hostname.text}'}',
          ),
          trailing: LucideIcon(
            expanded ? 'chevron-up' : 'chevron-down',
            size: 18,
            color: Theme.of(context).hintColor,
          ),
        ),
        if (expanded) ...[
          _field(s, _netName, s.tr('网络名', 'Network name')),
          _field(s, _secret, s.tr('密钥', 'Secret'), obscure: true),
          _field(s, _ipv4, s.tr('本机虚拟 IP', 'Virtual IP'), hint: '10.126.126.1/24'),
          _field(s, _hostname, s.tr('主机名', 'Hostname')),
          ListTile(
            dense: true,
            title: Text(s.tr('节点来源', 'Peer source')),
            subtitle: Text(
              s.tr('官方公共节点或你自己的', 'Official public nodes, or your own'),
            ),
            trailing: PopupMenuButton<String>(
              enabled: !running,
              icon: const LucideIcon('ellipsis', size: 18),
              tooltip: s.tr('切换节点', 'Switch peers'),
              onSelected: (v) {
                if (v == 'official') {
                  _peers.text = defaultEasyTierPeers.join('\n');
                } else if (v == 'clear') {
                  _peers.text = '';
                }
                setState(() {});
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'official',
                  child: Text(s.tr('用官方公共节点', 'Use official public nodes')),
                ),
                PopupMenuItem(
                  value: 'clear',
                  child: Text(s.tr('清空，自己填', 'Clear and fill my own')),
                ),
              ],
            ),
          ),
          _field(
            s,
            _peers,
            s.tr('种子 / 中继节点（每行一个）', 'Seed / relay peers (one per line)'),
            hint: 'tcp://public.easytier.top:11010',
            maxLines: 3,
          ),
        ],
      ],
    );
  }

  Widget _field(
    AppState s,
    TextEditingController c,
    String label, {
    String? hint,
    bool obscure = false,
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: TextField(
      controller: c,
      obscureText: obscure,
      maxLines: obscure ? 1 : maxLines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    ),
  );

  static String _fmt(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}G';
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
