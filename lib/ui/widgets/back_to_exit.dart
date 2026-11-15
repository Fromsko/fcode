import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import '../../theme/app_theme.dart';

/// 返回到了头：第一次只提示，[window] 内再按一次才退出应用。
class BackToExit {
  BackToExit(this.state, {this.window = const Duration(seconds: 2)});
  final AppState state;
  final Duration window;

  Timer? _armed;
  OverlayEntry? _hint;

  bool get armed => _armed?.isActive ?? false;

  void press(BuildContext context) {
    if (armed) {
      dispose();
      unawaited(SystemNavigator.pop());
      return;
    }
    _hideHint();
    // 提示放在最上层的 Overlay：侧边栏开着时 SnackBar 会被它盖住。
    final text = state.tr('再按一次退出', 'Press back again to exit');
    final hint = _hint = OverlayEntry(builder: (_) => _ExitHint(text));
    Overlay.of(context, rootOverlay: true).insert(hint);
    _armed = Timer(window, _hideHint);
  }

  void _hideHint() {
    _hint?.remove();
    _hint = null;
  }

  void dispose() {
    _armed?.cancel();
    _armed = null;
    _hideHint();
  }
}

class _ExitHint extends StatelessWidget {
  const _ExitHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 72),
            child: Center(
              child: Material(
                key: const ValueKey('back-to-exit-hint'),
                color: scheme.inverseSurface,
                shape: const StadiumBorder(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MobileSpace.lg,
                    vertical: MobileSpace.sm,
                  ),
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: MobileType.secondary,
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
