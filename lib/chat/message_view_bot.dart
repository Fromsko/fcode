part of 'message_view.dart';

/// 新 agent 的临时 id 不是给人看的，还没标题时也不露出来。
String _agentTitle(AppState state, SessionSummary? session, String id) {
  if (session == null) return id;
  final title = session.title.trim();
  return title.isEmpty ? state.tr('新对话', 'New chat') : session.title;
}

final _blockMarkdown = RegExp(
  r'^\s*(```|#|>|\||[-*+]\s|\d+\.\s)',
  multiLine: true,
);

/// 纯文字时气泡收到最长一行的宽度；块级 Markdown、行内代码、链接和文件
/// 提及渲染时带内边距或图标，量不准，返回 null 铺满。
double? _bubbleFitWidth(BuildContext context, String text, TextStyle style) {
  if (text.contains('`') ||
      text.contains('](') ||
      text.contains('@') ||
      _blockMarkdown.hasMatch(text)) {
    return null;
  }
  final plain = text
      .replaceAll(RegExp(r'\*\*|__'), '')
      .replaceAll(RegExp(r'(?<!\n)\n(?!\n)'), ' ');
  final painter = TextPainter(
    text: TextSpan(text: plain, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width + 6;
}

const _botAvatarSize = 36.0;
const _botAvatarGap = 6.0;
const _botTailTop = 12.0;
const _botBubbleRadius = 8.0;
const _botQuoteRadius = 4.0;

/// 聊天里隔 5 分钟以上才出现的时间行：今天只写钟点，昨天、更早带日期。
class ChatTimeLine extends StatelessWidget {
  const ChatTimeLine(this.at, {super.key, required this.state});

  final DateTime at;
  final AppState state;

  static bool between(DateTime? previous, DateTime at) =>
      previous == null || at.difference(previous) > const Duration(minutes: 5);

  @override
  Widget build(BuildContext context) {
    final local = at.toLocal();
    final now = DateUtils.dateOnly(DateTime.now());
    final day = DateUtils.dateOnly(local);
    final clock = formatClock(local);
    final label = day == now
        ? clock
        : day == now.subtract(const Duration(days: 1))
        ? '${state.tr('昨天', 'Yesterday')} $clock'
        : '${formatDay(state, local)} $clock';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(label, style: MobileTheme.metaStyleOf(context)),
      ),
    );
  }
}

/// 气泡左边缘到屏幕边：外边距、头像、间隔、尖角。
const _botBubbleInset = 12 + _botAvatarSize + _botAvatarGap + 6;

/// 引用的那条消息：灰底一小块，点开看原文。
class QuoteChip extends StatelessWidget {
  const QuoteChip({
    super.key,
    required this.who,
    required this.text,
    this.onTap,
    this.maxLines = 1,
  });

  final String who, text;
  final VoidCallback? onTap;
  final int maxLines;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(_botQuoteRadius),
      ),
      child: Text(
        who.isEmpty ? text : '$who: $text',
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: MobileTheme.metaStyleOf(context),
      ),
    ),
  );
}

/// 聊天的一行：头像、尖角、气泡，另一边留 40；群聊里名字在气泡上方。
Widget _botRow(
  BuildContext context, {
  required Widget avatar,
  required Color color,
  required Widget bubble,
  bool user = false,
  String? name,
}) {
  final tail = Transform.translate(
    offset: Offset(user ? -1 : 1, 0),
    child: Padding(
      padding: const EdgeInsets.only(top: _botTailTop),
      child: CustomPaint(
        size: const Size(6, 10),
        painter: _BubbleTail(color, user),
      ),
    ),
  );
  Widget rowOf(List<Widget> children) => Row(
    mainAxisAlignment: user ? MainAxisAlignment.end : MainAxisAlignment.start,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: children,
  );
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: name == null
        ? rowOf(
            user
                ? [
                    const SizedBox(width: 40),
                    bubble,
                    tail,
                    const SizedBox(width: _botAvatarGap),
                    avatar,
                  ]
                : [
                    avatar,
                    const SizedBox(width: _botAvatarGap),
                    tail,
                    bubble,
                    const SizedBox(width: 40),
                  ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              avatar,
              const SizedBox(width: _botAvatarGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MobileTheme.metaStyleOf(context),
                      ),
                    ),
                    rowOf([tail, bubble]),
                  ],
                ),
              ),
              const SizedBox(width: 40),
            ],
          ),
  );
}

/// 和 Bot 聊天的样子：头像、带尖角的气泡、图片自成一条。
extension _BotMessage on MessageView {
  Widget _botParts(BuildContext context, List<(String, String)> parts) {
    final firstSay = parts.indexWhere(
      (part) =>
          part.$1 != ChatCodec.botCardTag && part.$1 != ChatCodec.botNarrateTag,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, (tag, text)) in parts.indexed)
          if (tag == ChatCodec.botCardTag)
            _BotAgentCard(
              state: state,
              desktopId: desktopId,
              bot: bot!,
              id: text,
              onOpen: onOpenSession,
            )
          else if (tag == ChatCodec.botNarrateTag)
            Padding(
              padding: botContentInsets.add(
                const EdgeInsets.symmetric(vertical: 4),
              ),
              child: _botPart(context, tag, ChatCodec.withoutVoiceCues(text)),
            )
          else
            MessageView(
              state: state,
              desktopId: desktopId,
              item: AssistantTextItem(text),
              bot: bot,
              projectId: projectId,
              sessionId: sessionId,
              onOpenSession: onOpenSession,
              senderName: index == firstSay ? senderName : null,
              quote: index == firstSay ? quote : null,
              onQuote: onQuote,
            ),
      ],
    );
  }

  Widget _quoteBlock(BuildContext context, bool user) {
    final quote = this.quote;
    if (quote == null) return const SizedBox.shrink();
    if (quote.text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        user ? 0 : _botBubbleInset,
        2,
        user ? _botBubbleInset : 0,
        0,
      ),
      child: QuoteChip(
        who: quote.who,
        text: quote.text,
        onTap: quote.onTap,
        maxLines: 2,
      ),
    );
  }

  Widget _botBubble(BuildContext context, ChatItem value) {
    final user = value is UserMessageItem;
    final text = user
        ? ChatCodec.withoutBotEvents(messageBody(value.text, value.images))
        : ChatCodec.botVisibleText((value as AssistantTextItem).text);
    final scheme = Theme.of(context).colorScheme;
    final color = user
        ? botUserBubbleColor(context)
        : scheme.surfaceContainerLow;
    final avatar = user
        ? LetterAvatar(
            state.settings.name.isEmpty ? '我' : state.settings.name,
            image: state.settings.avatar,
            size: _botAvatarSize,
          )
        : BotAvatar(state: state, ref: bot!, size: _botAvatarSize);
    final textStyle = MobileTheme.messageStyleOf(context);
    final references = user
        ? fileReferenceRegion(text)
        : (body: text, paths: <String>[]);
    final sticker = ChatCodec.sticker(text);
    final fit = user || sticker != null
        ? null
        : _bubbleFitWidth(context, text, textStyle);
    final prose = MobileTheme.reading(
      context,
      child: _prose(text, style: textStyle, selectable: false),
    );
    final body = sticker != null
        ? StickerView(sticker)
        : user
        ? Text(
            references.body,
            style: textStyle.copyWith(color: const Color(0xFF111111)),
          )
        // 气泡是白的，里面的代码块要用白底上的浅灰。
        : fit == null
        ? prose
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: fit),
            child: prose,
          );
    void press(BuildContext anchor) => showBubbleMenu(anchor, [
      BubbleMenuAction(
        icon: 'copy',
        label: state.tr('复制', 'Copy'),
        onTap: () =>
            _copy(context, text, images: user ? value.images : const []),
      ),
      if (onQuote != null)
        BubbleMenuAction(
          icon: 'message-circle',
          label: state.tr('引用', 'Quote'),
          onTap: onQuote!,
        ),
    ]);
    final bubble = Flexible(
      child: Builder(
        builder: (anchor) => GestureDetector(
          onLongPress: () => press(anchor),
          child: Container(
            key: ValueKey(user ? 'bot-user-bubble' : 'bot-answer-bubble'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(_botBubbleRadius),
            ),
            child: body,
          ),
        ),
      ),
    );
    final words = _botRow(
      context,
      avatar: avatar,
      color: color,
      bubble: bubble,
      user: user,
      name: user ? null : senderName,
    );
    final withQuote = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: user
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [words, _quoteBlock(context, user)],
    );
    final files = references.paths;
    if (!user || (value.images.isEmpty && files.isEmpty)) return withQuote;
    // 图片、文件各自成一条，不进气泡；只有附件时也不留空气泡。
    Widget aside(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: child),
          ),
          const SizedBox(width: _botAvatarGap + 6),
          avatar,
        ],
      ),
    );
    return Column(
      children: [
        if (references.body.isNotEmpty) words,
        for (final path in files)
          aside(
            Builder(
              builder: (anchor) => GestureDetector(
                onLongPress: () => press(anchor),
                child: SizedBox(
                  width: 240,
                  child: FileAttachment(
                    key: ValueKey(('bot-user-file', path)),
                    name: fileReferenceName(path),
                    path: path,
                    bot: true,
                    onTap: _openFile(context, path),
                  ),
                ),
              ),
            ),
          ),
        if (value.images.isNotEmpty)
          aside(
            Builder(
              builder: (anchor) => ImageDeck(
                key: const ValueKey('bot-user-images'),
                images: value.images.map(GalleryImage.fromAttachment).toList(),
                tr: state.tr,
                onLongPress: () => press(anchor),
              ),
            ),
          ),
        _quoteBlock(context, user),
      ],
    );
  }
}

/// Bot 正在输入时的气泡：和它的消息同一条布局，气泡里三个点轮流变亮。
class BotTypingBubble extends StatefulWidget {
  const BotTypingBubble({
    super.key,
    required this.state,
    required this.bot,
    this.name,
  });

  final AppState state;
  final BotRef bot;

  /// 群聊里显示在气泡上方；一对一不传。
  final String? name;

  @override
  State<BotTypingBubble> createState() => _BotTypingBubbleState();
}

class _BotTypingBubbleState extends State<BotTypingBubble>
    with SingleTickerProviderStateMixin {
  late final _dots = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubble = Flexible(
      child: Container(
        key: const ValueKey('bot-typing-bubble'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(_botBubbleRadius),
        ),
        child: AnimatedBuilder(
          animation: _dots,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: EdgeInsets.only(right: i == 2 ? 0 : 4),
                  child: Opacity(
                    opacity: _dotOpacity(i),
                    child: SizedBox.square(
                      dimension: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.onSurfaceVariant,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return _botRow(
      context,
      avatar: BotAvatar(
        state: widget.state,
        ref: widget.bot,
        size: _botAvatarSize,
      ),
      color: scheme.surfaceContainerLow,
      bubble: bubble,
      name: widget.name,
    );
  }

  double _dotOpacity(int index) {
    final phase = (_dots.value * 3 - index) % 3;
    return phase < 1 ? .3 + .7 * phase : .3;
  }
}

/// Bot 发的对话卡片：标题、状态和项目，点开进那个对话。
class _BotAgentCard extends StatelessWidget {
  const _BotAgentCard({
    required this.state,
    required this.desktopId,
    required this.bot,
    required this.id,
    this.onOpen,
  });

  final AppState state;
  final String desktopId, id;
  final BotRef bot;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = state.sessions
        .where((ref) => ref.desktopId == desktopId && ref.session.id == id)
        .firstOrNull
        ?.session;
    final title = _agentTitle(state, session, id);
    final project = state.projects
        .where(
          (ref) =>
              ref.desktopId == desktopId && ref.project.id == session?.project,
        )
        .firstOrNull
        ?.project
        .name;
    final status = switch (session?.status) {
      LinkSessionStatus.running => state.tr('运行中', 'Running'),
      LinkSessionStatus.needsInput => state.tr('等你处理', 'Needs you'),
      _ => null,
    };
    final meta = MobileTheme.metaStyleOf(context);
    final card = Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(_botBubbleRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('bot-agent-card'),
        onTap: onOpen == null ? null : () => onOpen!(id),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LetterAvatar(title, size: _botAvatarSize),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MobileTheme.messageStyleOf(context).copyWith(
                        fontSize:
                            MobileType.body *
                            MobileTheme.messageScaleOf(context),
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    if (status != null || project != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text.rich(
                          TextSpan(
                            style: meta,
                            children: [
                              if (status != null)
                                TextSpan(
                                  text: status,
                                  style: TextStyle(
                                    color: MobileTheme.statusColorsOf(context)
                                        .info,
                                  ),
                                ),
                              if (status != null && project != null)
                                const TextSpan(text: ' · '),
                              if (project != null) TextSpan(text: project),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              LucideIcon(
                'chevron-right',
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
    return _botRow(
      context,
      avatar: BotAvatar(state: state, ref: bot, size: _botAvatarSize),
      color: scheme.surfaceContainerLow,
      bubble: Flexible(child: card),
    );
  }
}

class _BubbleTail extends CustomPainter {
  const _BubbleTail(this.color, this.right);
  final Color color;
  final bool right;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(right ? 0 : size.width, 0)
      ..lineTo(right ? size.width : 0, size.height / 2)
      ..lineTo(right ? 0 : size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BubbleTail oldDelegate) =>
      color != oldDelegate.color || right != oldDelegate.right;
}
