// Fromsko — GPL-3.0-only.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../widgets/lucide_icon.dart';
import 'chat_composer_action.dart';
import 'composer_banners.dart' show Tr;
import 'task_stop_button.dart';

/// 输入框的底：白底、一圈细边、圆角。三种输入栏共用。
BoxDecoration chatComposerDecoration(BuildContext context) => BoxDecoration(
  color: Theme.of(context).colorScheme.surfaceContainerLowest,
  border: Border.all(
    color: Theme.of(context).colorScheme.onSurfaceVariant
        .withValues(alpha: .18),
  ),
  borderRadius: BorderRadius.circular(22),
);

/// 加号面板里的一格。
class ChatAddTile {
  const ChatAddTile({
    required this.id,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// 测试用的格子名；也是 `chat-action-$id` 的后半段。
  final String id;
  final String icon;
  final String label;
  final VoidCallback? onTap;
}

/// 加号面板：一行四列，和键盘一样高，格子少也不压扁。
class ChatAddPanel extends StatelessWidget {
  const ChatAddPanel({super.key, required this.tiles, required this.height});

  final List<ChatAddTile> tiles;

  /// 由 [ChatAddPanelHost.addPanelHeight] 在 Scaffold 外量好：Scaffold 里
  /// 已经看不到键盘占了多少。
  final double height;

  static const _tileSize = 60.0;
  static const _columns = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    return Container(
      key: const ValueKey('chat-actions'),
      // 铺满整行：放进居中的 Column 里也不会缩成内容宽，
      // 灰底和上边线一直顶到两边。
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: .5),
        ),
      ),
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 12.0, side = 16.0;
          // 四列等宽，取整免得舍入误差把第四格挤到下一行。
          final width =
              ((constraints.maxWidth - side * 2 - gap * (_columns - 1)) /
                      _columns)
                  .floorToDouble();
          // 格子尽量大，放大字号时也不超出一列。
          final tile = math.min(media.textScaler.scale(_tileSize), width);
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(side, 16, side, 8),
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final entry in tiles)
                  SizedBox(
                    key: ValueKey('chat-action-${entry.id}'),
                    width: width,
                    child: Tooltip(
                      message: entry.label,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: entry.onTap,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: tile,
                                height: tile,
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerLowest,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Center(
                                  child: LucideIcon(
                                    entry.icon,
                                    size: tile * .44,
                                    color: entry.onTap == null
                                        ? scheme.onSurface.withValues(
                                            alpha: .38,
                                          )
                                        : scheme.onSurface,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                entry.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: MobileType.secondary,
                                  color: entry.onTap == null
                                      ? scheme.onSurface.withValues(alpha: .38)
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 加号面板和键盘轮流占输入框下面：面板让给键盘时先垫着它的高度，键盘升上来
/// 再放掉，输入框不跳。
mixin ChatAddPanelHost<T extends StatefulWidget> on State<T> {
  bool addOpen = false;
  double? _seenKeyboard;
  double _reserve = 0;
  Timer? _reserveTimer;

  /// 输入框的焦点；面板打开时让出，收起时拿回。
  FocusNode get addFocus;

  double get _panelHeight =>
      math.min(_seenKeyboard ?? 280, MediaQuery.sizeOf(context).height * .5);

  /// 面板和键盘一样高，格子少也不压扁；键盘还没收完时只占它让出的高度，
  /// 两者合起来不高过键盘原高，输入框不跳。
  double get addPanelHeight =>
      math.max(0, _panelHeight - MediaQuery.viewInsetsOf(context).bottom);

  /// 每次 build 调一下，输入框有焦点时记下键盘高度。
  void noteKeyboard(BuildContext context) {
    if (!addFocus.hasFocus) return;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset > math.max(_seenKeyboard ?? 0, 100)) _seenKeyboard = inset;
  }

  void closeAdd() {
    if (addOpen) setState(() => addOpen = false);
  }

  void addToKeyboard() {
    if (!addOpen) return;
    setState(() {
      addOpen = false;
      _reserve = _panelHeight;
    });
    _reserveTimer?.cancel();
    _reserveTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _reserve = 0);
    });
  }

  void toggleAdd() {
    if (addOpen) {
      addToKeyboard();
      addFocus.requestFocus();
    } else {
      addFocus.unfocus();
      _reserveTimer?.cancel();
      setState(() {
        addOpen = true;
        _reserve = 0;
      });
    }
  }

  /// 面板收起、键盘还没升满时垫的空白。
  Widget get addReserve => _reserve <= 0
      ? const SizedBox.shrink()
      : SizedBox(
          height: math.max(
            0,
            _reserve - MediaQuery.viewInsetsOf(context).bottom,
          ),
        );

  @override
  void dispose() {
    _reserveTimer?.cancel();
    super.dispose();
  }
}

/// 一行输入：加号在左，文字在中间，发送（或停止）在右。
class ChatInputBar extends StatelessWidget {
  const ChatInputBar({
    super.key,
    required this.tr,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.canSend,
    required this.busy,
    required this.onSend,
    this.enabled = true,
    this.onAdd,
    this.onFieldTap,
    this.stop,
    this.stopBusy = false,
    this.inputFormatters,
    this.fieldKey,
    this.contextMenuBuilder,
  });

  final Tr tr;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final bool enabled;
  final bool canSend;
  final bool busy;
  final VoidCallback onSend;

  /// 点加号；null 时按钮变淡，点不动。
  final VoidCallback? onAdd;
  final VoidCallback? onFieldTap;

  /// 给了就显示停止，不显示发送。
  final VoidCallback? stop;
  final bool stopBusy;
  final List<TextInputFormatter>? inputFormatters;
  final Key? fieldKey;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey('composer-input-surface'),
      decoration: chatComposerDecoration(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: IconButton(
              color: scheme.onSurfaceVariant,
              tooltip: tr('添加附件', 'Add attachment'),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              constraints: BoxConstraints.tight(const Size.square(44)),
              onPressed: onAdd,
              icon: const LucideIcon('plus', size: 22),
            ),
          ),
          Expanded(
            child: TextField(
              key: fieldKey,
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              minLines: 1,
              maxLines: 5,
              style: Theme.of(context).textTheme.bodyMedium,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: inputFormatters,
              contextMenuBuilder: contextMenuBuilder,
              onTap: onFieldTap,
              decoration: InputDecoration(
                filled: false,
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(4, 10, 8, 10),
                hintText: hint,
              ),
            ),
          ),
          // 发送键收在输入框里，四周留出一圈，不贴边框。
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            child: SizedBox.square(
              dimension: 36,
              child: stop != null
                  ? StopActionButton(
                      busy: stopBusy,
                      size: 36,
                      iconSize: 22,
                      tooltip: stopBusy
                          ? tr('正在停止…', 'Stopping…')
                          : tr('停止生成', 'Stop generation'),
                      onPressed: stop,
                    )
                  : ChatComposerAction(
                      busy: busy,
                      enabled: canSend,
                      tooltip: tr('发送', 'Send'),
                      onSend: onSend,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
