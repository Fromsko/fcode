package local.baocode.mobile

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 引擎、PlatformBridge 与网络观察者的主线程宿主，生命周期跟引擎走，不跟 Activity 走。
 * 保活开启时引擎放进 FlutterEngineCache，Activity 销毁后保留；重新打开界面复用同一引擎，
 * 不会有第二个 Dart 隔离区或第二条连接，也不会重复注册插件。
 */
object BackgroundHost {
    private const val ENGINE_ID = "local.baocode.mobile.engine"
    private const val CHANNEL = "local.baocode.mobile/background"
    private val main = Handler(Looper.getMainLooper())

    private var engine: FlutterEngine? = null
    private var bridge: PlatformBridge? = null
    private var channel: MethodChannel? = null
    private var network: NetworkWatcher? = null
    private var activity: MainActivity? = null
    private var appContext: Context? = null
    private var visible = false

    private val gate = KeepAliveGate()
    private val pendingResults = mutableListOf<MethodChannel.Result>()
    private val startTimeout = Runnable { fail(gate.token, "start_timeout") }

    /** 通知点开后要去的对话：界面没起来时先记着，attach 后交给 Dart。 */
    private var pendingOpen: Pair<String, String>? = null

    /** 前台服务已确认进入前台（仅主线程读写）。 */
    val running get() = gate.phase == KeepAliveGate.Phase.RUNNING

    /** 启动中或运行中都保留引擎：Activity 此时销毁也不能丢掉 Dart。 */
    val keepsEngine get() = gate.phase != KeepAliveGate.Phase.IDLE

    private fun status(): Map<String, Boolean> =
        mapOf("running" to running, "networkWatching" to (network?.watching == true))

    /** 保活期间始终复用同一引擎；Flutter 的独占 Activity 宿主负责先分离旧界面。 */
    fun reusableEngine(): FlutterEngine? =
        if (keepsEngine) FlutterEngineCache.getInstance().get(ENGINE_ID) else null

    fun attach(host: MainActivity, flutterEngine: FlutterEngine) {
        if (activity !== host) activity?.let { bridge?.detachActivity(it) }
        activity = host
        appContext = host.applicationContext
        if (engine !== flutterEngine) {
            releaseEngineResources()
            engine = flutterEngine
            val messenger = flutterEngine.dartExecutor.binaryMessenger
            bridge = PlatformBridge(host.applicationContext, messenger)
            channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(::onCall) }
            network = NetworkWatcher(host.applicationContext, main) {
                channel?.invokeMethod("networkChanged", null)
            }.also { it.start() }
        }
        bridge?.attach(host)
        deliverPendingOpen()
    }

    /** 通知带着目标点进来（冷启动或 onNewIntent）：界面就绪后交给 Dart。 */
    fun openFromNotification(intent: Intent?) {
        val desktopId = intent?.getStringExtra(KeepAliveService.EXTRA_DESKTOP_ID)
        val sessionId = intent?.getStringExtra(KeepAliveService.EXTRA_SESSION_ID)
        if (desktopId.isNullOrEmpty() || sessionId.isNullOrEmpty()) return
        intent.removeExtra(KeepAliveService.EXTRA_DESKTOP_ID)
        intent.removeExtra(KeepAliveService.EXTRA_SESSION_ID)
        pendingOpen = desktopId to sessionId
        deliverPendingOpen()
    }

    private fun deliverPendingOpen() {
        val target = pendingOpen ?: return
        // 引擎不在、界面不在，或界面刚建好还没进 onStart：都等下一次 attach/可见。
        val channel = channel ?: return
        if (activity == null || !visible) return
        pendingOpen = null
        channel.invokeMethod("openConversation", mapOf(
            "desktopId" to target.first, "sessionId" to target.second))
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) =
        bridge?.onActivityResult(requestCode, resultCode, data) == true

    fun handlePermissionResult(requestCode: Int) =
        bridge?.onRequestPermissionsResult(requestCode) == true

    fun setVisible(host: MainActivity, value: Boolean) {
        if (activity !== host) return
        visible = value
        if (value) deliverPendingOpen()
    }

    /** [destroyEngine] 为 true 时，随后 Flutter 会销毁引擎，这里先清掉依附于它的东西。 */
    fun detach(host: MainActivity, destroyEngine: Boolean) {
        if (activity === host) {
            activity = null
            visible = false
            bridge?.detachActivity(host)
            if (destroyEngine) releaseEngineResources()
        }
    }

    /** Service 已 startForeground 成功。返回 false 表示这次启动已失效，Service 必须自行停止。 */
    fun serviceForeground(token: Long): Boolean {
        if (!gate.confirm(token)) return false
        main.removeCallbacks(startTimeout)
        val waiting = pendingResults.toList()
        pendingResults.clear()
        waiting.forEach { it.success(status()) }
        return true
    }

    /** Service 启动被系统拒绝。 */
    fun serviceFailed(token: Long) = fail(token, "start_failed")

    /**
     * 前台服务结束（用户停止、系统停止、超时、销毁）。幂等；旧令牌的迟到回调被忽略。
     * [userStopped] 区分用户按的停止与系统结束：只有前者该改用户的设置。
     */
    fun serviceEnded(token: Long, userStopped: Boolean = false) = fail(token, "start_cancelled", userStopped)

    private fun fail(token: Long?, code: String, userStopped: Boolean = false) {
        val previous = gate.end(token) ?: return
        main.removeCallbacks(startTimeout)
        val waiting = pendingResults.toList()
        pendingResults.clear()
        waiting.forEach { it.error(code, "The background service did not start", null) }
        if (activity != null) {
            // 引擎仍归当前 Activity 所有，正常前台使用；只是不再保留。
            FlutterEngineCache.getInstance().remove(ENGINE_ID)
            if (previous == KeepAliveGate.Phase.RUNNING) {
                channel?.invokeMethod("statusChanged",
                    status() + mapOf("userStopped" to userStopped))
            }
        } else {
            // Activity 已脱离，没人持有引擎：销毁缓存引擎与 bridge，进程可被回收。
            val orphan = engine
            releaseEngineResources()
            orphan?.destroy()
        }
    }

    private fun releaseEngineResources() {
        network?.stop()
        network = null
        channel?.setMethodCallHandler(null)
        channel = null
        bridge?.close()
        bridge = null
        if (engine != null) FlutterEngineCache.getInstance().remove(ENGINE_ID)
        engine = null
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "stop" -> {
                // 这里是用户自己关的（设置页或通知按钮）；同样记下，Dart 下次启动读到。
                val context = appContext
                if (context != null) KeepAliveService.recordUserStopped(context)
                fail(null, "start_cancelled", userStopped = true)
                context?.let { it.stopService(Intent(it, KeepAliveService::class.java)) }
                result.success(status())
            }
            "status" -> result.success(status())
            "update" -> update(call, result)
            // 通知上按过停止、Dart 当时没醒着：读走这个标记，别再按设置拉起。
            "takeUserStopped" -> {
                val context = appContext
                result.success(context != null && KeepAliveService.takeUserStopped(context))
            }
            else -> result.notImplemented()
        }
    }

    /** 摘要变了：重发同一条服务通知；服务没在跑就当无事发生。 */
    private fun update(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        val title = call.argument<String>("title")
        val body = call.argument<String>("body")
        if (context == null || title.isNullOrBlank() || body.isNullOrBlank()) {
            result.error("bad_arguments", "title and body are required", null)
            return
        }
        val posted = KeepAliveService.postNotice(context, KeepAliveNotice(
            title = title,
            body = body,
            stopLabel = startedStopLabel ?: "Stop",
            shortText = call.argument<String>("shortText"),
            desktopId = call.argument<String>("desktopId"),
            sessionId = call.argument<String>("sessionId"),
        ))
        result.success(posted)
    }

    /** 启动时的停止按钮文字；摘要更新只改标题和正文，不带它。 */
    private var startedStopLabel: String? = null

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (running) {
            result.success(status())
            return
        }
        if (gate.phase == KeepAliveGate.Phase.PENDING) {
            pendingResults.add(result) // 去重：并入同一次启动的结果。
            return
        }
        val host = activity
        val current = engine
        if (host == null || current == null || !visible) {
            result.error("not_visible", "Keep-alive can only be started from the visible app", null)
            return
        }
        val title = call.argument<String>("title")
        val body = call.argument<String>("body")
        val stopLabel = call.argument<String>("stopLabel")
        if (title.isNullOrBlank() || body.isNullOrBlank() || stopLabel.isNullOrBlank()) {
            result.error("bad_arguments", "title, body and stopLabel are required", null)
            return
        }
        // 通知权限没给也能跑，只是通知不显示：冷启动按默认开启不打扰用户，
        // 设置页那边自己先申请权限再调用这里。
        // 监听不可用就明确失败，不在没有切网信号的情况下悄悄保活。
        network?.start()
        if (network?.watching != true) {
            result.error("network_unavailable", "Network changes cannot be observed", null)
            return
        }
        val token = gate.begin()
        if (token == null) {
            result.error("start_failed", "The background service is busy", null)
            return
        }
        val context: Context = host.applicationContext
        startedStopLabel = stopLabel
        val intent = Intent(context, KeepAliveService::class.java)
            .putExtra(KeepAliveService.EXTRA_TITLE, title)
            .putExtra(KeepAliveService.EXTRA_BODY, body)
            .putExtra(KeepAliveService.EXTRA_STOP_LABEL, stopLabel)
            .putExtra(KeepAliveService.EXTRA_SHORT_TEXT, call.argument<String>("shortText"))
            .putExtra(KeepAliveService.EXTRA_DESKTOP_ID, call.argument<String>("desktopId"))
            .putExtra(KeepAliveService.EXTRA_SESSION_ID, call.argument<String>("sessionId"))
            .putExtra(KeepAliveService.EXTRA_TOKEN, token)
        pendingResults.add(result)
        FlutterEngineCache.getInstance().put(ENGINE_ID, current)
        main.postDelayed(startTimeout, START_TIMEOUT_MS)
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
            else context.startService(intent)
        } catch (error: RuntimeException) {
            fail(token, "start_failed")
        }
    }

    private const val START_TIMEOUT_MS = 10_000L
}
