import 'dart:async';

import 'package:bao_link/bao_link.dart';

import 'conversation_filters.dart';
import 'project_actions.dart';
import 'session_press_row.dart';

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../../chat/widgets/pixel_loader.dart';
import '../../link/chat_codec.dart';
import '../../link/phone_link.dart' show DesktopLinkStatus;
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../tasks/chat_page.dart';
import '../bots/bots_tab.dart';
import '../devices/device_menu.dart';
import '../devices/devices_page.dart';
import '../files/files_tab.dart';
import '../widgets/dropdown_panel.dart';
import '../widgets/lucide_icon.dart';
import '../widgets/mobile_widgets.dart';
import '../widgets/model_icon.dart';
import '../widgets/project_icon_view.dart';
import '../widgets/pull_refresh.dart';
import '../widgets/top_hint.dart';
import '../widgets/formats.dart';

/// A new conversation, as the desktop's own starts one: in the project
/// used last on that desktop unless [project] is given, the page open at
/// once; the project can be changed there until the first message.
Future<void> newConversation(
  BuildContext context,
  AppState state, {
  ProjectRef? project,
  String? desktopId,
}) async {
  project ??= recentProject(state, desktopId ?? state.selectedDesktopId);
  if (project == null) {
    showTopHint(
      context,
      state.tr(
        '先在电脑中打开项目并连接。',
        'Connect a desktop with an open project first.',
      ),
    );
    return;
  }
  await _openDraft(context, state, project);
}

/// The project of the desktop's latest conversation, else its first: of
/// those online.
ProjectRef? recentProject(AppState state, String? desktopId) {
  final projects = [
    for (final ref in state.projects)
      if ((desktopId == null || ref.desktopId == desktopId) &&
          state.isOnline(ref.desktopId))
        ref,
  ];
  if (projects.isEmpty) return null;
  final sessions = [
    for (final ref in state.sessions)
      if (projects.any(
        (p) =>
            p.desktopId == ref.desktopId && p.project.id == ref.session.project,
      ))
        ref,
  ]..sort((a, b) => b.session.updatedAt.compareTo(a.session.updatedAt));
  if (sessions.firstOrNull case final latest?) {
    return projects.firstWhere(
      (p) =>
          p.desktopId == latest.desktopId &&
          p.project.id == latest.session.project,
    );
  }
  return projects.first;
}

/// Asks the desktop for a draft in [project] and opens it, in the place of
/// the page asking when [replace].
Future<void> _openDraft(
  BuildContext context,
  AppState state,
  ProjectRef project, {
  bool replace = false,
}) async {
  final id = await draftWithCover(context, state, project);
  if (id == null || !context.mounted) return;
  final page = ChatPage(
    state: state,
    desktopId: project.desktopId,
    sessionId: id,
    title: state.tr('新对话', 'New conversation'),
    projectId: project.project.id,
    onSwitchProject: (pageContext) async {
      final next = await pickProject(pageContext, state, current: project);
      if (next == null ||
          (next.desktopId == project.desktopId &&
              next.project.id == project.project.id) ||
          !pageContext.mounted) {
        return;
      }
      await _openDraft(pageContext, state, next, replace: true);
    },
  );
  final route = MaterialPageRoute<void>(builder: (_) => page);
  if (replace) {
    await Navigator.of(context).pushReplacement(route);
  } else {
    await Navigator.of(context).push(route);
  }
}

bool _drafting = false;

/// [requestDraft] with the screen covered while the desktop answers: taps
/// wait, and a loader shows if it takes a moment. Null when it failed (said
/// already) or another is being made.
Future<String?> draftWithCover(
  BuildContext context,
  AppState state,
  ProjectRef project,
) async {
  if (_drafting) return null;
  _drafting = true;
  final cover = OverlayEntry(builder: (_) => const _DraftCover());
  Overlay.of(context, rootOverlay: true).insert(cover);
  try {
    return await runUi(context, () => requestDraft(state, project));
  } finally {
    cover.remove();
    _drafting = false;
  }
}

class _DraftCover extends StatefulWidget {
  const _DraftCover();

  @override
  State<_DraftCover> createState() => _DraftCoverState();
}

class _DraftCoverState extends State<_DraftCover> {
  bool _slow = false;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    // 电脑很快回话时不闪一下加载。
    _timer = Timer(
      const Duration(milliseconds: 250),
      () => setState(() => _slow = true),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    key: const ValueKey('draft-cover'),
    children: [
      const ModalBarrier(dismissible: false),
      if (_slow) const Center(child: PixelLoader.agent(size: 32)),
    ],
  );
}

/// A draft conversation in [project], as the desktop starts one: its id.
Future<String> requestDraft(AppState state, ProjectRef project) async {
  final result = objectMap(
    await state.request(project.desktopId, LinkMethods.draft, {
      'project': project.project.id,
    }),
  );
  final id = result['session'];
  if (id is! String) {
    throw const FormatException('The desktop did not return a session');
  }
  return id;
}

/// The projects of [current]'s desktop to start a conversation in, beside
/// [anchor]: each with its folder and branch, [current] ticked.
Future<ProjectRef?> pickProject(
  BuildContext anchor,
  AppState state, {
  required ProjectRef current,
}) => showDropdownPanel<ProjectRef>(
  anchor,
  width: 640,
  builder: (context) {
    final theme = Theme.of(context);
    final choices = [
      for (final ref in state.projects)
        if (ref.desktopId == current.desktopId) ref,
    ];
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(MobileSpace.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final ref in choices)
              Builder(
                builder: (context) {
                  final selected = ref.project.id == current.project.id;
                  final branch = ref.project.branch;
                  return Material(
                    color: selected
                        ? theme.colorScheme.surfaceContainerHighest
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(MobileSizes.radius),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      key: ValueKey('pick-project-${ref.project.id}'),
                      enabled: state.isOnline(ref.desktopId),
                      leading: const LucideIcon('folder', size: 22),
                      title: Text(
                        ref.project.name,
                        style: selected
                            ? const TextStyle(fontWeight: FontWeight.w600)
                            : null,
                      ),
                      subtitle: Text(
                        [
                          ref.project.path,
                          if (branch != null && branch.isNotEmpty) branch,
                        ].join(' · '),
                      ),
                      trailing: selected
                          ? LucideIcon(
                              'check',
                              size: 20,
                              color: theme.colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.pop(context, ref),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  },
);

class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key, required this.state});
  final AppState state;
  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  ConversationFilters _filters = const ConversationFilters();
  final _search = TextEditingController();

  /// Projects unfolded in place, their conversations listed under them.
  final _unfolded = <(String, String)>{};
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 下拉刷新：在线就在这条连接上重取电脑状态，离线就立刻重拨。
  Future<void> _refresh(AppState state, String? desktopId) async {
    if (desktopId == null) return;
    if (!state.desktops.any((desktop) => desktop.id == desktopId)) return;
    await state.refreshDesktop(desktopId);
  }

  void _clearFilters() => setState(() {
    _filters = const ConversationFilters();
    _search.clear();
  });

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final desktopId = state.selectedDesktopId;
    final desktopProjects = state.projects.where(
      (ref) => ref.desktopId == desktopId,
    );
    // 和电脑侧边栏一样：置顶的对话在最上面，不再算在各自的项目里。
    final pinned = _filters.pinned(
      desktopProjects,
      state.sessions,
      state.desktopName,
    );
    final projects = _filters.projects(
      desktopProjects,
      state.sessions,
      state.desktopName,
    );
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: DesktopSwitcherTitle(state: state, onChanged: _clearFilters),
        actions: [
          Builder(
            builder: (anchor) => IconButton(
              tooltip: state.tr('新建', 'Create'),
              icon: const LucideIcon('circle-plus', size: 24),
              onPressed: () async {
                MenuPanelItem<String> item(
                  String value,
                  String icon,
                  String title,
                ) => MenuPanelItem(
                  value,
                  title,
                  key: ValueKey('create-$value'),
                  leading: LucideIcon(icon, size: 22),
                );
                final value = await showMenuPanel<String>(anchor, [
                  item(
                    'conversation',
                    'square-pen',
                    state.tr('新对话', 'New conversation'),
                  ),
                  item('bot', 'user-plus', state.tr('添加 Bot', 'Add bot')),
                ], width: 200);
                if (!context.mounted) return;
                switch (value) {
                  case 'conversation':
                    await newConversation(context, state, desktopId: desktopId);
                  case 'bot':
                    await openPage<void>(context, BotEditPage(state: state));
                }
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_filters.searching)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      state.tr('搜索结果', 'Search results'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _clearFilters,
                    child: Text(state.tr('清除', 'Clear')),
                  ),
                ],
              ),
            ),
          Expanded(
            child: state.desktops.isEmpty
                ? EmptyPanel(
                    state.tr(
                      '连接电脑，继续你的对话。',
                      'Connect a desktop to continue your conversations.',
                    ),
                    actionLabel: state.tr('配对新电脑', 'Pair a desktop'),
                    onAction: () =>
                        openPage<void>(context, PairDevicePage(state: state)),
                  )
                : PullRefresh(
                    header: SearchCapsule(
                      state: state,
                      controller: _search,
                      onChanged: (value) => setState(
                        () => _filters = ConversationFilters(query: value),
                      ),
                    ),
                    onArmed: state.haptic,
                    onRefresh: () => _refresh(state, desktopId),
                    child: ListView(
                      children: [
                        for (final ref in pinned)
                          projectSessionRow(context, state, ref, onTop: true),
                        for (final item in projects) _projectRow(state, item),
                        if (projects.isEmpty && pinned.isEmpty)
                          _emptyNote(state, desktopId),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _projectRow(AppState state, ConversationProject item) {
    final ref = item.ref;
    final sessions = item.sessions;
    SessionRef? newest(Iterable<SessionRef> list) => list.isEmpty
        ? null
        : list.reduce(
            (a, b) => a.session.updatedAt.isAfter(b.session.updatedAt) ? a : b,
          );
    final latest = newest(sessions);
    final focus =
        newest(
          sessions.where(
            (ref) =>
                state.isOnline(ref.desktopId) &&
                ref.session.status != LinkSessionStatus.idle,
          ),
        ) ??
        latest;
    final key = (ref.desktopId, ref.project.id);
    final unfolded = _unfolded.contains(key);
    void toggle() =>
        setState(() => unfolded ? _unfolded.remove(key) : _unfolded.add(key));
    final listRow = ListRow(
      leading: waitingAvatar(
        state,
        ProjectIconView(state: state, ref: ref),
        sessions,
      ),
      title:
          '${ref.project.name}${sessions.isEmpty ? '' : '（${sessions.length}）'}',
      flags: statusFlags(context, state, sessions),
      subtitle: [
        if (projectSource(ref.project.id) == ConversationSource.unknown)
          state.tr('未知来源', 'Unknown location'),
        focus == null
            ? state.tr('没有对话', 'No conversations')
            : '${focus.session.title}${switch (lastLine(state, focus)) {
                null => '',
                final line => '：$line',
              }}',
      ].join(' · '),
      time: latest == null ? null : _time(latest.session.updatedAt),
      // 图钉和展开箭头都在时间下面，不另占一列，标题不被挤窄。
      status: ref.project.pinned == true || sessions.isNotEmpty
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 和对话、Bot 一样标出置顶的项目。
                if (ref.project.pinned == true)
                  const LucideIcon('pin', size: 16),
                if (sessions.isNotEmpty) ...[
                  if (ref.project.pinned == true) const SizedBox(width: 10),
                  AnimatedRotation(
                    turns: unfolded ? .5 : 0,
                    duration: _unfoldDuration,
                    curve: _unfoldCurve,
                    child: const LucideIcon('chevron-down', size: 16),
                  ),
                ],
              ],
            )
          : null,
      onTap: () => openPage<void>(
        context,
        ProjectChatsPage(state: state, project: ref, filters: _filters),
      ),
    );
    final row = ProjectActionRow(
      key: ValueKey('project-${ref.desktopId}-${ref.project.id}'),
      state: state,
      project: ref,
      child: sessions.isEmpty
          ? listRow
          : Stack(
              children: [
                listRow,
                // 箭头只有 16px：右下角一整块都算点箭头，只展开不进项目。
                Positioned(
                  right: 0,
                  bottom: 0,
                  width: 72,
                  height: 44,
                  // 不用 Tooltip：它会抢走长按，这里长按仍是项目菜单。
                  child: Semantics(
                    button: true,
                    label: unfolded
                        ? state.tr('收起对话', 'Hide conversations')
                        : state.tr('展开对话', 'Show conversations'),
                    child: GestureDetector(
                      key: ValueKey(
                        'unfold-${ref.desktopId}-${ref.project.id}',
                      ),
                      behavior: HitTestBehavior.opaque,
                      onTap: toggle,
                    ),
                  ),
                ),
              ],
            ),
    );
    if (sessions.isEmpty) return row;
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: ValueKey('project-group-${ref.desktopId}-${ref.project.id}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        ClipRect(
          child: AnimatedSize(
            duration: _unfoldDuration,
            curve: _unfoldCurve,
            alignment: Alignment.topCenter,
            child: !unfolded
                ? const SizedBox(width: double.infinity)
                : ColoredBox(
                    color: colors.surfaceContainerLowest,
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: _unfoldIndent),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final session in sessions)
                                projectSessionRow(context, state, session),
                            ],
                          ),
                        ),
                        // 竖线对着项目头像的中线：这些对话属于上面那个项目。
                        Positioned(
                          left: MobileSpace.lg + MobileSizes.avatar / 2,
                          top: 0,
                          bottom: MobileSpace.md,
                          width: 1,
                          child: ColoredBox(color: colors.outlineVariant),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  static const _unfoldDuration = Duration(milliseconds: 200);
  static const _unfoldCurve = Curves.easeOutCubic;
  static const _unfoldIndent = 28.0;

  /// Why the list is empty: still connecting, offline, a search, or no
  /// project open on that desktop.
  Widget _emptyNote(AppState state, String? desktopId) {
    final name = desktopId == null ? '' : state.desktopName(desktopId);
    final status = desktopId == null ? null : state.linkStatus(desktopId);
    final (text, retry) = switch (status) {
      _ when _filters.searching => (
        state.tr('没有匹配的项目或会话', 'No matching projects or conversations'),
        false,
      ),
      DesktopLinkStatus.connecting => (
        state.tr('正在连接 $name…', 'Connecting to $name…'),
        false,
      ),
      DesktopLinkStatus.offline => (
        '$name ${linkStatusLabel(state, DesktopLinkStatus.offline)}',
        true,
      ),
      DesktopLinkStatus.needsPairing => (
        '$name ${linkStatusLabel(state, DesktopLinkStatus.needsPairing)}',
        false,
      ),
      _ => (state.tr('电脑上还没有打开的项目', 'No projects open on this desktop'), false),
    };
    return Padding(
      padding: const EdgeInsets.all(MobileSpace.xl),
      child: Column(
        children: [
          if (status == DesktopLinkStatus.connecting) ...[
            ConnectingSpinner(
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: MobileSpace.md),
          ],
          Text(
            text,
            textAlign: TextAlign.center,
            // 需重新配对是唯一要动手的，红；其余是说明，灰。
            style: TextStyle(
              color: status == DesktopLinkStatus.needsPairing
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).hintColor,
            ),
          ),
          if (retry && desktopId != null)
            TextButton(
              onPressed: () => state.retryConnection(desktopId),
              child: Text(state.tr('重试', 'Retry')),
            ),
        ],
      ),
    );
  }

  String _time(DateTime date) => sessionTime(widget.state, date);
}

class ProjectChatsPage extends StatelessWidget {
  const ProjectChatsPage({
    super.key,
    required this.state,
    required this.project,
    this.filters = const ConversationFilters(),
  });
  final AppState state;
  final ProjectRef project;
  final ConversationFilters filters;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      final sessions = filters.sessions(
        state.sessions.where(
          (s) =>
              s.desktopId == project.desktopId &&
              s.session.project == project.project.id,
        ),
        state.desktopName,
        projectName: project.project.name,
      );
      return Scaffold(
        appBar: AppBar(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                project.project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // What the rows show is only last known until it reconnects.
              if (!state.isOnline(project.desktopId))
                Text(
                  devicePathText(state, project.desktopId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: state.isOnline(project.desktopId)
                  ? state.tr('项目文件', 'Project files')
                  : state.tr(
                      '电脑已断开，无法查看项目文件',
                      'Desktop offline; project files unavailable',
                    ),
              icon: const LucideIcon('folder', size: 22),
              onPressed: state.isOnline(project.desktopId)
                  ? () => openPage<void>(
                      context,
                      FilesPage(state: state, project: project),
                    )
                  : null,
            ),
            IconButton(
              tooltip: state.tr('新对话', 'New conversation'),
              icon: const LucideIcon('square-pen', size: 22),
              onPressed: () =>
                  newConversation(context, state, project: project),
            ),
          ],
        ),
        body: Column(
          children: [
            if (filters.searching)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  state.tr('搜索结果', 'Search results'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            Expanded(
              child: sessions.isEmpty
                  ? EmptyPanel(
                      state.tr('还没有对话', 'No conversations yet'),
                      actionLabel: state.tr('新对话', 'New conversation'),
                      onAction: () =>
                          newConversation(context, state, project: project),
                    )
                  : PullRefresh(
                      onArmed: state.haptic,
                      onRefresh: () => state.refreshDesktop(project.desktopId),
                      child: ListView.builder(
                        itemCount: sessions.length,
                        itemBuilder: (context, index) =>
                            projectSessionRow(context, state, sessions[index]),
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );
}

/// A conversation in a project's list: in the project's page and under a
/// project unfolded on the home list. [onTop], a pinned one above the
/// projects: its project named before its last line.
Widget projectSessionRow(
  BuildContext context,
  AppState state,
  SessionRef ref, {
  bool onTop = false,
}) {
  return SessionPressRow(
    key: ValueKey(
      '${onTop ? 'pinned' : 'session'}-${ref.desktopId}-${ref.session.id}',
    ),
    state: state,
    session: ref,
    child: ListRow(
      leading: waitingAvatar(state, LetterAvatar(ref.session.title), [ref]),
      title: ref.session.title,
      aside: modelTag(context, state, ref),
      flags: statusFlags(context, state, [ref], counted: false),
      subtitle: onTop
          ? [projectNameOf(state, ref), ?lastLine(state, ref)].join(' · ')
          : lastLine(state, ref),
      time: sessionTime(state, ref.session.updatedAt),
      status: ref.session.pinned ? const LucideIcon('pin', size: 16) : null,
      onTap: () => openPage<void>(
        context,
        ChatPage(
          state: state,
          desktopId: ref.desktopId,
          sessionId: ref.session.id,
          title: ref.session.title,
          projectId: ref.session.project,
        ),
      ),
    ),
  );
}

/// [avatar] with how many of [sessions] wait on the user (needing an answer,
/// or done and not looked at) on its corner, as chat apps mark a chat:
/// counted as the 对话 tab counts them, so the list's marks add up to it.
Widget waitingAvatar(
  AppState state,
  Widget avatar,
  Iterable<SessionRef> sessions,
) {
  final counts = state.countByStatus(sessions);
  final waiting = counts.needsInput + counts.done;
  return Badge(
    isLabelVisible: waiting > 0,
    label: Text('$waiting'),
    offset: const Offset(6, -6),
    child: avatar,
  );
}

/// The name of [ref]'s project, its id until the project list knows it.
String projectNameOf(AppState state, SessionRef ref) =>
    state.projects
        .where(
          (p) =>
              p.desktopId == ref.desktopId &&
              p.project.id == ref.session.project,
        )
        .firstOrNull
        ?.project
        .name ??
    ref.session.project;

String sessionTime(AppState state, DateTime date, [DateTime? now]) {
  now ??= DateTime.now();
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(date.year, date.month, date.day)).inDays;
  if (days <= 0) {
    return formatClock(date);
  }
  if (days == 1) return state.tr('昨天', 'Yesterday');
  if (days < 7) {
    const zh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const en = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return state.tr(zh[date.weekday - 1], en[date.weekday - 1]);
  }
  return formatDay(state, date, now: now);
}

/// 「2 个运行中 · 1 个待处理」 for a project, 「运行中」 for one conversation:
/// the same words wherever a status shows. Nothing while the desktop is not
/// connected, what it last said being stale; its title says so instead.
List<(String, Color)> statusFlags(
  BuildContext context,
  AppState state,
  Iterable<SessionRef> sessions, {
  bool counted = true,
}) {
  final colors = Theme.of(context).colorScheme;
  // 电脑离线时它最后说的状态已经过时：那时不标，标题上写着离线。
  final (running: running, needsInput: waiting, done: done) = state
      .countByStatus(sessions.where((ref) => state.isOnline(ref.desktopId)));
  return [
    if (running > 0)
      (
        counted
            ? state.tr('$running 个运行中', '$running running')
            : state.tr('运行中', 'Running'),
        // Under way is indigo whatever the accent, apart from green (done).
        MobileTheme.statusColorsOf(context).info,
      ),
    if (waiting > 0)
      (
        counted
            ? state.tr('$waiting 个待处理', '$waiting need input')
            : state.tr('待处理', 'Needs input'),
        colors.error,
      ),
    if (done > 0)
      (
        counted
            ? state.tr('$done 个已完成', '$done done')
            : state.tr('已完成', 'Done'),
        MobileTheme.statusColorsOf(context).success,
      ),
  ];
}

/// The last thing the agent said in a conversation, from the cached buffer;
/// null when it was never opened here. Never subscribes.
String? lastLine(AppState state, SessionRef ref) {
  final buffer = state.peekBuffer(ref.desktopId, ref.session.id);
  for (final raw in buffer?.items.reversed ?? const <Map<String, Object?>>[]) {
    final item = ChatCodec.decode(raw);
    if (item is AssistantTextItem) {
      final text = oneLineExcerpt(item.text, max: 80);
      return text.isEmpty ? null : text;
    }
  }
  return null;
}

/// The model a conversation runs on, left of its time: its maker's logo and
/// name, as [AppState.sessionModel] knows it. Never subscribes.
Widget? modelTag(BuildContext context, AppState state, SessionRef ref) {
  final model = state.sessionModel(ref);
  if (model == null) return null;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ModelIcon.ofId(
        model.id,
        provider: model.provider,
        providerLabel: model.providerLabel,
        size: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 3),
      // 字号、颜色和截断跟着那一行的 [ListRow.aside]。
      Flexible(child: Text(modelShortName(model.id, model.label))),
    ],
  );
}
