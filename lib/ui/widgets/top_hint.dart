import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

OverlayEntry? _shown;

/// 屏幕底部一条短提示，放在最上层的 Overlay：侧边栏、底部面板、看图器
/// 开着时也看得见，键盘弹出时浮在键盘上面。同一时间只有一条，新的替换旧的。
/// [duration] 后自己消失；返回的条目可以提前用 [hideTopHint] 收起。
OverlayEntry showTopHint(
  BuildContext context,
  String text, {
  Duration duration = const Duration(seconds: 4),
}) {
  hideTopHint(_shown);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) =>
        _TopHint(text, duration: duration, onDone: () => hideTopHint(entry)),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  return _shown = entry;
}

/// 收起 [entry]；已经收起的不再动。
void hideTopHint(OverlayEntry? entry) {
  if (entry == null) return;
  if (identical(entry, _shown)) _shown = null;
  if (entry.mounted) entry.remove();
}

class _TopHint extends StatefulWidget {
  const _TopHint(this.text, {required this.duration, required this.onDone});
  final String text;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<_TopHint> createState() => _TopHintState();
}

// 计时跟着提示走：提示先被收起或页面关掉，计时一起取消。
class _TopHintState extends State<_TopHint> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, widget.onDone);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      bottom: MediaQuery.viewInsetsOf(context).bottom,
      child: IgnorePointer(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              MobileSpace.lg,
              0,
              MobileSpace.lg,
              72,
            ),
            child: Center(
              child: Material(
                key: const ValueKey('top-hint'),
                color: scheme.inverseSurface,
                // 单行看着是胶囊；长提示折成多行时也不变成两头大圆。
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(MobileSizes.button / 2),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MobileSpace.lg,
                    vertical: MobileSpace.sm,
                  ),
                  child: Text(
                    widget.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: MobileType.secondary,
                      height: 1.4,
                      color: scheme.onInverseSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
