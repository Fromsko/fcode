// ignore_for_file: invalid_use_of_protected_member
part of 'chat_page.dart';

/// 输入区：两种输入栏、附件、粘贴、面板和本地排队。
extension _Composer on _ChatPageState {
  /// Whether a message sent now waits on the phone: the agent is at work, or
  /// messages queued earlier have not gone out yet (a new one must not pass
  /// them).
  bool get _queueing =>
      _buffer.live ||
      widget.state.localQueue.messages(widget.desktopId, _sessionId).isNotEmpty;

  /// 清空输入：文字、待发图片和 @ 提及。正在编辑时只清内容，不退出编辑。
  void _clearInput() {
    if (_composer.text.trim().isEmpty && _images.isEmpty && _files.isEmpty) {
      return;
    }
    setState(() {
      _images.clear();
      _files.clear();
      _fileSelection = null;
      _mentions.clear();
      _imagesMissing = false;
      _composer.clear();
    });
    if (_editIndex == null) _saveDraft('');
  }

  /// 有东西可清时才出现的橡皮。
  Widget _clearButton() => ValueListenableBuilder<TextEditingValue>(
    valueListenable: _composer,
    builder: (context, value, _) =>
        value.text.trim().isEmpty && _images.isEmpty && _files.isEmpty
        ? const SizedBox.shrink()
        : IconButton(
            tooltip: tr('清空输入', 'Clear input'),
            onPressed: _clearInput,
            color: Theme.of(context).colorScheme.error,
            icon: const LucideIcon('eraser', size: 22),
          ),
  );

  /// Puts the draft on the phone's queue and clears the input; nothing is
  /// sent until the turn ends.
  void _queueDraft() {
    _botReplySuggestions.dismiss();
    final input = _input;
    final assembled = assembleInput(input);
    widget.state.localQueue.add(
      widget.desktopId,
      _sessionId,
      text: assembled.text,
      images: input.images,
      mentions: assembled.mentions,
      draft: input,
      project: widget.projectId,
      bot: widget.botId,
    );
    setState(() {
      _error = null;
      _images.clear();
      _files.clear();
      _fileSelection = null;
      _mentions.clear();
      _composer.clear();
    });
    _saveDraft('');
  }

  Future<void> _localNow(LocalQueuedMessage message) async {
    if (!_online || _sending || _uploading) return;
    final sent = await widget.state.localQueue.sendNow(
      widget.desktopId,
      _sessionId,
      message.id,
    );
    if (sent && mounted) _forceBottom();
  }

  /// Takes the message back into the input, with its pictures and files. A
  /// draft already there is kept: the message is added after it.
  void _localEdit(LocalQueuedMessage message) {
    final taken = widget.state.localQueue.take(
      widget.desktopId,
      _sessionId,
      message.id,
    );
    if (taken == null) {
      setState(
        () => _error = tr(
          '这条消息已经在发送或已移出队列。',
          'That message is being sent or already left the queue.',
        ),
      );
      return;
    }
    final draft = _composer.text.trim();
    final restored =
        taken.draft ??
        InputDraft(
          text: taken.text,
          images: taken.images,
          mentions: taken.mentions.toSet(),
        );
    _images.addAll(restored.images);
    _files.addAll(restored.files);
    _mentions.addAll(restored.mentions);
    _composer.text = draft.isEmpty ? restored.text : '$draft\n${restored.text}';
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
    _draftChanged();
    _composerFocus.requestFocus();
  }

  void _localRemove(LocalQueuedMessage message) {
    widget.state.localQueue.take(widget.desktopId, _sessionId, message.id);
  }

  /// 输入框上方显示连接、编辑提示，以及发送后等待执行的消息。
  List<Widget> _composerNotices() {
    final queue = widget.state.localQueue;
    final held = _hasSession
        ? queue.messages(widget.desktopId, _sessionId).length
        : 0;
    final failure = _hasSession
        ? queue.failure(widget.desktopId, _sessionId)
        : null;
    final offline = [
      if (!_online)
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _composer,
          builder: (context, value, _) {
            final hasDraft =
                value.text.trim().isNotEmpty ||
                _images.isNotEmpty ||
                _files.isNotEmpty;
            if (!hasDraft && held == 0) return const SizedBox.shrink();
            final status = _status;
            return ComposerNotice(
              key: const ValueKey('offline-notice'),
              icon: 'plug',
              title: switch (status) {
                DesktopLinkStatus.connecting => tr(
                  '正在连接电脑，连上后才能发送',
                  'Connecting; you can send once connected',
                ),
                DesktopLinkStatus.needsPairing => tr(
                  '需要重新配对才能发送',
                  'Pair again to send',
                ),
                _ => tr('未连接电脑，暂时发不出去', 'Not connected; cannot send yet'),
              },
              detail: switch ((hasDraft, held > 0)) {
                (true, true) => tr(
                  '草稿和排队消息已保留',
                  'draft and queued messages kept',
                ),
                (false, true) => tr(
                  '排队消息已保留，连上后继续发送',
                  'queued messages kept, sent once connected',
                ),
                _ => tr('草稿已保留', 'draft kept'),
              },
              actionLabel: status == DesktopLinkStatus.offline
                  ? tr('重试', 'Retry')
                  : null,
              onAction: status == DesktopLinkStatus.offline
                  ? () => widget.state.retryConnection(widget.desktopId)
                  : null,
            );
          },
        ),
      // What the queue could not send stays queued; the user says when to try again.
      if (failure != null && _online)
        ComposerNotice(
          key: const ValueKey('queue-failure-notice'),
          icon: 'triangle-alert',
          tone: Theme.of(context).colorScheme.error,
          title: failure,
          actionLabel: tr('重试', 'Retry'),
          onAction: _uploading
              ? null
              : () => queue.retry(widget.desktopId, _sessionId),
        ),
    ];
    if (_editIndex != null) return offline;
    final rows = _hasSession
        ? queue.messages(widget.desktopId, _sessionId)
        : const <LocalQueuedMessage>[];
    return [
      ...offline,
      if (rows.isNotEmpty)
        QueuedMessagesPanel(
          messages: rows,
          tr: tr,
          enabled:
              _online &&
              !_commandBusy &&
              !_sending &&
              !_uploading &&
              !queue.busy(widget.desktopId, _sessionId),
          onSendNow: _localNow,
          onEdit: _localEdit,
          onRemove: _localRemove,
        ),
    ];
  }

  /// The input card's own first line while a sent message is edited, so it
  /// reads as the composer's state rather than as the chat's.
  Widget _editHeader(SessionBuffer buffer) => Padding(
    padding: const EdgeInsets.only(left: MobileSpace.sm),
    child: ComposerNotice(
      key: const ValueKey('editing-notice'),
      icon: 'pencil',
      tone: _editValid
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.error,
      title: _editValid
          ? tr('正在编辑', 'Editing')
          : tr('编辑的消息已变化', 'The message changed'),
      detail: !_editValid
          ? tr('请取消后重新选择', 'Cancel and select it again')
          : buffer.loading
          ? tr('正在同步对话', 'Syncing the conversation')
          : buffer.live
          ? tr('将中断并丢弃后续', 'Stops this turn, drops what follows')
          : tr('后续对话将被丢弃', 'Drops what follows'),
      actionLabel: tr('取消', 'Cancel'),
      onAction: _sending || _uploading ? null : _cancelEdit,
    ),
  );

  Future<void> _paste() async {
    if (_pasting) return;
    _pasting = true;
    final before = _composer.value;
    final generation = _binding.generation;
    final editing = _editAnchor;
    try {
      final content = await ChatClipboard.read();
      final text =
          content?.text ??
          (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (!mounted || (text == null && content == null)) return;
      if (generation != _binding.generation ||
          editing != _editAnchor ||
          _composer.value != before) {
        setState(
          () => _error = tr(
            '输入内容已变化，请重新粘贴。',
            'The input changed. Please paste again.',
          ),
        );
        return;
      }
      final selection = before.selection;
      final start = selection.isValid ? selection.start : before.text.length;
      final end = selection.isValid ? selection.end : before.text.length;
      _images.addAll([
        for (final image in content?.images ?? const <ImageAttachment>[])
          DraftImage(image.name ?? 'image', image.mediaType, image.bytes),
      ]);
      _composer.value = TextEditingValue(
        text: before.text.replaceRange(start, end, text ?? ''),
        selection: TextSelection.collapsed(offset: start + (text?.length ?? 0)),
      );
      _draftChanged();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = tr(
            '无法粘贴图文，请重新复制后再试。',
            'Could not paste the message. Copy it again and retry.',
          ),
        );
      }
    } finally {
      _pasting = false;
    }
  }

  Widget _pasteScope(Widget child) => Actions(
    actions: {
      PasteTextIntent: CallbackAction<PasteTextIntent>(
        onInvoke: (_) {
          unawaited(_paste());
          return null;
        },
      ),
    },
    child: child,
  );

  Widget _pasteMenu(BuildContext context, EditableTextState editable) {
    final items = editable.contextMenuButtonItems;
    final paste = ContextMenuButtonItem(
      type: ContextMenuButtonType.paste,
      onPressed: () {
        editable.hideToolbar();
        unawaited(_paste());
      },
    );
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editable.contextMenuAnchors,
      buttonItems: [
        for (final item in items)
          item.type == ContextMenuButtonType.paste ? paste : item,
        if (!items.any((item) => item.type == ContextMenuButtonType.paste))
          paste,
      ],
    );
  }

  Future<void> _pickImages({ImageSource? source}) async {
    _composerFocus.unfocus();
    if (_picking || _uploading || _sending) return;
    setState(() => _picking = true);
    try {
      final picked = await pickConversationImages(widget.state, source: source);
      if (mounted && picked.isNotEmpty) {
        _images.addAll(picked);
        _draftChanged();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = userMessage(widget.state, error));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 和文件页同一个浏览：一层层点进项目，点到文件就把它 @ 进输入框。
  /// 回来以后像选完图片一样把键盘叫回来。
  Future<void> _mention() async {
    _composerFocus.unfocus();
    final project = _project;
    if (project == null) return;
    final selected = await openPage<String>(
      context,
      FilesPage(state: widget.state, project: project, picking: true),
    );
    if (!mounted) return;
    _composerFocus.requestFocus();
    if (selected == null) return;
    _insertFileMention(selected);
  }

  /// 输入框以 `/` 开头时的命令列表：内置的常用命令、电脑上的技能和项目命令。
  Widget _slashMenu() {
    final query = _editIndex == null ? slashQuery(_composer.text) : null;
    if (query == null) return const SizedBox.shrink();
    if ((_projectCommands == null || _skills == null) &&
        _online &&
        !clock.now().isBefore(_desktopCommandsDue)) {
      unawaited(_loadDesktopCommands());
    }
    final matches = matchSlashCommands([
      ...builtinSlashCommands(tr),
      ...?_projectCommands,
      ...?_skills,
    ], query);
    if (matches.isEmpty) return const SizedBox.shrink();
    return SlashCommandMenu(
      commands: matches,
      projectLabel: tr('项目', 'Project'),
      onPick: (command) {
        final text = '/${command.name} ';
        _composer.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        _composerFocus.requestFocus();
      },
    );
  }

  /// 只问还没拿到的那份；没拿全的，[_desktopCommandsRetry] 之后再打 `/` 时重问。
  Future<void> _loadDesktopCommands() async {
    _desktopCommandsDue = DateTime(9999);
    final (commands, skills) = await (
      _projectCommands == null
          ? _loadProjectCommands()
          : Future.value(_projectCommands),
      _skills == null ? _loadSkills() : Future.value(_skills),
    ).wait;
    _desktopCommandsDue = clock.now().add(_desktopCommandsRetry);
    if (!mounted) return;
    setState(() {
      _projectCommands = commands;
      _skills = skills;
    });
  }

  static const _desktopCommandsRetry = Duration(seconds: 10);

  /// 拿不到（断线、超时）是 null；电脑端太旧不认 `extensions` 就当没有。
  Future<List<SlashCommand>?> _loadSkills() async {
    try {
      final result = await widget.state.request(
        widget.desktopId,
        LinkMethods.extensions,
      );
      return [
        for (final item in (objectMap(result)['items'] as List?) ?? const [])
          if (LinkExtension.fromJson(objectMap(item)) case final skill
              when skill.kind == 'skill' &&
                  skill.enabled != false &&
                  (skill.project == null || skill.project == widget.projectId))
            SlashCommand(
              skill.name,
              skill.description,
              kind: SlashKind.skill,
              project: skill.project != null,
            ),
      ];
    } on LinkRemoteException catch (error) {
      return error.code == LinkErrors.unknown ? const [] : null;
    } on Object {
      return null;
    }
  }

  /// 项目 `.claude/commands` 下的命令文件，经电脑的 `folder`、`read` 读来；
  /// 拿不到（断线、超时）是 null。
  Future<List<SlashCommand>?> _loadProjectCommands() async {
    final project = widget.projectId;
    if (project == null) return const [];
    const folder = '.claude/commands';
    final Map<String, Object?> listing;
    try {
      listing = objectMap(
        await widget.state.request(widget.desktopId, LinkMethods.folder, {
          'project': project,
          'path': folder,
        }),
      );
    } on LinkRemoteException catch (error) {
      // 没有这个文件夹，或电脑端还不认 `folder`。
      return error.code == LinkErrors.notFound ||
              error.code == LinkErrors.unknown
          ? const []
          : null;
    } on Object {
      return null;
    }
    final names = [
      for (final name in (listing['files'] as List?) ?? const [])
        if (name is String && name.endsWith('.md')) name,
    ].take(_maxProjectCommands);
    try {
      final read = await Future.wait([
        for (final name in names) _readProjectCommand(project, folder, name),
      ]);
      return [...read.nonNulls];
    } on Object {
      return null;
    }
  }

  Future<SlashCommand?> _readProjectCommand(
    String project,
    String folder,
    String name,
  ) async {
    try {
      final file = objectMap(
        await widget.state.request(widget.desktopId, LinkMethods.read, {
          'project': project,
          'path': '$folder/$name',
        }),
      );
      return switch (file['text']) {
        final String text => projectSlashCommand(name, text),
        _ => null,
      };
    } on LinkRemoteException catch (error) {
      // 列出来之后被删了。
      if (error.code == LinkErrors.notFound) return null;
      rethrow;
    }
  }

  static const _maxProjectCommands = 50;

  Widget _draftImages() {
    // 待发附件共用一个画廊；移除某张后组随之重建。
    final group = [
      for (final image in _images) GalleryImage(image.bytes, name: image.name),
    ];
    return _draftImageStrip(group);
  }

  Widget _draftImageStrip(List<GalleryImage> group) {
    // Bot 的图片排在输入框上方，输入框仍是一行。
    final bot = widget.botId != null;
    final thumbnail = bot ? 64.0 : 76.0;
    final bottom = bot ? 0.0 : 8.0;
    return SizedBox(
      // 文件卡：一行名字加最多两行状态，大字号时随之放高。
      height:
          (_files.isEmpty
              ? thumbnail
              : math.max(
                  thumbnail,
                  MobileSpace.sm * 2 +
                      60 * MediaQuery.textScalerOf(context).scale(1),
                )) +
          8 +
          bottom,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(12, 8, 12, bottom),
        scrollDirection: Axis.horizontal,
        itemCount: _images.length + _files.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i >= _images.length) {
            final file = _files[i - _images.length];
            final pending = file.status == DraftFileStatus.uploading;
            return SizedBox(
              width: bot ? 184 : 200,
              child: FileAttachment(
                name: file.name,
                path: file.path,
                size: file.size,
                nameLines: 1,
                bot: bot,
                uploading: pending,
                failed: !file.ready && !pending,
                status: switch (file.status) {
                  DraftFileStatus.uploading => tr('上传中', 'Uploading'),
                  DraftFileStatus.ready => null,
                  DraftFileStatus.failed =>
                    file.error ?? tr('上传失败', 'Upload failed'),
                  DraftFileStatus.unconfirmed =>
                    file.error ??
                        tr('上传未确认，请重新选择', 'Upload unconfirmed; select again'),
                },
                detail: file.error,
                removeLabel: tr('移除文件', 'Remove file'),
                onRemove: _sending ? null : () => _removeFile(file),
              ),
            );
          }
          return SizedBox.square(
            dimension: thumbnail,
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(bot ? 6 : 12),
                  child: MemoryPicture(
                    bytes: _images[i].bytes,
                    name: _images[i].name,
                    group: group,
                    index: i,
                    width: thumbnail,
                    height: thumbnail,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(right: 0, top: 0, child: _removeImageBadge(i)),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 缩略图角上的小角标；看着小，点击区比它大一圈。
  Widget _removeImageBadge(int index) => Tooltip(
    message: tr('移除图片', 'Remove image'),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _sending
          ? null
          : () {
              _images.removeAt(index);
              _draftChanged();
            },
      child: SizedBox.square(
        dimension: 28,
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Container(
              key: const ValueKey('draft-image-remove'),
              width: 18,
              height: 18,
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 12, color: Colors.white),
            ),
          ),
        ),
      ),
    ),
  );

  /// 同一行放输入框和按钮，面板接在下方顶替键盘，和常见聊天软件一样。
  Widget _botComposer(SessionBuffer buffer, bool ready) {
    final scheme = Theme.of(context).colorScheme;
    final line = BorderSide(color: scheme.outlineVariant, width: .5);
    final notices = _composerNotices();
    final working = buffer.live && _online;
    final bar = TapRegion(
      onTapOutside: (_) => closeAdd(),
      child: DecoratedBox(
        decoration: const BoxDecoration(),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (notices.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: notices,
                  ),
                ),
              if (_images.isNotEmpty || _files.isNotEmpty) _draftImages(),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _pasteScope(
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _composer,
                        builder: (context, value, _) {
                          final empty =
                              value.text.trim().isEmpty &&
                              _images.isEmpty &&
                              _files.isEmpty;
                          return ChatInputBar(
                            tr: tr,
                            controller: _composer,
                            focusNode: _composerFocus,
                            hint: tr('发消息…', 'Message…'),
                            enabled: ready,
                            canSend:
                                ready &&
                                !empty &&
                                !_imagesMissing &&
                                _filesReady,
                            busy: _sending,
                            onSend: _send,
                            onAdd: ready ? toggleAdd : null,
                            onFieldTap: addToKeyboard,
                            stop: working && empty && !_sending
                                ? () => _command(LinkMethods.stop)
                                : null,
                            stopBusy: _commandBusy,
                            contextMenuBuilder: _pasteMenu,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              if (addOpen)
                DecoratedBox(
                  decoration: BoxDecoration(border: Border(top: line)),
                  child: _addPanel(ready, topBorder: false),
                )
              else
                addReserve,
            ],
          ),
        ),
      ),
    );
    if (!working) return bar;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BotWorkingLine(tr: tr, since: _turnStart(buffer)),
        bar,
      ],
    );
  }

  Widget _composerView(SessionBuffer buffer, bool ready) {
    noteKeyboard(context);
    if (widget.botId != null) return _botComposer(buffer, ready);
    final live = buffer.live && _online;
    Widget stop() => StopActionButton(
      busy: _commandBusy,
      size: 48,
      iconSize: 26,
      tooltip: _commandBusy
          ? tr('正在停止…', 'Stopping…')
          : tr('停止生成', 'Stop generation'),
      onPressed: () => _command(LinkMethods.stop),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._composerNotices(),
              // As the desktop's strip: over the composer, not over the chat.
              ChatActivityCard(
                key: ValueKey((widget.desktopId, _sessionId)),
                state: widget.state,
                desktopId: widget.desktopId,
                sessionId: _sessionId,
                projectId: widget.projectId,
                agents: projectRunningAgents(
                  buffer.items.map(ChatCodec.decode).whereType<ChatItem>(),
                  buffer.tasks,
                ),
                onOpenAgent: _openRunningAgent,
                foldSignal: _trayFold,
              ),
              _slashMenu(),
              DecoratedBox(
                key: const ValueKey('composer-input-surface'),
                decoration: chatComposerDecoration(context),

                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_editIndex != null) _editHeader(buffer),
                    if (_images.isNotEmpty || _files.isNotEmpty) _draftImages(),
                    _pasteScope(
                      TextField(
                        controller: _composer,
                        focusNode: _composerFocus,
                        contextMenuBuilder: _pasteMenu,
                        // Not outside the add panel: tapping here hands it to the
                        // keyboard rather than dropping it.
                        groupId: _addRegion,
                        onTap: addToKeyboard,
                        style: Theme.of(context).textTheme.bodyMedium,
                        minLines: 1,
                        maxLines: 6,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding: EdgeInsets.fromLTRB(
                            16,
                            _editIndex != null ? 2 : 14,
                            16,
                            2,
                          ),
                          hintText: tr('发消息…', 'Message…'),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        TapRegion(
                          groupId: _addRegion,
                          child: IconButton(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            tooltip: tr('添加附件', 'Add attachment'),
                            // 和后面的选项按钮同为紧凑尺寸，图标间距才一致。
                            visualDensity: VisualDensity.compact,
                            onPressed: _sending || _picking || _uploading
                                ? null
                                : toggleAdd,
                            icon: const LucideIcon('plus', size: 22),
                          ),
                        ),
                        for (final choice in _composerChoices(buffer))
                          _choiceIconButton(choice, ready),
                        _clearButton(),
                        const Spacer(),
                        if (ContextUsage.parse(buffer.context)
                            case final usage?)
                          ContextRing(
                            state: widget.state,
                            usage: usage,
                            onPressed: () =>
                                showContextUsage(context, widget.state, usage),
                          ),
                        // 只有一个按钮：工作中没写东西时是停止，写了就是发送。
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _composer,
                          builder: (context, value, _) {
                            final hasDraft =
                                value.text.trim().isNotEmpty ||
                                _images.isNotEmpty ||
                                _files.isNotEmpty;
                            final canSend =
                                ready &&
                                !_sending &&
                                hasDraft &&
                                !_imagesMissing &&
                                _filesReady &&
                                _editReady;
                            return Padding(
                              padding: const EdgeInsets.only(left: 4, right: 8),
                              child: live && !hasDraft && !_sending
                                  ? stop()
                                  : ChatComposerAction(
                                      busy: _sending,
                                      enabled: canSend,
                                      tooltip: _editIndex != null
                                          ? tr('重新发送', 'Resend')
                                          : tr('发送', 'Send'),
                                      onSend: _send,
                                    ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 功能区铺满整行：灰底和上边线一直顶到屏幕两边才发现得出是另一块。
        if (addOpen && !_sending)
          TapRegion(
            groupId: _addRegion,
            onTapOutside: (_) => setState(() => addOpen = false),
            child: _addPanel(ready),
          ),
        if (!addOpen) addReserve,
      ],
    );
  }

  Widget _addPanel(bool ready, {bool topBorder = true}) {
    // 选完东西回到输入框：键盘跟着回来，接着打字。
    void pick(VoidCallback action) {
      setState(() => addOpen = false);
      action();
      _composerFocus.requestFocus();
    }

    ChatAddTile tile(
      String id,
      String icon,
      String label,
      VoidCallback? action,
    ) => ChatAddTile(
      id: id,
      icon: icon,
      label: label,
      onTap: action == null ? null : () => pick(action),
    );

    return ChatAddPanel(
      key: topBorder ? null : const ValueKey('chat-actions-inline'),
      height: addPanelHeight,
      tiles: [
        tile(
          'album',
          'images',
          tr('相册', 'Photos'),
          _picking || _uploading || _sending ? null : _pickImages,
        ),
        tile(
          'camera',
          'camera',
          tr('拍摄', 'Camera'),
          _picking || _uploading || _sending
              ? null
              : () => _pickImages(source: ImageSource.camera),
        ),
        tile(
          'upload',
          'arrow-up',
          tr('上传文件', 'Upload file'),
          ready && (widget.botId != null || widget.projectId != null)
              ? _pickFile
              : null,
        ),
        // 模型、模式、权限在输入框下面那排；Bot 可上传文件，但不浏览项目。
        if (widget.botId == null)
          tile(
            'file',
            'at-sign',
            tr('文件', 'Files'),
            ready && _project != null ? _mention : null,
          ),
      ],
    );
  }
}
