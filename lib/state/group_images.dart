import 'dart:typed_data';

/// 群聊图片的字节，按（电脑, 群, 文件名）记着：来回滚动不重新下载。
/// 只留最近 [maxEntries] 张，超出就丢最久没用的。
class GroupImageCache {
  GroupImageCache({this.maxEntries = 40});

  final int maxEntries;
  final _bytes = <(String, String, String), Uint8List>{};

  Uint8List? get(String desktop, String group, String name) {
    final key = (desktop, group, name);
    final bytes = _bytes.remove(key);
    if (bytes != null) _bytes[key] = bytes;
    return bytes;
  }

  void put(String desktop, String group, String name, Uint8List bytes) {
    final key = (desktop, group, name);
    _bytes
      ..remove(key)
      ..[key] = bytes;
    while (_bytes.length > maxEntries) {
      _bytes.remove(_bytes.keys.first);
    }
  }

  void invalidateDesktop(String desktop) =>
      _bytes.removeWhere((key, _) => key.$1 == desktop);
}
