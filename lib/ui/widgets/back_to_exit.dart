import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import 'top_hint.dart';

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
    _hint = showTopHint(
      context,
      state.tr('再按一次退出', 'Press back again to exit'),
      duration: window,
    );
    _armed = Timer(window, () {});
  }

  void dispose() {
    _armed?.cancel();
    _armed = null;
    hideTopHint(_hint);
    _hint = null;
  }
}
