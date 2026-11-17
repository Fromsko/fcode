import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../files/files_tab.dart';
import '../widgets/mobile_widgets.dart';
import '../widgets/press_menu.dart';
import 'chats_tab.dart';

/// 对话首页、文件页与侧边栏共用的项目长按菜单，和电脑端项目菜单同序。
class ProjectActionRow extends StatefulWidget {
  const ProjectActionRow({
    super.key,
    required this.state,
    required this.project,
    required this.child,
    this.onNew,
  });
  final AppState state;
  final ProjectRef project;
  final Widget child;

  /// 「新对话」怎么开；不给就像首页一样推一页新对话。
  final Future<void> Function()? onNew;

  @override
  State<ProjectActionRow> createState() => _ProjectActionRowState();
}

class _ProjectActionRowState extends State<ProjectActionRow> {
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

  Future<void> _hide() async {
    final state = widget.state;
    final ref = widget.project;
    final confirmed = await confirmAction(
      context,
      state,
      state.tr('从列表移除项目？', 'Remove project from the list?'),
      state.tr(
        '将“${ref.project.name}”从电脑和手机的项目列表移除，不删除文件或对话。',
        'Remove “${ref.project.name}” from the desktop and phone lists without deleting files or conversations.',
      ),
      action: state.tr('移除', 'Remove'),
    );
    if (!confirmed || !mounted || !state.isOnline(ref.desktopId)) return;
    await state.request(ref.desktopId, LinkMethods.hideProject, {
      'project': ref.project.id,
    });
  }

  /// 像电脑端「全部归档」：该项目列着的对话逐个归档。
  Future<void> _archiveAll() async {
    final state = widget.state;
    final ref = widget.project;
    final sessions = [
      for (final session in state.sessions)
        if (session.desktopId == ref.desktopId &&
            session.session.project == ref.project.id)
          session.session.id,
    ];
    if (sessions.isEmpty) return;
    final confirmed = await confirmAction(
      context,
      state,
      state.tr('全部归档？', 'Archive all?'),
      state.tr(
        '归档“${ref.project.name}”的 ${sessions.length} 段对话。',
        'Archive ${sessions.length} conversations of “${ref.project.name}”.',
      ),
      action: state.tr('归档', 'Archive'),
    );
    if (!confirmed || !mounted) return;
    for (final id in sessions) {
      await state.request(ref.desktopId, LinkMethods.archive, {'session': id});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final ref = widget.project;
    final pinned = ref.project.pinned;
    final online = state.isOnline(ref.desktopId);
    final copyPath = PressMenuItem(
      state.tr('复制路径', 'Copy path'),
      () => _run(() => copyWithNote(context, state, ref.project.path)),
    );
    // 复制路径不用电脑，离线也在。
    return PressMenuRow(
      enabled: !_busy,
      items: online
          ? [
              PressMenuItem(
                state.tr('新对话', 'New conversation'),
                () => _run(
                  widget.onNew ??
                      () => newConversation(context, state, project: ref),
                ),
              ),
              PressMenuItem(
                state.tr('浏览文件', 'Browse files'),
                () => openPage<void>(
                  context,
                  FilesPage(state: state, project: ref),
                ),
              ),
              if (pinned != null)
                PressMenuItem(
                  pinned ? state.tr('取消置顶', 'Unpin') : state.tr('置顶', 'Pin'),
                  () => _run(
                    () async => state.request(
                      ref.desktopId,
                      LinkMethods.pinProject,
                      {'project': ref.project.id, 'pinned': !pinned},
                    ),
                  ),
                ),
              copyPath,
              PressMenuItem(
                state.tr('全部归档', 'Archive all'),
                () => _run(_archiveAll),
              ),
              PressMenuItem(
                state.tr('从列表移除', 'Remove from list'),
                () => _run(_hide),
              ),
            ]
          : [copyPath],
      child: widget.child,
    );
  }
}
