import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../link/chat_codec.dart';
import 'group_page.dart';
import '../../state/bot_settings.dart';
import '../conversations/chats_tab.dart' show sessionTime;
import '../devices/device_menu.dart';
import '../tasks/chat_page.dart';
import '../tasks/model_settings_sheet.dart';
import '../widgets/bottom_sheet_panel.dart';
import '../widgets/dropdown_panel.dart';
import '../widgets/lucide_icon.dart';
import '../widgets/mobile_widgets.dart';
import '../widgets/press_menu.dart';
import '../widgets/pull_refresh.dart';
import '../widgets/top_hint.dart';
import '../../theme/app_theme.dart';
import '../user_message.dart';
import '../widgets/fold_row.dart';

part 'bot_widgets.dart';
part 'bot_profile.dart';
part 'bot_edit.dart';
part 'bot_memory.dart';

class BotsTab extends StatelessWidget {
  const BotsTab({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) {
    final desktopId = state.selectedDesktopId;
    final groups = state.groups
        .where((ref) => ref.desktopId == desktopId)
        .toList();
    final bots = [
      for (final ref in state.bots)
        if (ref.desktopId == desktopId) ref,
    ];
    // 置顶的在前，其次按最近动静，没动静的排在后面保持原有顺序。
    final rows = <(int, DateTime?, Widget)>[
      for (final ref in groups)
        (
          state.groupPinned(ref) ? 0 : 1,
          ref.group.last?.at,
          GroupPressRow(
            key: ValueKey(('group', ref.desktopId, ref.group.id)),
            state: state,
            ref: ref,
            child: ListRow(
              leading: unreadAvatar(
                ref.group.unread,
                GroupAvatar(state: state, ref: ref),
              ),
              title: groupTitle(state, ref),
              subtitle: ref.group.last == null
                  ? null
                  : ref.group.last!.mine || ref.group.last!.notice
                  ? ref.group.last!.text
                  : ChatCodec.botVisibleText(ref.group.last!.text),
              time: switch (ref.group.last?.at) {
                final at? => sessionTime(state, at),
                null => null,
              },
              status: state.groupPinned(ref)
                  ? const LucideIcon('pin', size: 16)
                  : null,
              onTap: () => openPage<void>(
                context,
                GroupChatPage(state: state, ref: ref),
              ),
            ),
          ),
        ),
      for (final ref in bots)
        (
          state.botPinned(ref) ? 0 : 1,
          ref.bot.updatedAt,
          BotPressRow(
            key: ValueKey('bot-${ref.desktopId}-${ref.bot.id}'),
            state: state,
            ref: ref,
            child: ListRow(
              leading: unreadAvatar(
                ref.bot.unread,
                BotAvatar(state: state, ref: ref),
              ),
              title: ref.bot.name,
              note: ref.bot.assistant ? state.tr('助理', 'Assistant') : null,
              subtitle: _botListLine(ref.bot),
              time: switch (ref.bot.updatedAt) {
                final at? => sessionTime(state, at),
                null => null,
              },
              status: state.botPinned(ref)
                  ? const LucideIcon('pin', size: 16)
                  : null,
              onTap: () => openPage<void>(
                context,
                ChatPage(
                  state: state,
                  desktopId: ref.desktopId,
                  sessionId: ref.bot.session ?? 'bot:${ref.bot.id}',
                  title: ref.bot.name,
                  botId: ref.bot.id,
                ),
              ),
            ),
          ),
        ),
    ];
    final order = {for (final (i, row) in rows.indexed) row.$3: i};
    rows.sort((a, b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      final (at, bt) = (a.$2, b.$2);
      if (at != null && bt != null && at != bt) return bt.compareTo(at);
      if ((at == null) != (bt == null)) return at == null ? 1 : -1;
      return order[a.$3]!.compareTo(order[b.$3]!);
    });
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: DesktopSwitcherTitle(state: state),
        actions: [
          Builder(
            builder: (anchor) => IconButton(
              tooltip: state.tr('新建', 'Create'),
              icon: const LucideIcon('plus', size: 22),
              onPressed: () async {
                MenuPanelItem<String> item(
                  String value,
                  String icon,
                  String title,
                ) => MenuPanelItem(
                  value,
                  title,
                  key: ValueKey('bots-create-$value'),
                  leading: LucideIcon(icon, size: 22),
                );
                final value = await showMenuPanel<String>(anchor, [
                  if (desktopId != null)
                    item(
                      'group',
                      'message-circle',
                      state.tr('发起群聊', 'Start group chat'),
                    ),
                  item('bot', 'user-plus', state.tr('添加 Bot', 'Add bot')),
                ], width: 200);
                if (!context.mounted) return;
                switch (value) {
                  case 'group':
                    await startGroupChat(context, state, desktopId!);
                  case 'bot':
                    await openPage<void>(context, BotEditPage(state: state));
                }
              },
            ),
          ),
        ],
      ),
      body: state.desktops.isEmpty
          ? EmptyPanel(
              state.tr(
                '连接电脑后管理你的 Bot。',
                'Connect a desktop to manage your bots.',
              ),
            )
          : PullRefresh(
              onArmed: state.haptic,
              onRefresh: () => desktopId == null
                  ? Future<void>.value()
                  : state.refreshDesktop(desktopId),
              child: ListView(
                children: [
                  if (bots.isEmpty && groups.isEmpty)
                    EmptyPanel(
                      state.tr(
                        '还没有 Bot。定义它是谁、能做什么。',
                        'No bots yet. Define who one is and what it can do.',
                      ),
                      actionLabel: state.tr('添加 Bot', 'Add bot'),
                      onAction: () =>
                          openPage<void>(context, BotEditPage(state: state)),
                    )
                  else
                    for (final row in rows) row.$3,
                ],
              ),
            ),
    );
  }
}

/// 群名或成员名；群里还没有名字时用成员。
String groupTitle(AppState state, GroupRef ref) {
  if (ref.group.name.isNotEmpty) return ref.group.name;
  final names = [
    for (final id in ref.group.members)
      if (state.botOn(ref.desktopId, id) case final member?) member.bot.name,
  ];
  return names.isEmpty ? state.tr('群聊', 'Group chat') : names.join('、');
}
