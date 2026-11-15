import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_licenses.dart';
import 'chat/widgets/pixel_loader.dart';
import 'link/link_store.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'ui/conversations/open_conversation.dart';
import 'ui/home_shell.dart';
import 'ui/widgets/lucide_icon.dart';
import 'ui/widgets/mobile_widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerAppLicenses();
  // The home screen's icons, read while the app starts behind its loader.
  unawaited(
    LucideIcon.precache(const [
      'message-circle',
      'bot',
      'folder',
      'settings',
      'list-filter',
      'circle-plus',
      'search',
      'chevron-down',
      'pin',
      'user-plus',
      'images',
      'camera',
      'at-sign',
    ]).catchError((Object _) {}),
  );
  const demo = bool.fromEnvironment('DEMO');
  runApp(
    MobileApp(
      state: AppState(
        demo: demo,
        store: demo ? MemoryLinkStore() : PlatformLinkStore(),
      ),
    ),
  );
}

class MobileApp extends StatefulWidget {
  const MobileApp({super.key, required this.state});
  final AppState state;
  @override
  State<MobileApp> createState() => _MobileAppState();
}

class _MobileAppState extends State<MobileApp> with WidgetsBindingObserver {
  final _themes = MobileThemeCache();
  final _releaseInput = ReleaseInputOnCover();

  /// 点后台通知时直接开对话：深层页面要由这里推，不靠某个列表页。
  final _navigator = GlobalKey<NavigatorState>();
  late var _inputs = _inputsOf(widget.state);

  /// Whether the app takes the system's back itself, as the routes last said.
  bool? _handlesBack;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_stateChanged);
    // Paired already: the system is asked, once, to let the app notify.
    unawaited(
      widget.state.initialize().then(
        (_) => widget.state.askNotificationsOnce(),
      ),
    );
  }

  /// What the app itself is built from; the rest is the pages' to follow.
  static (bool, String, double, double, ThemeMode, String) _inputsOf(
    AppState state,
  ) => (
    state.ready,
    state.settings.accent,
    state.settings.codeFontSize,
    state.settings.textScale,
    state.settings.themeMode,
    state.settings.language,
  );

  void _stateChanged() {
    final inputs = _inputsOf(widget.state);
    if (inputs != _inputs) setState(() => _inputs = inputs);
    _openPending();
  }

  /// 点通知要开的那段对话：界面在、状态也到了才推页面，否则等下一次回来。
  void _openPending() {
    if (widget.state.peekPendingOpen() == null ||
        _navigator.currentContext == null ||
        !widget.state.ready) {
      return;
    }
    // 下一帧再推，不与正在建的界面抢。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _navigator.currentContext;
      if (context == null || !context.mounted) return;
      final target = widget.state.takePendingOpen();
      if (target == null) return;
      unawaited(
        openConversation(
          context,
          widget.state,
          desktopId: target.desktopId,
          sessionId: target.sessionId,
        ).whenComplete(
          () => widget.state.pendingOpenSettled(
            target.desktopId,
            target.sessionId,
          ),
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.state.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.state.resume());
      _openPending();
    }
    _syncBack();
  }

  // Flutter drops what the routes say while the lifecycle is still unknown,
  // as at a cold start: kept here and told once it is, or back quits the app.
  bool _onNavigation(NavigationNotification notification) {
    _handlesBack = notification.canHandlePop;
    _syncBack();
    return true;
  }

  void _syncBack() {
    final handles = _handlesBack;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (handles == null ||
        lifecycle == null ||
        lifecycle == AppLifecycleState.detached) {
      return;
    }
    unawaited(SystemNavigator.setFrameworkHandlesBack(handles));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_stateChanged);
    widget.state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final themes = _themes.of(
      accent: MobileAccent.parse(state.settings.accent),
      codeFontSize: state.settings.codeFontSize,
      messageScale: state.settings.textScale,
    );
    return MaterialApp(
      title: 'YCode',
      debugShowCheckedModeBanner: false,
      theme: themes.light,
      darkTheme: themes.dark,
      themeMode: state.settings.themeMode,
      locale: state.settings.language == 'system'
          ? null
          : Locale(state.settings.language),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      navigatorKey: _navigator,
      navigatorObservers: [_releaseInput],
      onNavigationNotification: _onNavigation,
      home: state.ready
          ? ListenableBuilder(
              listenable: state,
              builder: (_, _) => HomeShell(state: state),
            )
          : Scaffold(body: Center(child: const PixelLoader.agent(size: 32))),
    );
  }
}
