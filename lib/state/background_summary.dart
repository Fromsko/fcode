import 'package:bao_link/bao_link.dart' show LinkSessionStatus;

/// 一条对话在通知摘要里的样子；纯数据，不依赖 AppState 或平台。
class BackgroundConversation {
  const BackgroundConversation({
    required this.desktopId,
    required this.sessionId,
    required this.title,
    required this.updatedAt,
    this.status = LinkSessionStatus.idle,
    this.wait,
  });
  final String desktopId, sessionId, title;
  final DateTime updatedAt;
  final LinkSessionStatus status;

  /// 在等你时等你做什么；不在等就是 null（含卡在等、做完没看）。
  final BackgroundWait? wait;
}

/// 在等用户的那几种：要批准比要回答急，做完没看最后。
enum BackgroundWait { approval, question, done }

typedef BackgroundDesktop = ({String id, String name, bool online});

/// 后台通知的整段文字；[target] 非空时点通知直接打开那段对话。
class BackgroundSummary {
  const BackgroundSummary({
    required this.title,
    required this.body,
    required this.shortText,
    this.target,
  });
  final String title, body, shortText;
  final ({String desktopId, String sessionId})? target;

  /// 原生方法通道的参数；目标为空时只打开应用本身。
  Map<String, Object?> toArguments() => {
    'title': title,
    'body': body,
    'shortText': shortText,
    if (target != null) 'desktopId': target!.desktopId,
    if (target != null) 'sessionId': target!.sessionId,
  };

  @override
  bool operator ==(Object other) =>
      other is BackgroundSummary &&
      other.title == title &&
      other.body == body &&
      other.shortText == shortText &&
      other.target == target;

  @override
  int get hashCode => Object.hash(title, body, shortText, target);
}

/// 在等的先、运行中的次之、都空就报告连接状态；只算在线的电脑，
/// 离线电脑最后报的状态已经过时。
BackgroundSummary summarizeBackground({
  required List<BackgroundDesktop> desktops,
  required Iterable<BackgroundConversation> conversations,
  required String Function(String zh, String en) tr,
}) {
  final online = {
    for (final desktop in desktops)
      if (desktop.online) desktop.id,
  };
  final names = {for (final desktop in desktops) desktop.id: desktop.name};
  final named = desktops.length > 1;
  final live = [
    for (final conversation in conversations)
      if (online.contains(conversation.desktopId)) conversation,
  ];

  final waiting = [
    for (final conversation in live)
      if (conversation.wait != null) conversation,
  ]..sort((a, b) {
    final urgency = _urgency(a.wait!).compareTo(_urgency(b.wait!));
    return urgency != 0 ? urgency : b.updatedAt.compareTo(a.updatedAt);
  });
  if (waiting.isNotEmpty) {
    final first = waiting.first;
    final count = waiting.length;
    return BackgroundSummary(
      title: count == 1
          ? tr('1 个对话在等你', '1 conversation waiting for you')
          : tr('$count 个对话在等你', '$count conversations waiting for you'),
      body:
          '${_named(first, names, named, tr)} · ${_waitLabel(first.wait!, tr)}',
      shortText: _waitLabel(first.wait!, tr),
      target: (desktopId: first.desktopId, sessionId: first.sessionId),
    );
  }

  final running = [
    for (final conversation in live)
      if (conversation.status == LinkSessionStatus.running) conversation,
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  if (running.isNotEmpty) {
    final first = running.first;
    final count = running.length;
    return BackgroundSummary(
      title: count == 1
          ? tr('1 个对话运行中', '1 conversation running')
          : tr('$count 个对话运行中', '$count conversations running'),
      body: _named(first, names, named, tr),
      shortText: tr('运行中', 'Running'),
      target: (desktopId: first.desktopId, sessionId: first.sessionId),
    );
  }

  if (desktops.isEmpty) {
    return BackgroundSummary(
      title: tr('YCode 后台连接', 'YCode background'),
      body: tr('还没有配对电脑', 'No desktop paired yet'),
      shortText: tr('后台', 'Idle'),
    );
  }
  if (online.isEmpty) {
    return BackgroundSummary(
      title: tr('YCode 后台连接', 'YCode background'),
      body: tr('电脑离线，正在重连', 'Desktop offline, reconnecting'),
      shortText: tr('离线', 'Offline'),
    );
  }
  return BackgroundSummary(
    title: tr('YCode 已连接', 'YCode connected'),
    body: tr('没有在跑的对话', 'No conversation running'),
    shortText: tr('在线', 'Online'),
  );
}

int _urgency(BackgroundWait wait) => wait.index;

// 也是状态栏胶囊里的短词，不超过 7 个字符。
String _waitLabel(BackgroundWait wait, String Function(String, String) tr) =>
    switch (wait) {
      BackgroundWait.approval => tr('待批准', 'Approve'),
      BackgroundWait.question => tr('待回答', 'Answer'),
      BackgroundWait.done => tr('待查看', 'Review'),
    };

/// 标题（多台电脑时带上电脑名），太长就截断：锁屏上的正文只有一行。
String _named(
  BackgroundConversation conversation,
  Map<String, String> names,
  bool named,
  String Function(String, String) tr,
) {
  final raw = conversation.title.trim();
  final title = _clip(raw.isEmpty ? tr('未命名对话', 'Untitled') : raw, 28);
  final desktop = _clip(names[conversation.desktopId] ?? '', 12);
  return named && desktop.isNotEmpty ? '$title · $desktop' : title;
}

String _clip(String value, int max) {
  final runes = value.runes;
  if (runes.length <= max) return value;
  return '${String.fromCharCodes(runes.take(max - 1))}…';
}
