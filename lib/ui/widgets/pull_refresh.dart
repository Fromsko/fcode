// Fromsko — GPL-3.0-only.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 列表顶部的下拉刷新，和官方一样：搜索框连同列表跟手下拉，三个灰点露在
/// 上面让出的空隙里，随距离逐个浮现；过了阈值震一下，松手就刷新，刷新中
/// 停在原处、三个点深浅轮转，完成后收起。
class PullRefresh extends StatefulWidget {
  const PullRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.header,
    this.onArmed,
    this.threshold = 80,
    this.maxReveal = 44,
  });

  /// 刷新动作；失败时保留旧内容，由页面自己说明。
  final Future<void> Function() onRefresh;

  /// 可滚动的列表；不满一屏也能拉。
  final Widget child;

  /// 列表上方不滚动的那条（搜索框），下拉时和列表一起往下走。
  final Widget? header;

  /// 拉过阈值、松手就会刷新的那一刻（震动）。
  final VoidCallback? onArmed;
  final double threshold, maxReveal;

  @override
  State<PullRefresh> createState() => _PullRefreshState();
}

class _PullRefreshState extends State<PullRefresh>
    with SingleTickerProviderStateMixin {
  late final _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// 列表越过顶部的距离：列表自己跟手下拉、松手回弹。
  double _pull = 0;

  /// 越过顶部后手指拉了多远：回弹有阻尼，按手指算阈值才跟手感一致。
  double _finger = 0;
  bool _dragging = false, _refreshing = false;

  double get _progress => (_finger / widget.threshold).clamp(0.0, 1.0);

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification case ScrollUpdateNotification(:final metrics)) {
      final pull = math.max(0.0, -metrics.pixels);
      if (pull != _pull) setState(() => _pull = pull);
    }
    if (_refreshing) return false;
    switch (notification) {
      case ScrollStartNotification(:final dragDetails):
        _dragging = dragDetails != null;
        _finger = 0;
      case ScrollUpdateNotification(:final metrics, :final dragDetails?):
        final before = _finger;
        _finger = metrics.pixels < 0
            ? math.max(0.0, _finger + dragDetails.delta.dy)
            : 0;
        if (before < widget.threshold && _finger >= widget.threshold) {
          widget.onArmed?.call();
        }
      default:
    }
    return false;
  }

  /// 手指抬起就判断：回弹接着动，等它的通知就晚了。
  void _release() {
    if (!_dragging || _refreshing) return;
    _dragging = false;
    if (_finger >= widget.threshold) unawaited(_refresh());
    _finger = 0;
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    _wave.repeat();
    try {
      await widget.onRefresh();
    } on Object {
      // 失败保留旧内容。
    } finally {
      _wave.stop();
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    // 刷新中把内容留在灰点下面，完成后收起。
    tween: Tween(end: _refreshing ? widget.maxReveal : 0),
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOut,
    builder: (context, hold, list) => Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: hold + _pull,
          child: AnimatedBuilder(animation: _wave, builder: _dots),
        ),
        Padding(
          padding: EdgeInsets.only(top: hold),
          child: Column(
            children: [
              if (widget.header case final header?)
                // 列表的越界是它自己画的，搜索框挪同样的距离才贴着它走。
                Transform.translate(offset: Offset(0, _pull), child: header),
              Expanded(child: list!),
            ],
          ),
        ),
      ],
    ),
    child: Listener(
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        // 安卓默认的夹紧滚动拉不动列表：统一用带阻尼的回弹，跟手也有惯性。
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            overscroll: false,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
          ),
          child: widget.child,
        ),
      ),
    ),
  );

  Widget _dots(BuildContext context, Widget? _) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      key: const ValueKey('pull-refresh-dots'),
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 6,
      children: [
        for (var i = 0; i < 3; i++)
          Opacity(
            opacity: _refreshing ? _turning(i) : .7 * _appearing(i),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: const SizedBox.square(dimension: 7),
            ),
          ),
      ],
    );
  }

  /// 下拉时第 [index] 个点：拉得越远越深，前一个先出来。
  double _appearing(int index) =>
      ((_progress - index * .3) / .4).clamp(0.0, 1.0);

  /// 刷新中第 [index] 个点：深浅从左往右轮转，大小不变。
  double _turning(int index) =>
      .2 + .6 * (.5 + .5 * math.cos(2 * math.pi * (_wave.value - index / 3)));
}
