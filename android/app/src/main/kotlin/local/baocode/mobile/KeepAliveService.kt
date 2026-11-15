package local.baocode.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.util.Log

/** 通知要显示的一行摘要；由 Dart 按所有电脑算好。 */
data class KeepAliveNotice(
    val title: String,
    val body: String,
    val stopLabel: String,
    val shortText: String? = null,
    val desktopId: String? = null,
    val sessionId: String? = null,
)

/**
 * 只负责前台通知与系统可见性。引擎、Dart 与连接都在 [BackgroundHost]，这里不持有任何一个。
 * 类型是 remoteMessaging（手机与电脑之间的消息同步）；不自启、不粘性重启。
 * 通知是跨所有电脑的状态摘要，内容变了由 BackgroundHost 用 [postNotice] 重发同一条。
 */
class KeepAliveService : Service() {
    // 这个实例服务的那次启动；onDestroy 只结束自己的启动，不误伤随后发起的新一次。
    private var token = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Dart 可能睡着：把「用户自己关的」记下来，启动时才不会又拉起来。
            recordUserStopped(this)
            BackgroundHost.serviceEnded(token, userStopped = true)
            stopSelf()
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE)
        val body = intent?.getStringExtra(EXTRA_BODY)
        val stopLabel = intent?.getStringExtra(EXTRA_STOP_LABEL)
        val requested = intent?.getLongExtra(EXTRA_TOKEN, 0L) ?: 0L
        if (title == null || body == null || stopLabel == null || requested == 0L) {
            // startForegroundService 之后必须先进前台再停，否则系统会让应用崩溃。
            try {
                startForeground(NOTIFICATION_ID, buildNotification(
                    this, KeepAliveNotice("YCode", "", "Stop")))
                stopForeground(STOP_FOREGROUND_REMOVE)
            } catch (error: RuntimeException) {
                Log.w(TAG, "foreground start rejected", error)
            }
            stopSelf()
            return START_NOT_STICKY
        }
        token = requested
        val notice = KeepAliveNotice(
            title, body, stopLabel,
            intent.getStringExtra(EXTRA_SHORT_TEXT),
            intent.getStringExtra(EXTRA_DESKTOP_ID),
            intent.getStringExtra(EXTRA_SESSION_ID))
        try {
            val notification = buildNotification(this, notice)
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: RuntimeException) {
            Log.w(TAG, "foreground start rejected", error)
            BackgroundHost.serviceFailed(requested)
            stopSelf()
            return START_NOT_STICKY
        }
        // 已被取消、超时或被新的启动取代的迟到启动：通知已显示过，立即撤掉并停止，不空跑。
        if (!BackgroundHost.serviceForeground(requested)) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    // Android 15+ 超时回调；remoteMessaging 没有时限，仅作防御。
    override fun onTimeout(startId: Int, fgsType: Int) {
        BackgroundHost.serviceEnded(token)
        stopSelf()
    }

    override fun onDestroy() {
        BackgroundHost.serviceEnded(token)
        super.onDestroy()
    }

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"
        const val EXTRA_STOP_LABEL = "stopLabel"
        const val EXTRA_SHORT_TEXT = "shortText"
        const val EXTRA_DESKTOP_ID = "desktopId"
        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_TOKEN = "token"
        private const val ACTION_STOP = "local.baocode.mobile.action.STOP_KEEP_ALIVE"
        private const val ACTION_OPEN = "local.baocode.mobile.action.OPEN_NOTIFICATION"
        private const val CHANNEL = "baocode.mobile.background"
        private const val CHANNEL_NAME = "YCode"
        private const val NOTIFICATION_ID = 47130
        private const val TAG = "KeepAliveService"

        /** 用户按的停止，Dart 读一次就清掉。 */
        private const val PREFS = "baocode_background"
        private const val KEY_USER_STOPPED = "userStopped"

        fun recordUserStopped(context: Context) {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_USER_STOPPED, true).apply()
        }

        /** Dart 启动时读一次并清掉：用户停止过就别再按设置拉起。 */
        fun takeUserStopped(context: Context): Boolean {
            val prefs = context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(KEY_USER_STOPPED, false)) return false
            prefs.edit().remove(KEY_USER_STOPPED).apply()
            return true
        }

        /** 服务在跑时换一条摘要：同一个通知 id 重发，不另开通知。 */
        fun postNotice(context: Context, notice: KeepAliveNotice): Boolean {
            if (!BackgroundHost.running) return false
            return try {
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                manager.notify(NOTIFICATION_ID, buildNotification(context, notice))
                true
            } catch (error: RuntimeException) {
                Log.w(TAG, "notification update rejected", error)
                false
            }
        }

        private fun buildNotification(context: Context, notice: KeepAliveNotice): Notification {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(NotificationChannel(
                    CHANNEL, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW))
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            builder.setSmallIcon(R.drawable.ic_stat_ycode)
                .setContentTitle(notice.title)
                .setContentText(notice.body)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
            // Android 16 起可请求提升为常驻胶囊通知；更老的系统忽略这些设置。
            if (Build.VERSION.SDK_INT >= 36) promoted(builder, notice.shortText)
            val stop = PendingIntent.getService(context, 0,
                Intent(context, KeepAliveService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(Notification.Action.Builder(
                Icon.createWithResource(context, android.R.drawable.ic_menu_close_clear_cancel),
                notice.stopLabel, stop).build())
            builder.setContentIntent(contentIntent(context, notice))
            return builder.build()
        }

        /** 点通知直接开那段对话：带上电脑和会话，界面层据此推到对话页。 */
        private fun contentIntent(context: Context, notice: KeepAliveNotice): PendingIntent {
            val launch = Intent(context, MainActivity::class.java)
                .setAction(ACTION_OPEN)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_DESKTOP_ID, notice.desktopId)
                .putExtra(EXTRA_SESSION_ID, notice.sessionId)
            // 目标不同就用不同的 requestCode，旧 extras 不会混进新目标。
            val code = "${notice.desktopId}/${notice.sessionId}".hashCode() and 0x7fffffff
            return PendingIntent.getActivity(context, code, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        /**
         * Android 16 的提升常驻通知。compileSdk 36 的 android.jar 还没有这个方法
         * （36.1 才加），所以用反射；调不到就还是普通常驻通知。短状态字 36 上可直接设。
         */
        private fun promoted(builder: Notification.Builder, shortText: String?) {
            if (!shortText.isNullOrBlank()) builder.setShortCriticalText(shortText)
            try {
                Notification.Builder::class.java
                    .getMethod("setRequestPromotedOngoing", java.lang.Boolean.TYPE)
                    .invoke(builder, true)
            } catch (_: Exception) {
                Log.d(TAG, "promoted ongoing is not available on this build")
            }
        }
    }
}
