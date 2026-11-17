import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../widgets/mobile_widgets.dart';
import '../widgets/press_menu.dart';
import 'delete_conversation.dart';

/// 首页置顶对话、项目内对话与侧边栏对话共用的长按菜单。
class SessionPressRow extends StatefulWidget {
  const SessionPressRow({
    super.key,
    required this.state,
    required this.session,
    required this.child,
  });
  final AppState state;
  final SessionRef session;
  final Widget child;

  @override
  State<SessionPressRow> createState() => _SessionPressRowState();
}

class _SessionPressRowState extends State<SessionPressRow> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runUi(context, action);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final ref = widget.session;
    final session = ref.session;
    final online = state.isOnline(ref.desktopId);
    // 和电脑端对话菜单同序；复制会话 ID 不用电脑，离线也在。
    return PressMenuRow(
      enabled: !_busy,
      items: [
        if (online) ...[
          PressMenuItem(
            state.tr('重命名', 'Rename'),
            () => _run(() async {
              final title = await askText(
                context,
                state,
                state.tr('重命名', 'Rename'),
                value: session.title,
              );
              if (title == null || title.isEmpty) return;
              await state.request(ref.desktopId, LinkMethods.rename, {
                'session': session.id,
                'title': title,
              });
            }),
          ),
          PressMenuItem(
            session.pinned ? state.tr('取消置顶', 'Unpin') : state.tr('置顶', 'Pin'),
            () => _run(
              () async => state.request(ref.desktopId, LinkMethods.pin, {
                'session': session.id,
                'pinned': !session.pinned,
              }),
            ),
          ),
          PressMenuItem(
            state.tr('归档', 'Archive'),
            () => _run(() async {
              if (!await confirmAction(
                context,
                state,
                state.tr('归档对话？', 'Archive conversation?'),
                session.title,
                action: state.tr('归档', 'Archive'),
              )) {
                return;
              }
              await state.request(ref.desktopId, LinkMethods.archive, {
                'session': session.id,
              });
            }),
          ),
        ],
        PressMenuItem(
          state.tr('复制会话 ID', 'Copy session ID'),
          () => _run(() => copyWithNote(context, state, session.id)),
        ),
        if (online)
          PressMenuItem(
            state.tr('删除该聊天', 'Delete chat'),
            () => _run(
              () => deleteConversation(
                context,
                state,
                desktopId: ref.desktopId,
                sessionId: session.id,
                title: session.title,
              ),
            ),
          ),
      ],
      child: widget.child,
    );
  }
}
