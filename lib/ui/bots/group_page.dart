import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../chat/chat_models.dart';
import '../../chat/message_view.dart';
import '../../chat/widgets/image_deck.dart';
import '../../link/chat_codec.dart';
import '../../state/app_state.dart';
import '../../state/conversation_input.dart';
import '../../state/group_images.dart';
import '../../state/group_subscriptions.dart';
import '../../theme/app_theme.dart';
import '../tasks/chat_input_bar.dart';
import '../tasks/composer_banners.dart';
import '../tasks/conversation_images.dart';
import '../tasks/session_sync_notice.dart';
import '../user_message.dart';
import '../widgets/earlier_messages.dart';
import '../widgets/image_gallery.dart';
import '../widgets/mobile_widgets.dart';
import 'bots_tab.dart';

class GroupChatPage extends StatefulWidget {
  const GroupChatPage({super.key, required this.state, required this.ref});
  final AppState state;
  final GroupRef ref;
  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage>
    with ChatAddPanelHost<GroupChatPage> {
  late final TextEditingController _text;
  final _focus = FocusNode();
  final _images = <DraftImage>[];
  final _scroll = ScrollController();
  bool _follow = true, _restoringScroll = false, _userScrolling = false;
  int _seenRevision = -1;
  int? _firstSequence;
  bool _sending = false, _picking = false, _retained = false;
  String? _error, _sendId, _sendPayload;
  late int _signature;
  int? _quote;
  Timer? _saveTimer;
  @override
  FocusNode get addFocus => _focus;
  AppState get state => widget.state;
  String get desktop => widget.ref.desktopId;
  String get id => widget.ref.group.id;
  String get draftKey => 'group:$id';
  GroupBuffer get buffer => state.groupChats.buffer(desktop, id);
  InputDraft get input =>
      InputDraft(text: _text.text, images: List.of(_images));

  @override
  void initState() {
    super.initState();
    final draft = state.inputDraft(desktop, draftKey);
    _text = TextEditingController(text: draft.text)..addListener(_saveLater);
    _images.addAll(draft.images);
    _signature = _signatureOf();
    state.addListener(_stateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _retained = true;
      unawaited(state.groupChats.retain(desktop, id));
    });
  }

  /// 这一页只认自己显示的东西：别的会话、别的电脑变了不整页重画。
  void _stateChanged() {
    if (!mounted) return;
    final signature = _signatureOf();
    if (signature == _signature) return;
    _signature = signature;
    setState(() {});
  }

  int _signatureOf() {
    final current = _currentGroup;
    return Object.hash(
      buffer.revision,
      buffer.loading,
      buffer.loadingEarlier,
      buffer.error,
      buffer.earlierError,
      buffer.more,
      buffer.unsupported,
      state.isOnline(desktop),
      state.settings.language,
      state.settings.name,
      state.settings.avatar,
      current.name,
      current.members.join('\u0000'),
      current.typing.join('\u0000'),
      current.holder,
      _botIdentities(current),
    );
  }

  LinkGroup get _currentGroup =>
      state.groups
          .where((ref) => ref.desktopId == desktop && ref.group.id == id)
          .firstOrNull
          ?.group ??
      widget.ref.group;

  /// 名字和头像只随 Bot 的身份变；消息里的发送者也可能是已离群的。
  String _botIdentities(LinkGroup group) {
    final bots = {
      for (final ref in state.bots)
        if (ref.desktopId == desktop) ref.bot.id: ref.bot,
    };
    final ids = <String>{...group.members, ...group.typing};
    for (final message in buffer.messages) {
      if (!message.mine && !message.notice) ids.add(message.from);
    }
    final former = state.tr('已离群的 Bot', 'Former member');
    return [
      for (final botId in ids)
        '$botId\u0000${bots[botId]?.name ?? former}'
            '\u0000${bots[botId]?.avatar ?? ''}',
    ].join('\u0001');
  }

  /// 图片变了：重画待发图片，草稿稍后存。
  void _draftChanged() {
    if (mounted) setState(() {});
    _saveLater();
  }

  /// 和对话页一样停手 350ms 再存：每个字都存会整份草稿写一次安全存储。
  void _saveLater() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), _saveDraft);
  }

  void _saveDraft() {
    _saveTimer?.cancel();
    _saveTimer = null;
    unawaited(
      state.saveInputDraft(desktop, draftKey, input).catchError((Object error) {
        if (mounted) setState(() => _error = userMessage(state, error));
      }),
    );
  }

  @override
  void dispose() {
    _text.removeListener(_saveLater);
    if (_saveTimer != null) _saveDraft();
    state.removeListener(_stateChanged);
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    if (_retained) unawaited(state.groupChats.release(desktop, id));
    super.dispose();
  }

  /// 取一页更早的群消息；三处入口共用，重复请求由 groupChats 自己去重。
  void _loadEarlier() => unawaited(state.groupChats.earlier(desktop, id));

  /// 手指还在列表上时不跳：列表边滚边排版也会发尺寸通知，跳了就打断拖动。
  void _followLatest() {
    if (!_follow || _restoringScroll || _userScrolling) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_follow ||
          _restoringScroll ||
          _userScrolling ||
          !_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      if ((position.maxScrollExtent - position.pixels).abs() > 1) {
        _scroll.jumpTo(position.maxScrollExtent);
      }
    });
  }

  void _historyChanged() {
    if (_seenRevision == buffer.revision) return;
    final first = buffer.messages.firstOrNull?.seq;
    final prepended =
        _firstSequence != null && first != null && first < _firstSequence!;
    _seenRevision = buffer.revision;
    _firstSequence = first;
    if (prepended && _scroll.hasClients) {
      final before = _scroll.position;
      final pixels = before.pixels, extent = before.maxScrollExtent;
      _follow = false;
      _restoringScroll = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scroll.hasClients) {
          final position = _scroll.position;
          _scroll.jumpTo(
            (pixels + position.maxScrollExtent - extent).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
        _restoringScroll = false;
      });
    } else {
      _followLatest();
    }
  }

  Future<void> _pick({bool camera = false}) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final images = await pickConversationImages(
        state,
        source: camera ? ImageSource.camera : null,
      );
      if (!mounted) return;
      _images.addAll(images);
      _draftChanged();
    } on Object catch (error) {
      if (mounted) setState(() => _error = userMessage(state, error));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 点选一格后收起面板：选完图片回到输入框，键盘跟着回来。
  void _pickPanel({required bool camera}) {
    setState(() => addOpen = false);
    _focus.requestFocus();
    unawaited(_pick(camera: camera));
  }

  Future<void> _send() async {
    if (_sending ||
        !state.isOnline(desktop) ||
        (_text.text.trim().isEmpty && _images.isEmpty)) {
      return;
    }
    final sent = input;
    final quote = _quote;
    final payload = jsonEncode({
      'text': sent.text,
      'images': [for (final image in sent.images) image.wire],
      'ref': quote,
    });
    if (_sendPayload != payload) {
      _sendPayload = payload;
      _sendId = base64UrlEncode(randomBytes(18));
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final result = objectMap(
        await state.request(desktop, LinkMethods.sendGroup, {
          'group': id,
          'text': sent.text,
          'id': _sendId,
          if (sent.images.isNotEmpty)
            'images': [for (final image in sent.images) image.wire],
          'ref': ?quote,
        }),
      );
      if (result['seq'] is! num) throw const FormatException('群发送未确认');
      if (!mounted) return;
      final remaining = input.afterSending(sent);
      _images
        ..clear()
        ..addAll(remaining.images);
      _text.text = remaining.text;
      if (_quote == quote) _quote = null;
      _sendId = _sendPayload = null;
      _draftChanged();
      _follow = true;
      _followLatest();
    } on LinkRemoteException catch (error) {
      if (mounted) setState(() => _error = userMessage(state, error));
    } on Object {
      if (mounted) {
        setState(
          () => _error = state.tr(
            '发送未确认，草稿已保留。先查看群消息再决定是否重发；不会自动重试。',
            'Send unconfirmed; draft kept. Check the group before sending again. No automatic retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _mention(LinkGroup group) async {
    if (group.members.isEmpty) return;
    final botId = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                state.tr('选择提醒的人', 'Choose who to mention'),
                style: MobileTheme.hintStyleOf(context),
              ),
            ),
            for (final id in group.members)
              ListTile(
                key: ValueKey(('group-mention', id)),
                leading: BotAvatar(
                  state: state,
                  ref: BotRef(desktop, _bot(id)),
                  size: _pickAvatar,
                ),
                title: Text(_bot(id).name),
                onTap: () => Navigator.pop(context, id),
              ),
          ],
        ),
      ),
    );
    if (botId == null || !mounted) return;
    final text = _text.text;
    final at = _text.selection.baseOffset.clamp(0, text.length);
    final insert = '${_bot(botId).name} ';
    _text.value = TextEditingValue(
      text: text.replaceRange(at, at, insert),
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
  }

  LinkBot _bot(String botId) =>
      state.botOn(desktop, botId)?.bot ??
      LinkBot(id: botId, name: state.tr('已离群的 Bot', 'Former member'));

  ({String who, String text, VoidCallback? onTap}) _quoteData(int seq) {
    final message = buffer.messages
        .where((message) => message.seq == seq)
        .firstOrNull;
    if (message == null) {
      return (
        who: '',
        text: state.tr('引用消息尚未加载', 'Quoted message not loaded'),
        onTap: buffer.more && !buffer.loadingEarlier ? _loadEarlier : null,
      );
    }
    return (
      who: message.mine
          ? state.tr('我', 'Me')
          : message.notice
          ? ''
          : _bot(message.from).name,
      text: message.mine || message.notice
          ? message.text
          : _lastSay(message.text),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _message(message),
          ),
        ),
      ),
    );
  }

  /// 引用只记到哪条消息，一条里说了几句时露最后一句，像官方那样只占一行。
  String _lastSay(String text) {
    final says = [
      for (final part in ChatCodec.botPartsOf(text))
        if (part.tag == ChatCodec.botSayTag) part.text,
    ];
    final said = says.isEmpty
        ? ChatCodec.botVisibleText(text)
        : ChatCodec.withoutVoiceCues(says.last);
    return said.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Widget _message(LinkGroupMessage message) {
    if (message.notice) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(message.text, style: MobileTheme.metaStyleOf(context)),
        ),
      );
    }
    final sender = message.mine ? null : _bot(message.from);
    final bot = BotRef(
      desktop,
      sender ??
          (widget.ref.group.members.isEmpty
              ? LinkBot(id: '', name: widget.ref.group.name)
              : _bot(widget.ref.group.members.first)),
    );
    final parts = message.mine
        ? const <({String tag, String text, int? ref})>[]
        : ChatCodec.botPartsOf(message.text);
    final firstSay = parts.indexWhere(
      (part) =>
          part.tag != ChatCodec.botCardTag &&
          part.tag != ChatCodec.botNarrateTag,
    );
    final messageQuote = message.ref == null ? null : _quoteData(message.ref!);
    void quote() => setState(() => _quote = message.seq);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.mine)
          MessageView(
            state: state,
            desktopId: desktop,
            bot: bot,
            item: UserMessageItem(text: message.text),
            quote: messageQuote,
            onQuote: quote,
          )
        else if (parts.isEmpty)
          MessageView(
            state: state,
            desktopId: desktop,
            bot: bot,
            item: AssistantTextItem(message.text),
            senderName: sender!.name,
            quote: messageQuote,
            onQuote: quote,
          )
        else
          for (final (index, part) in parts.indexed)
            MessageView(
              state: state,
              desktopId: desktop,
              bot: bot,
              item: AssistantTextItem(
                '<${part.tag}>${part.text}</${part.tag}>',
              ),
              senderName: index == firstSay ? sender!.name : null,
              quote: part.ref == null
                  ? index == firstSay
                        ? messageQuote
                        : null
                  : _quoteData(part.ref!),
              onQuote: quote,
            ),
        if (message.images.isNotEmpty)
          _GroupImages(
            key: ValueKey((desktop, id, message.seq)),
            state: state,
            desktop: desktop,
            group: id,
            images: message.images,
            mine: message.mine,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    _historyChanged();
    final current = _currentGroup;
    final online = state.isOnline(desktop);
    final ready = online && !_sending && !_picking && !buffer.unsupported;
    noteKeyboard(context);
    // 加号面板开着时，返回键先收起面板（和 Bot 聊天一样），再按才离开。
    return PopScope(
      canPop: !addOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && addOpen) closeAdd();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: Navigator.canPop(context)
              ? AttentionBackButton(state: state)
              : null,
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (current.typing.isNotEmpty || current.holder != null) ...[
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  '${groupTitle(state, GroupRef(desktop, current))}（${current.members.length + 1}）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: state.tr('群设置', 'Group settings'),
              icon: const Icon(Icons.more_horiz),
              onPressed: () async {
                final deleted = await openPage<bool>(
                  context,
                  GroupInfoPage(state: state, desktop: desktop, group: current),
                );
                if (deleted == true && context.mounted) {
                  Navigator.pop(context);
                }
              },
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (!online)
                Text(state.tr('电脑不在线，草稿已保留', 'Desktop offline; draft kept')),
              if (buffer.error ?? _error case final error?)
                ComposerNotice(
                  icon: 'triangle-alert',
                  title: error,
                  tone: Theme.of(context).colorScheme.error,
                  actionLabel: buffer.error != null
                      ? state.tr('重新加载', 'Reload')
                      : state.tr('关闭', 'Dismiss'),
                  onAction: () {
                    setState(() => _error = null);
                    if (buffer.error != null) {
                      unawaited(state.groupChats.refresh(desktop, id));
                    }
                  },
                ),
              // 已有消息时多半是回前台静默核对，不急着让进度条闪一下。
              SessionSyncGate(
                online: online,
                loading: buffer.loading,
                hasContent: buffer.messages.isNotEmpty,
                builder: (context, syncing) => syncing
                    ? const LinearProgressIndicator()
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: Builder(
                  builder: (context) {
                    final typing = current.typing;
                    final count = buffer.messages.length;
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: EarlierOnScroll(
                            canLoad: () =>
                                online &&
                                !buffer.loading &&
                                !buffer.loadingEarlier &&
                                buffer.more &&
                                count > 0 &&
                                buffer.earlierError == null &&
                                !_restoringScroll,
                            onLoad: _loadEarlier,
                            onUserScroll: (_, scrolling) =>
                                _userScrolling = scrolling,
                            onScrollDelta: (notification, delta) {
                              if (_restoringScroll) return;
                              _follow =
                                  followAfterScroll(
                                    notification.metrics,
                                    delta,
                                  ) ??
                                  _follow;
                            },
                            child:
                                NotificationListener<ScrollMetricsNotification>(
                                  onNotification: (_) {
                                    _followLatest();
                                    return false;
                                  },
                                  child: ListView.builder(
                                    key: const ValueKey('group-history'),
                                    controller: _scroll,
                                    itemCount: count + typing.length,
                                    itemBuilder: (context, index) {
                                      if (index >= count) {
                                        final botId = typing[index - count];
                                        return BotTypingBubble(
                                          state: state,
                                          bot: BotRef(desktop, _bot(botId)),
                                          name: _bot(botId).name,
                                        );
                                      }
                                      final message = buffer.messages[index];
                                      final previous = index > 0
                                          ? buffer.messages[index - 1]
                                          : null;
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          if (ChatTimeLine.between(
                                            previous?.at,
                                            message.at,
                                          ))
                                            ChatTimeLine(
                                              message.at,
                                              key: ValueKey((
                                                'group-divider',
                                                message.seq,
                                              )),
                                              state: state,
                                            ),
                                          _message(message),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                          ),
                        ),
                        if (buffer.loadingEarlier ||
                            buffer.earlierError != null)
                          EarlierStatusOverlay(
                            loading: buffer.loadingEarlier,
                            error: buffer.earlierError,
                            onRetry: online && !buffer.loadingEarlier
                                ? _loadEarlier
                                : null,
                            tr: state.tr,
                          ),
                      ],
                    );
                  },
                ),
              ),
              if (_quote case final quote?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            final data = _quoteData(quote);
                            return QuoteChip(
                              who: data.who,
                              text: data.text,
                              onTap: data.onTap,
                            );
                          },
                        ),
                      ),
                      IconButton(
                        tooltip: state.tr('取消引用', 'Cancel quote'),
                        onPressed: () => setState(() => _quote = null),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
              if (_images.isNotEmpty)
                SizedBox(
                  height: 72,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final image in _images)
                        Stack(
                          children: [
                            Image.memory(
                              image.bytes,
                              width: 72,
                              height: 72,
                              fit: BoxFit.cover,
                              cacheWidth:
                                  (72 * MediaQuery.devicePixelRatioOf(context))
                                      .round(),
                            ),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: _sending
                                    ? null
                                    : () {
                                        _images.remove(image);
                                        _draftChanged();
                                      },
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(8),
                // 只有输入栏跟着字变，不整页重建。
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _text,
                  builder: (context, value, _) => ChatInputBar(
                    tr: state.tr,
                    controller: _text,
                    focusNode: _focus,
                    hint: state.tr('发消息…', 'Message…'),
                    enabled: ready,
                    canSend:
                        ready &&
                        (value.text.trim().isNotEmpty || _images.isNotEmpty),
                    busy: _sending,
                    onSend: _send,
                    onAdd: ready ? toggleAdd : null,
                    onFieldTap: addToKeyboard,
                    fieldKey: const ValueKey('group-composer'),
                    inputFormatters: [
                      _MentionTrigger(
                        () => WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _mention(current);
                        }),
                      ),
                    ],
                  ),
                ),
              ),
              if (addOpen)
                ChatAddPanel(
                  height: addPanelHeight,
                  tiles: [
                    ChatAddTile(
                      id: 'album',
                      icon: 'images',
                      label: state.tr('相册', 'Photos'),
                      onTap: ready ? () => _pickPanel(camera: false) : null,
                    ),
                    ChatAddTile(
                      id: 'camera',
                      icon: 'camera',
                      label: state.tr('拍摄', 'Camera'),
                      onTap: ready ? () => _pickPanel(camera: true) : null,
                    ),
                  ],
                )
              else
                addReserve,
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupImages extends StatefulWidget {
  const _GroupImages({
    super.key,
    required this.state,
    required this.desktop,
    required this.group,
    required this.images,
    required this.mine,
  });
  final AppState state;
  final String desktop, group;
  final List<String> images;
  final bool mine;
  @override
  State<_GroupImages> createState() => _GroupImagesState();
}

class _GroupImagesState extends State<_GroupImages> {
  List<GalleryImage>? _images;
  Object? _error;
  bool _loading = false;

  GroupImageCache get _cache => widget.state.groupImages;

  @override
  void initState() {
    super.initState();
    final cached = _cached();
    // 全在缓存里就同步画出来，不闪一下加载条。
    if (cached != null) {
      _images = cached;
    } else {
      unawaited(_load());
    }
  }

  List<GalleryImage>? _cached() {
    final images = <GalleryImage>[];
    for (final name in widget.images) {
      final bytes = _cache.get(widget.desktop, widget.group, name);
      if (bytes == null) return null;
      images.add(GalleryImage(bytes, name: name));
    }
    return images;
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final images = await Future.wait([
        for (final name in widget.images) _image(name),
      ]);
      if (!mounted) return;
      setState(() {
        _images = images;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      _loading = false;
    }
  }

  Future<GalleryImage> _image(String name) async {
    if (_cache.get(widget.desktop, widget.group, name) case final bytes?) {
      return GalleryImage(bytes, name: name);
    }
    final data = objectMap(
      await widget.state.request(widget.desktop, LinkMethods.groupImage, {
        'group': widget.group,
        'image': name,
      }),
    );
    if (data['data'] is! String || data['type'] is! String) {
      throw const FormatException('群图片未确认');
    }
    final bytes = base64Decode(data['data'] as String);
    _cache.put(widget.desktop, widget.group, name, bytes);
    return GalleryImage(bytes, name: name);
  }

  @override
  void didUpdateWidget(_GroupImages oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一条消息的图片换了（重发/编辑）：按新清单重取。
    if (!listEquals(oldWidget.images, widget.images) ||
        oldWidget.desktop != widget.desktop ||
        oldWidget.group != widget.group) {
      _images = _cached();
      _error = null;
      if (_images == null) unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final images = _images;
    final error = _error;
    return Padding(
      padding: botContentInsets.add(const EdgeInsets.symmetric(vertical: 8)),
      child: error != null
          ? TextButton(
              onPressed: () {
                setState(() => _error = null);
                unawaited(_load());
              },
              child: Text(userMessage(widget.state, error)),
            )
          : images == null
          ? Align(
              alignment: widget.mine
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              // 和 ImageDeck 差不多大，解码完不跳高度。
              child: Container(
                key: const ValueKey('group-image-placeholder'),
                width: ImageDeck.pictureWidth + 40,
                height: (ImageDeck.pictureWidth * 1.3).ceilToDouble(),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            )
          : Align(
              alignment: widget.mine
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: ImageDeck(images: images, tr: widget.state.tr),
            ),
    );
  }
}

/// 刚打出一个“@”时叫出成员列表；粘贴、删改都不算。
class _MentionTrigger extends TextInputFormatter {
  _MentionTrigger(this.onTyped);
  final VoidCallback onTyped;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final at = newValue.selection.baseOffset;
    if (newValue.text.length == oldValue.text.length + 1 &&
        at >= 1 &&
        newValue.text[at - 1] == '@' &&
        newValue.text.replaceRange(at - 1, at, '') == oldValue.text) {
      onTyped();
    }
    return newValue;
  }
}

const _memberAvatar = 56.0;
const _pickAvatar = 36.0;
const _memberTileWidth = 60.0;

class GroupInfoPage extends StatefulWidget {
  const GroupInfoPage({
    super.key,
    required this.state,
    required this.desktop,
    required this.group,
  });
  final AppState state;
  final String desktop;
  final LinkGroup group;
  @override
  State<GroupInfoPage> createState() => _GroupInfoPageState();
}

class _GroupInfoPageState extends State<GroupInfoPage> {
  late final saver = widget.state.groupProfileSaver(
    widget.desktop,
    group: widget.group,
  );
  LinkGroup? _saved;
  bool _saving = false;
  AppState get state => widget.state;

  LinkGroup get _group =>
      state.groups
          .where(
            (ref) =>
                ref.desktopId == widget.desktop &&
                ref.group.id == widget.group.id,
          )
          .firstOrNull
          ?.group ??
      _saved ??
      widget.group;

  BotRef _memberOn(String id) =>
      state.botOn(widget.desktop, id) ??
      BotRef(
        widget.desktop,
        LinkBot(id: id, name: state.tr('已离群的 Bot', 'Former member')),
      );

  void _hint(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  String _saveFailure(Object error) => error is GroupSettingsUnconfirmed
      ? state.tr(
          '电脑未确认所选群设置，请核对实际设置；旧版电脑可能不支持。已确认的群身份会保留，不会重复创建。',
          'The desktop did not confirm these group settings. Check the actual settings; an older desktop may not support them. The confirmed group identity is kept; it will not be created again.',
        )
      : userMessage(state, error);

  Future<void> _save({
    String? name,
    List<String>? members,
    int? passes,
    String? rules,
    int? gap,
  }) async {
    if (_saving) return;
    final current = _group;
    setState(() => _saving = true);
    try {
      final saved = await saver.save(
        name: name ?? current.name,
        members: members ?? current.members,
        passes: passes ?? current.passes,
        rules: rules ?? current.rules,
        gap: gap ?? current.gap,
      );
      await state.refreshDesktopState(widget.desktop);
      if (mounted) setState(() => _saved = saved);
    } on Object catch (error) {
      if (!mounted) return;
      _hint(_saveFailure(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editText(
    String title,
    String value,
    String note,
    Future<void> Function(String text) save,
  ) async {
    final text = await openPage<String>(
      context,
      LongTextPage(state: state, title: title, value: value, note: note),
    );
    if (text == null || text == value || !mounted) return;
    await save(text);
  }

  Future<void> _addMembers() async {
    final group = _group;
    final candidates = [
      for (final ref in state.bots)
        if (ref.desktopId == widget.desktop &&
            !group.members.contains(ref.bot.id))
          ref,
    ];
    final added = await openPage<List<String>>(
      context,
      _GroupMemberPicker(
        state: state,
        title: state.tr('添加成员', 'Add members'),
        refs: candidates,
        minSelected: 1,
      ),
    );
    if (added == null || added.isEmpty || !mounted) return;
    await _save(members: [...group.members, ...added]);
  }

  Future<void> _removeMembers() async {
    final group = _group;
    final refs = [for (final id in group.members) _memberOn(id)];
    final removed = await openPage<List<String>>(
      context,
      _GroupMemberPicker(
        state: state,
        title: state.tr('移除成员', 'Remove members'),
        refs: refs,
        minSelected: 1,
        maxSelected: refs.length - 1,
      ),
    );
    if (removed == null || removed.isEmpty || !mounted) return;
    await _save(
      members: [
        for (final id in group.members)
          if (!removed.contains(id)) id,
      ],
    );
  }

  Future<void> _pickPasses() async {
    final group = _group;
    final value = await openPage<int>(
      context,
      _GroupChoicePage(
        state: state,
        title: state.tr('最多传话次数', 'Most passes'),
        options: [
          for (final passes in const [2, 3, 4, 5, 6, 8, 10, 15, 20])
            (label: state.tr('$passes 次', '$passes times'), value: passes),
          (label: state.tr('不限', 'Unlimited'), value: 0),
        ],
        selected: group.passes,
        note: state.tr(
          '你每说一句话之后，Bot 之间最多互相传几次话，然后等你开口。',
          'After each of your messages, how many times the bots may pass the conversation on before they wait for you.',
        ),
      ),
    );
    if (value != null && value != group.passes && mounted) {
      await _save(passes: value);
    }
  }

  Future<void> _pickGap() async {
    final group = _group;
    final preset = _gapPresets.contains(group.gap);
    final value = await openPage<int>(
      context,
      _GroupChoicePage(
        state: state,
        title: state.tr('回复间隔', 'Reply interval'),
        options: [
          for (final gap in _gapPresets)
            (label: _gapLabel(state, gap), value: gap),
        ],
        selected: preset ? group.gap : -1,
        note: state.tr(
          'Bot 接过别的 Bot 传来的话后，等多久再回复。你说话时它们照常马上回。',
          'How long a bot waits, handed the conversation by another, before it answers. Bots still answer you at once.',
        ),
        customValue: preset ? null : _gapLabel(state, group.gap),
        custom: () => _askSeconds(group.gap),
      ),
    );
    if (value != null && value != group.gap && mounted) {
      await _save(gap: value);
    }
  }

  Future<int?> _askSeconds(int current) => showDialog<int>(
    context: context,
    builder: (context) => _SecondsDialog(state: state, current: current),
  );

  Future<void> _delete() async {
    final group = saver.saved ?? _group;
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final deleted = await runUi(
        context,
        () => deleteGroup(context, state, widget.desktop, group),
        errorMessage: (error) => userMessage(state, error),
      );
      if (deleted == true && mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _memberTile(BotRef ref) {
    final theme = Theme.of(context);
    return SizedBox(
      width: _memberTileWidth,
      child: Column(
        children: [
          BotAvatar(state: state, ref: ref, size: _memberAvatar),
          const SizedBox(height: 4),
          Text(
            ref.bot.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 和成员同高的一格：头像位、下面一行留白。
  Widget _actionTile(IconData icon, VoidCallback? onTap) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(
      _memberAvatar * MobileSizes.avatarCorner,
    );
    return SizedBox(
      width: _memberTileWidth,
      child: Column(
        children: [
          SizedBox.square(
            dimension: _memberAvatar,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: radius,
                onTap: onTap,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Icon(
                    icon,
                    size: 28,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Opacity(
            opacity: 0,
            child: Text('名', maxLines: 1, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final group = _group;
        final members = [for (final id in group.members) _memberOn(id)];
        final rules = group.rules.split('\n').first.trim();
        final shortRules = rules.length > 12
            ? '${rules.substring(0, 12)}…'
            : rules;
        return Scaffold(
          appBar: AppBar(title: Text(state.tr('聊天信息', 'Chat info'))),
          body: Column(
            children: [
              if (_saving) const LinearProgressIndicator(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  children: [
                    SectionLabel(
                      state.tr(
                        '群成员 (${members.length})',
                        'Members (${members.length})',
                      ),
                      top: 8,
                    ),
                    GroupCard(
                      children: [
                        // 铺满卡片，成员从左排起；不然 Wrap 缩成内容宽被居中。
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              for (final ref in members) _memberTile(ref),
                              _actionTile(
                                Icons.add,
                                _saving ? null : _addMembers,
                              ),
                              _actionTile(
                                Icons.remove,
                                _saving || members.length <= 1
                                    ? null
                                    : _removeMembers,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    GroupCard(
                      children: [
                        SettingsRow(
                          state.tr('群聊名称', 'Group name'),
                          value: groupTitle(
                            state,
                            GroupRef(widget.desktop, group),
                          ),
                          onTap: _saving
                              ? null
                              : () => _editText(
                                  state.tr('群聊名称', 'Group name'),
                                  group.name,
                                  state.tr(
                                    '留空时用成员名字',
                                    'Members’ names are used when empty',
                                  ),
                                  (text) => _save(name: text),
                                ),
                        ),
                        SettingsRow(
                          state.tr('群规', 'Group rules'),
                          value: rules.isEmpty
                              ? state.tr('未设置', 'Not set')
                              : shortRules,
                          onTap: _saving
                              ? null
                              : () => _editText(
                                  state.tr('群规', 'Group rules'),
                                  group.rules,
                                  state.tr(
                                    '群里每个 Bot 每次说话都会遵守。助理也能修改。例如：只聊周末去哪玩，轻松点',
                                    'Every bot follows this whenever it speaks. The assistant can change it too. For example: only talk about weekend plans, keep it light',
                                  ),
                                  (text) => _save(rules: text),
                                ),
                        ),
                        SettingsRow(
                          state.tr('最多传话次数', 'Most passes'),
                          value: group.passes == 0
                              ? state.tr('不限', 'Unlimited')
                              : state.tr(
                                  '${group.passes} 次',
                                  '${group.passes} times',
                                ),
                          onTap: _saving ? null : _pickPasses,
                        ),
                        SettingsRow(
                          state.tr('回复间隔', 'Reply interval'),
                          value: _gapLabel(state, group.gap),
                          onTap: _saving ? null : _pickGap,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    GroupCard(
                      children: [
                        SettingsRow(
                          state.tr('删除群聊', 'Delete group'),
                          color: theme.colorScheme.error,
                          trailing: const SizedBox.shrink(),
                          onTap: _saving ? null : _delete,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SecondsDialog extends StatefulWidget {
  const _SecondsDialog({required this.state, required this.current});
  final AppState state;
  final int current;
  @override
  State<_SecondsDialog> createState() => _SecondsDialogState();
}

class _SecondsDialogState extends State<_SecondsDialog> {
  late final _text = TextEditingController(text: '${widget.current}');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final seconds = int.tryParse(_text.text);
    if (seconds != null && seconds >= 0) Navigator.pop(context, seconds);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return AlertDialog(
      title: Text(state.tr('自定义间隔', 'Custom interval')),
      content: TextField(
        controller: _text,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(suffixText: state.tr('秒', 'sec')),
      ),
      actions: dialogButtons([
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: Text(state.tr('取消', 'Cancel')),
        ),
        FilledButton(onPressed: _submit, child: Text(state.tr('确定', 'OK'))),
      ]),
    );
  }
}

const _gapPresets = [0, 5, 10, 30, 60, 120, 300, 600];

String _gapLabel(AppState state, int seconds) => seconds == 0
    ? state.tr('立即', 'At once')
    : seconds < 60 || seconds % 60 != 0
    ? state.tr('$seconds 秒', '$seconds sec')
    : state.tr('${seconds ~/ 60} 分钟', '${seconds ~/ 60} min');

class _GroupChoicePage extends StatelessWidget {
  const _GroupChoicePage({
    required this.state,
    required this.title,
    required this.options,
    required this.selected,
    required this.note,
    this.customValue,
    this.custom,
  });
  final AppState state;
  final String title;
  final List<({String label, int value})> options;
  final int selected;
  final String note;
  final String? customValue;
  final Future<int?> Function()? custom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          GroupCard(
            children: [
              for (final option in options)
                PickRow(
                  option.label,
                  selected: option.value == selected,
                  onTap: () => Navigator.pop(context, option.value),
                ),
              if (custom != null)
                SettingsRow(
                  state.tr('自定义', 'Custom'),
                  value: customValue,
                  onTap: () async {
                    final value = await custom!();
                    if (value != null && context.mounted) {
                      Navigator.pop(context, value);
                    }
                  },
                ),
            ],
          ),
          CardNote(note),
        ],
      ),
    );
  }
}

class _GroupMemberPicker extends StatefulWidget {
  const _GroupMemberPicker({
    required this.state,
    required this.title,
    required this.refs,
    required this.minSelected,
    this.maxSelected,
  });
  final AppState state;
  final String title;
  final List<BotRef> refs;
  final int minSelected;
  final int? maxSelected;
  @override
  State<_GroupMemberPicker> createState() => _GroupMemberPickerState();
}

class _GroupMemberPickerState extends State<_GroupMemberPicker> {
  final _selected = <String>{};
  AppState get state => widget.state;

  bool get _enabled =>
      _selected.length >= widget.minSelected &&
      (widget.maxSelected == null || _selected.length <= widget.maxSelected!);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        doneButton(
          state,
          _enabled
              ? () => Navigator.pop(context, [
                  for (final ref in widget.refs)
                    if (_selected.contains(ref.bot.id)) ref.bot.id,
                ])
              : null,
        ),
      ],
    ),
    body: widget.refs.isEmpty
        ? Center(
            child: Text(
              state.tr('没有可选的 Bot', 'No bots to choose'),
              style: MobileTheme.hintStyleOf(context),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              GroupCard(
                children: [
                  for (final ref in widget.refs)
                    PickRow(
                      ref.bot.name,
                      subtitle: ref.bot.signature,
                      checkbox: true,
                      leading: BotAvatar(
                        state: state,
                        ref: ref,
                        size: _pickAvatar,
                      ),
                      selected: _selected.contains(ref.bot.id),
                      onTap: () => setState(() {
                        if (!_selected.remove(ref.bot.id)) {
                          _selected.add(ref.bot.id);
                        }
                      }),
                    ),
                ],
              ),
            ],
          ),
  );
}

/// 创建结果没确认时：刷新、挑出已经建好的群，绑到 [saver] 上。
Future<LinkGroup?> _checkCreatedGroup(
  BuildContext context,
  AppState state,
  String desktop,
  GroupProfileSaver saver,
) async {
  final snapshot = await state.refreshDesktopState(desktop);
  if (!context.mounted) return null;
  final group = await showModalBottomSheet<LinkGroup>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              state.tr(
                '选择已创建的群聊；没有找到请在电脑端核对',
                'Choose the group already created; check the desktop if it is missing',
              ),
            ),
          ),
          for (final group in snapshot.groups)
            ListTile(
              title: Text(group.name),
              onTap: () => Navigator.pop(context, group),
            ),
        ],
      ),
    ),
  );
  if (group != null) saver.useExisting(group);
  return group;
}

/// 删除 [group]：先确认，电脑确认后刷新列表，并取消手机上的置顶。
Future<bool> deleteGroup(
  BuildContext context,
  AppState state,
  String desktop,
  LinkGroup group,
) async {
  if (!await confirmAction(
    context,
    state,
    state.tr('删除群聊？', 'Delete group?'),
    state.tr(
      '群聊与全部群消息会从电脑删除。',
      'The group and all its messages will be deleted from the desktop.',
    ),
    destructive: true,
  )) {
    return false;
  }
  await state.request(desktop, LinkMethods.deleteGroup, {'group': group.id});
  await state.setGroupPinned(GroupRef(desktop, group), false);
  await state.refreshDesktopState(desktop);
  return true;
}

Future<void> startGroupChat(
  BuildContext context,
  AppState state,
  String desktop,
) async {
  final ids = await openPage<List<String>>(
    context,
    _GroupMemberPicker(
      state: state,
      title: state.tr('发起群聊', 'Start group chat'),
      refs: [
        for (final ref in state.bots)
          if (ref.desktopId == desktop) ref,
      ],
      minSelected: 2,
    ),
  );
  if (ids == null || ids.isEmpty || !context.mounted) return;
  final saver = state.groupProfileSaver(desktop);
  var group = saver.saved;
  try {
    group = await saver.save(
      name: '',
      members: ids,
      passes: linkGroupPasses,
      rules: '',
      gap: 0,
    );
    await state.refreshDesktopState(desktop);
  } on Object catch (error) {
    if (!context.mounted) return;
    if (!saver.creationUnconfirmed) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(userMessage(state, error))));
      return;
    }
    final refresh = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(state.tr('创建结果未确认', 'Creation unconfirmed')),
        content: Text(
          state.tr(
            '创建结果未确认，请先刷新并核对群聊，不能再次创建。',
            'Creation unconfirmed. Refresh and check the groups before trying again.',
          ),
        ),
        actions: dialogButtons([
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(state.tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(state.tr('刷新并核对', 'Refresh and check')),
          ),
        ]),
      ),
    );
    if (refresh != true || !context.mounted) return;
    try {
      group = await _checkCreatedGroup(context, state, desktop, saver);
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(userMessage(state, error))));
      return;
    }
  }
  if (group == null || !context.mounted) return;
  await openPage<void>(
    context,
    GroupChatPage(state: state, ref: GroupRef(desktop, group)),
  );
}
