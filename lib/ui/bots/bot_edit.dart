part of 'bots_tab.dart';

class BotEditPage extends StatefulWidget {
  const BotEditPage({super.key, required this.state, this.ref});
  final AppState state;
  final BotRef? ref;
  @override
  State<BotEditPage> createState() => _BotEditPageState();
}

class _BotEditPageState extends State<BotEditPage> {
  late final TextEditingController _name,
      _identity,
      _style,
      _signature,
      _gender;
  late Set<BotAbility> _abilities;
  late BotProactive _proactive;

  /// An emoji, or the name of the picture the bot has.
  late String _avatar;
  String? _desktop;
  String? _avatarImage;
  String _avatarType = 'image/jpeg';
  bool _saving = false, _chatOnly = false, _needsCreationCheck = false;
  bool _writesFirst = true;
  String? _saveError;
  BotProfileSaver? _profileSaver;

  bool get _creating => widget.ref == null;

  /// The page as opened, to tell an edit from none.
  late final String _opened;
  String _snapshot() => jsonEncode({
    'text': [
      for (final c in [_name, _identity, _style, _signature, _gender])
        c.text.trim(),
    ],
    'avatar': _avatar,
    'image': _avatarImage,
    'abilities': (_abilities.map((ability) => ability.name).toList()..sort()),
    'proactive': _proactive.toJson(),
    'chatOnly': _chatOnly,
    'writesFirst': _writesFirst,
    'desktop': _desktop,
  });

  @override
  void initState() {
    super.initState();
    final bot = widget.ref?.bot;
    _name = TextEditingController(text: bot?.name ?? '');
    _identity = TextEditingController(text: bot?.identity ?? '');
    _style = TextEditingController(text: bot?.style ?? '');
    _signature = TextEditingController(text: bot?.signature ?? '');
    _gender = TextEditingController(text: bot?.gender ?? '');
    _avatar = bot?.avatar ?? '';
    _abilities = {...?bot?.abilities};
    _proactive = bot?.proactive ?? const BotProactive();
    _chatOnly = bot?.chatOnly ?? false;
    _writesFirst = bot?.writesFirst ?? true;
    _desktop = widget.ref?.desktopId ?? widget.state.selectedDesktopId;
    _opened = _snapshot();
    if (_desktop != null) {
      _profileSaver = widget.state.botProfileSaver(_desktop!, bot: bot);
      _needsCreationCheck =
          _profileSaver!.creationUnconfirmed || _profileSaver!.busy;
      if (_needsCreationCheck) {
        _saveError = widget.state.tr(
          '这台电脑上一次创建尚未确认，请先核对，避免重复创建。',
          'The previous creation on this desktop is unconfirmed. Check it before creating again.',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _identity, _style, _signature, _gender]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _photo() async {
    final picked = await pickAvatar(context, widget.state);
    if (picked == null || !mounted) return;
    setState(() {
      _avatarImage = base64Encode(picked.bytes);
      _avatarType = picked.type;
    });
    await _saveNow();
  }

  Future<void> _chooseAvatar(BuildContext anchor) async {
    final state = widget.state;
    final hasAvatar = _avatarImage != null || _avatar.isNotEmpty;
    final choice = await showMenuPanel<String>(anchor, [
      MenuPanelItem(
        'photo',
        state.tr('从相册选择', 'Choose from photos'),
        key: const ValueKey('bot-avatar-photo'),
        leading: const LucideIcon('image', size: 22),
      ),
      MenuPanelItem(
        'emoji',
        state.tr('用一个表情', 'Use an emoji'),
        key: const ValueKey('bot-avatar-emoji'),
        leading: const LucideIcon('smile', size: 22),
      ),
      if (hasAvatar)
        MenuPanelItem(
          'none',
          state.tr('不用头像', 'No avatar'),
          key: const ValueKey('bot-avatar-none'),
          leading: LucideIcon(
            'trash-2',
            size: 22,
            color: Theme.of(context).colorScheme.error,
          ),
          color: Theme.of(context).colorScheme.error,
        ),
    ], align: DropdownAlign.center);
    if (!mounted) return;
    switch (choice) {
      case 'photo':
        await _photo();
      case 'emoji':
        final emoji = await askText(
          context,
          state,
          state.tr('头像表情', 'Avatar emoji'),
          value: isAvatarImage(_avatar) ? '' : _avatar,
        );
        if (emoji != null && mounted) {
          setState(() {
            _avatar = emoji;
            _avatarImage = null;
          });
          await _saveNow();
        }
      case 'none':
        setState(() {
          _avatar = '';
          _avatarImage = null;
        });
        await _saveNow();
    }
  }

  String get _avatarLabel {
    final state = widget.state;
    if (_avatarImage != null || isAvatarImage(_avatar)) {
      return state.tr('图片', 'Picture');
    }
    return _avatar.isEmpty ? state.tr('未填', 'Not filled') : _avatar;
  }

  Widget _avatarPreview() {
    const size = 80.0;
    if (_avatarImage == null && isAvatarImage(_avatar) && widget.ref != null) {
      return BotAvatar(state: widget.state, ref: widget.ref!, size: size);
    }
    return LetterAvatar(
      _name.text,
      size: size,
      image: _avatarImage,
      emoji: _avatarImage != null || _avatar.isEmpty || isAvatarImage(_avatar)
          ? null
          : _avatar,
    );
  }

  Future<void> _chooseDesktop(BuildContext anchor) async {
    final state = widget.state;
    final chosen = await showMenuPanel<String>(anchor, [
      for (final desktop in state.desktops)
        MenuPanelItem(
          desktop.id,
          desktop.name,
          selected: desktop.id == _desktop,
        ),
    ]);
    if (chosen == null || chosen == _desktop || !mounted) return;
    setState(() {
      _desktop = chosen;
      _profileSaver = state.botProfileSaver(chosen);
      _needsCreationCheck =
          _profileSaver!.creationUnconfirmed || _profileSaver!.busy;
      _saveError = _needsCreationCheck
          ? state.tr(
              '此电脑上一次创建仍需核对。',
              'Check the previous creation on this desktop.',
            )
          : null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.state.tr('请填写名字', 'Enter a name'))),
      );
      return;
    }
    if (_desktop == null || !widget.state.isOnline(_desktop!)) {
      setState(
        () => _saveError = widget.state.tr(
          '电脑不在线，未发送修改。',
          'Desktop offline. No changes sent.',
        ),
      );
      return;
    }
    if (_profileSaver?.botId == null) {
      _profileSaver = widget.state.botProfileSaver(
        _desktop!,
        bot: widget.ref?.bot,
      );
    }
    final saver = _profileSaver!;
    if (_needsCreationCheck || saver.creationUnconfirmed || saver.busy) {
      setState(() {
        _needsCreationCheck = true;
        _saveError = widget.state.tr(
          '上一次创建仍需核对，未再次提交。',
          'The previous creation needs checking. Nothing was submitted again.',
        );
      });
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      if (!_chatOnly && (saver.saved == null || saver.saved!.chatOnly)) {
        if (!await _confirmComputerTools(context, widget.state) || !mounted) {
          return;
        }
      }
      await saver.save(
        {
          'name': _name.text.trim(),
          'identity': _identity.text.trim(),
          'style': _style.text.trim(),
          'signature': _signature.text.trim(),
          'gender': _gender.text.trim(),
          'avatar': _avatar.trim().isEmpty ? null : _avatar.trim(),
          if (_avatarImage != null)
            'avatarImage': {'data': _avatarImage, 'type': _avatarType},
          'abilities': _abilities.map((ability) => ability.name).toList(),
          'proactive': _proactive.toJson(),
        },
        chatOnly: _chatOnly,
        writesFirst: _writesFirst,
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _saveError = error is BotModeUnconfirmed
              ? widget.state.tr(
                  '电脑未确认所选模式。Bot 已保存，请核对实际模式；再次保存只更新这个 Bot。',
                  'The mode was not confirmed. The bot was saved; check its actual mode. Saving again updates that bot.',
                )
              : saver.creationUnconfirmed
              ? widget.state.tr(
                  '创建结果未确认，请先核对，避免重复创建。',
                  'Creation was not confirmed. Check before creating another bot.',
                )
              : botSaveFailureMessage(error, widget.state.tr),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// An existing bot saves each change at once: no Done button, no page
  /// being popped, and no creation checks. Creation errors are shown on the
  /// page, next to everything the other failures show.
  Future<void> _saveNow() async {
    if (_creating || _saving) return;
    final saver = _profileSaver;
    if (saver == null) return;
    if (_desktop == null || !widget.state.isOnline(_desktop!)) {
      setState(
        () => _saveError = widget.state.tr(
          '电脑不在线，未保存。',
          'Desktop offline. Nothing was saved.',
        ),
      );
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await saver.save(
        {
          'name': _name.text.trim(),
          'identity': _identity.text.trim(),
          'style': _style.text.trim(),
          'signature': _signature.text.trim(),
          'gender': _gender.text.trim(),
          'avatar': _avatar.trim().isEmpty ? null : _avatar.trim(),
          if (_avatarImage != null)
            'avatarImage': {'data': _avatarImage, 'type': _avatarType},
          'abilities': _abilities.map((ability) => ability.name).toList(),
          'proactive': _proactive.toJson(),
        },
        chatOnly: _chatOnly,
        writesFirst: _writesFirst,
      );
    } on BotModeUnconfirmed {
      if (mounted) {
        setState(
          () => _saveError = widget.state.tr(
            '电脑未确认所选模式。Bot 已保存，请核对实际模式；再次保存只更新这个 Bot。',
            'The mode was not confirmed. The bot was saved; check its actual mode. Saving again updates that bot.',
          ),
        );
      }
    } on Object catch (error) {
      // BotWritesFirstUnconfirmed is a UserFacingError, so its own readable
      // words come through botSaveFailureMessage too.
      if (mounted) {
        setState(
          () => _saveError = botSaveFailureMessage(error, widget.state.tr),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _checkCreated() => runUi(context, () async {
    if (_desktop == null || _saving) return;
    if (_profileSaver?.busy ?? false) {
      setState(
        () => _saveError = widget.state.tr(
          '创建请求仍在等待，请稍后核对。',
          'Creation is still in progress. Check again shortly.',
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await widget.state.request(_desktop!, LinkMethods.state);
      if (!mounted) return;
      if (result is! Map || result['bots'] is! List) {
        throw const FormatException('电脑未返回 Bot 列表');
      }
      final bots = LinkState.fromJson(Map<String, Object?>.from(result)).bots;
      final chosen = await showBottomSheetPanel<LinkBot>(
        context,
        title: widget.state.tr(
          '选择本次已创建的 Bot',
          'Select the bot already created',
        ),
        closeLabel: widget.state.tr('关闭', 'Close'),
        builder: (context) => ListView(
          shrinkWrap: true,
          children: [
            for (final bot in bots.where((bot) => !bot.assistant))
              ListTile(
                title: Text(bot.name),
                subtitle: Text(bot.id),
                onTap: () => Navigator.pop(context, bot),
              ),
            if (!bots.any((bot) => !bot.assistant))
              ListTile(
                title: Text(
                  widget.state.tr(
                    '暂未找到，请在电脑端核对；不要重复创建。',
                    'None found. Check on the desktop before creating again.',
                  ),
                ),
              ),
          ],
        ),
      );
      if (chosen == null || !mounted) return;
      _profileSaver!.useExisting(chosen);
      if (_name.text.trim().isEmpty) {
        _name.text = chosen.name;
        _identity.text = chosen.identity;
        _style.text = chosen.style;
        _signature.text = chosen.signature;
        _gender.text = chosen.gender;
        _avatar = chosen.avatar ?? '';
        _abilities = {...chosen.abilities};
        _chatOnly = chosen.chatOnly;
        _writesFirst = chosen.writesFirst;
        _proactive = chosen.proactive;
      }
      setState(() {
        _needsCreationCheck = false;
        _saveError = widget.state.tr(
          '已选择现有 Bot，后续保存只更新它。',
          'Existing bot selected. Further saves update it.',
        );
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  });

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final desktopName = _desktop == null ? null : state.desktopName(_desktop!);
    final hint = state.tr('还没写', 'Not written yet');
    return ListenableBuilder(
      listenable: Listenable.merge([
        _name,
        _identity,
        _style,
        _signature,
        _gender,
      ]),
      // An existing bot saves each change at once, so there is nothing to
      // discard on the way back; a new one must still confirm.
      builder: (context, page) => _creating
          ? DiscardGuard(
              state: state,
              dirty: !_saving && _snapshot() != _opened,
              child: page!,
            )
          : page!,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _creating
                ? state.tr('新 Bot', 'New bot')
                : state.tr('编辑资料', 'Edit profile'),
          ),
          actions: _creating
              ? [
                  doneButton(
                    state,
                    _saving ||
                            _needsCreationCheck ||
                            (_profileSaver?.creationUnconfirmed ?? false)
                        ? null
                        : _save,
                  ),
                ]
              : const [],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Center(
              child: Builder(
                builder: (anchor) => InkWell(
                  key: const ValueKey('bot-avatar'),
                  borderRadius: BorderRadius.circular(
                    80 * MobileSizes.avatarCorner,
                  ),
                  onTap: _saving ? null : () => _chooseAvatar(anchor),
                  child: _avatarPreview(),
                ),
              ),
            ),
            const SizedBox(height: 20),
            GroupCard(
              children: [
                _profileField(_name, state.tr('名字', 'Name')),
                Builder(
                  builder: (anchor) => SettingsRow(
                    state.tr('头像', 'Avatar'),
                    value: _avatarLabel,
                    onTap: _saving ? null : () => _chooseAvatar(anchor),
                  ),
                ),
                Builder(
                  builder: (anchor) => SettingsRow(
                    state.tr('性别', 'Gender'),
                    value: _gender.text.isEmpty
                        ? state.tr('未填', 'Not filled')
                        : _gender.text,
                    onTap: _saving
                        ? null
                        : () async {
                            final value = await _pickGender(
                              anchor,
                              state,
                              _gender.text,
                            );
                            if (value != null && mounted) {
                              setState(() => _gender.text = value);
                              await _saveNow();
                            }
                          },
                  ),
                ),
                _profileField(_signature, state.tr('个性签名', 'Signature')),
                if (_creating)
                  Builder(
                    builder: (anchor) => SettingsRow(
                      state.tr('电脑', 'Desktop'),
                      value: desktopName ?? state.tr('未选择', 'None'),
                      onTap:
                          _saving ||
                              _profileSaver?.botId != null ||
                              state.desktops.length < 2
                          ? null
                          : () => _chooseDesktop(anchor),
                    ),
                  ),
              ],
            ),
            if (_creating)
              GroupCard(
                children: [
                  SwitchListTile(
                    key: const ValueKey('bot-writes-first'),
                    title: Text(state.tr('主动给我发消息', 'Contact me first')),
                    value: _writesFirst,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _writesFirst = value),
                  ),
                ],
              ),
            if (_saveError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _saveError!,
                      style: MobileTheme.hintStyleOf(
                        context,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    if (_profileSaver?.saved case final saved?)
                      Text(
                        '${state.tr('电脑返回的实际模式', 'Mode returned by desktop')}: '
                        '${saved.chatOnly ? state.tr('只聊天', 'Chat only') : state.tr('可操作电脑', 'Computer tools')}',
                        style: MobileTheme.hintStyleOf(context),
                      ),
                    if (_needsCreationCheck ||
                        (_profileSaver?.creationUnconfirmed ?? false))
                      TextButton(
                        onPressed: _saving ? null : _checkCreated,
                        child: Text(
                          state.tr(
                            '刷新并核对已创建的 Bot',
                            'Refresh and check created bots',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (_creating) ...[
              SectionLabel(state.tr('身份设定', 'Identity')),
              _InputCard(
                fieldKey: const ValueKey('身份设定'),
                controller: _identity,
                hint: hint,
                enabled: !_saving,
              ),
              _Note(_identityNote(state)),
              SectionLabel(state.tr('说话风格', 'Conversation style')),
              _InputCard(
                fieldKey: const ValueKey('说话风格'),
                controller: _style,
                hint: hint,
                enabled: !_saving,
              ),
              _Note(_styleNote(state)),
              SectionLabel(state.tr('干活方式', 'How it works')),
              GroupCard(
                children: [
                  _ModeTile(
                    state: state,
                    value: _chatOnly,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _chatOnly = value),
                  ),
                ],
              ),
              _Note(_modeNote(state, _chatOnly)),
              SectionLabel(state.tr('能力', 'Abilities')),
              GroupCard(
                children: [
                  for (final ability in BotAbility.values)
                    _AbilityTile(
                      state: state,
                      ability: ability,
                      value: _abilities.contains(ability),
                      onChanged: _saving
                          ? null
                          : (value) => setState(() {
                              if (value) {
                                _abilities.add(ability);
                              } else {
                                _abilities.remove(ability);
                              }
                            }),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _Note(_limitsNote(state)),
              ),
            ],
            if (_saving)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: ThinProgress(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _profileField(TextEditingController controller, String title) =>
      EditableSettingsRow(
        state: widget.state,
        controller: controller,
        title: title,
        enabled: !_saving,
        onChanged: (_) {
          setState(() {});
          _saveNow();
        },
      );
}

/// The two notes a bot keeps: of the user (MEMORY.md) and of itself
/// (SELF.md). It writes both as it talks; either saved restarts it on
/// what is written.
