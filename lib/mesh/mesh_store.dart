import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../link/link_store.dart';
import 'mesh_controller.dart';

/// 组网配置的本地持久化。
///
/// 复用 fromsko 既有的 [LinkStore]（原生实现走 OS 凭据存储），
/// 不引入 shared_preferences，也不把网络密钥写进普通偏好文件。
class MeshStore extends ChangeNotifier {
  MeshStore._(this._store, this._config);

  static const _kConfig = 'mesh_config';

  static Future<MeshStore> load(LinkStore store) async {
    MeshConfig cfg = const MeshConfig();
    final raw = await store.read(_kConfig);
    if (raw != null && raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        cfg = MeshConfig(
          networkName: '${m['networkName'] ?? cfg.networkName}',
          secret: '${m['secret'] ?? ''}',
          ipv4: '${m['ipv4'] ?? cfg.ipv4}',
          hostname: '${m['hostname'] ?? ''}',
          peers:
              (m['peers'] as List<dynamic>?)
                  ?.map((e) => '$e')
                  .where((e) => e.trim().isNotEmpty)
                  .toList() ??
              cfg.peers,
        );
      } on FormatException catch (error) {
        debugPrint('Ignoring unreadable mesh config: $error');
      }
    }
    return MeshStore._(store, cfg);
  }

  final LinkStore _store;
  MeshConfig _config;

  MeshConfig get config => _config;

  Future<void> save(MeshConfig cfg) async {
    _config = cfg;
    await _store.write(
      _kConfig,
      jsonEncode({
        'networkName': cfg.networkName,
        'secret': cfg.secret,
        'ipv4': cfg.ipv4,
        'hostname': cfg.hostname,
        'peers': cfg.peers,
      }),
    );
    notifyListeners();
  }

  Future<void> clearSecret() async {
    await save(_config.copyWith(secret: ''));
  }
}
