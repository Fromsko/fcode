import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../../theme/app_theme.dart';

/// 用户是否在自己滚：手指拖动、惯性滑行中为真，停下为假。
///
/// 只认拖动开始和方向通知：列表因为新内容长出来、或者我们自己的 `jumpTo`
/// 发出的通知都不算。取更早消息和「跟随底部」共用这一份判断。
class UserScrollTracker {
  bool _scrolling = false;

  /// 手指在列表上，或列表还在惯性滑行。
  bool get scrolling => _scrolling;

  /// 喂一个滚动通知，返回此刻是否算用户在滚。
  bool update(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _scrolling = true;
    } else if (notification is UserScrollNotification) {
      _scrolling = notification.direction != ScrollDirection.idle;
    }
    return _scrolling;
  }
}

/// 用户自己滚了 [delta] 之后是否跟随底部：往上翻一点就不跟，往下回到底部
/// 附近再跟；null 是不变。Bot 单聊和群聊共用。
bool? followAfterScroll(ScrollMetrics metrics, double delta) {
  final fromEnd = metrics.maxScrollExtent - metrics.pixels;
  if (delta < 0 && fromEnd > 16) return false;
  if (delta > 0 && fromEnd < 100) return true;
  return null;
}

/// 包住聊天列表：用户自己朝上滚到接近顶部时取一页更早的消息。
///
/// 只认用户的拖动和惯性：列表因为新内容增长、或者我们自己的 `jumpTo` 而
/// 变化时不触发。取不取还由 [canLoad] 当场判断（在线、没在取、还有更早的、
/// 没有待重试的错误）。
class EarlierOnScroll extends StatefulWidget {
  const EarlierOnScroll({
    super.key,
    required this.canLoad,
    required this.onLoad,
    this.onUserScroll,
    this.onScrollDelta,
    required this.child,
  });

  /// 此刻是否还该取。
  final bool Function() canLoad;

  /// 该取时调一次；重复调用由调用方自己去重。
  final VoidCallback onLoad;

  /// 用户是否在自己滚的事实：滚着时每个通知都调，停下的那一刻再调一次
  /// （这时 `scrolling` 为 false）。调用方在这里同步自己的跟随状态，
  /// 不必再套一层监听。
  final void Function(ScrollNotification notification, bool scrolling)?
  onUserScroll;

  /// 用户自己在滚时给出这次位移（负的是往更早的方向）；通知带着尺寸，
  /// 要不要重新跟随底部由调用方看。
  final void Function(ScrollNotification notification, double delta)?
  onScrollDelta;

  final Widget child;

  @override
  State<EarlierOnScroll> createState() => _EarlierOnScrollState();
}

class _EarlierOnScrollState extends State<EarlierOnScroll> {
  final _user = UserScrollTracker();

  /// 上一次通知时用户是否在滚：停下那一刻还要再通知一次。
  bool _reported = false;

  /// 离顶部多近就取：一屏没滚满时也不至于到顶才动。
  static const _threshold = 160.0;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final scrolling = _user.update(notification);
    if (scrolling || _reported) {
      widget.onUserScroll?.call(notification, scrolling);
    }
    _reported = scrolling;
    if (!scrolling) return false;
    final delta = switch (notification) {
      ScrollUpdateNotification(:final scrollDelta) => scrollDelta ?? 0.0,
      OverscrollNotification(:final overscroll) => overscroll,
      _ => 0.0,
    };
    widget.onScrollDelta?.call(notification, delta);
    // 负的位移是往更早的方向翻；离顶够近才取。
    if (delta < 0 &&
        notification.metrics.extentBefore < _threshold &&
        widget.canLoad()) {
      widget.onLoad();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      );
}

/// 取更早消息的状态：浮在列表顶部，出现和消失都不挪动内容。
///
/// 挂载时是 `Stack` 的直接子项（渲染成 [Positioned]），调用方在 `loading`
/// 或 `error` 时条件挂载；不该显示时它只画一个空的 [SizedBox.shrink]。
class EarlierStatusOverlay extends StatelessWidget {
  const EarlierStatusOverlay({
    super.key,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.tr,
  });

  /// 正在取；有 [error] 时先显示错误。
  final bool loading;

  final String? error;

  /// 为空时重试不可点（比如断线、正在取）。
  final VoidCallback? onRetry;

  final String Function(String zh, String en) tr;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    if (error == null && !loading) return const SizedBox.shrink();
    return Positioned(
      top: 8,
      left: 16,
      right: 16,
      child: Center(
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          elevation: 2,
          borderRadius: BorderRadius.circular(MobileSizes.radius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: error == null
                ? Text(tr('加载中…', 'Loading…'))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error),
                      TextButton(
                        onPressed: onRetry,
                        child: Text(tr('重试', 'Retry')),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
