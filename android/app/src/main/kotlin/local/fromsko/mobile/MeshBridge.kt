package local.fromsko.mobile

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.easytier.sdk.EtClient
import com.easytier.sdk.EtConfig
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * EasyTier 组网桥（Flutter ↔ et-aar）。
 *
 * 设计要点（照 flomo 的 MeshController 思路，但不照抄代码）：
 * - 状态机 IDLE/STARTING/RUNNING/ERROR，用 EventChannel 主动推，不用 Flutter 轮询；
 * - 每 5 秒拉一次 peers/routes/stats，解析成结构化 JSON 推给 Dart；
 * - 连通性探测用真 TCP 建连（EtClient.probeTcp），不看 ICE 状态瞎猜；
 * - 记流量基线，算出每个节点的本次会话收发增量。
 *
 * 通道：
 *   MethodChannel local.fromsko.mobile/mesh   — start/stop/refresh/probe/config
 *   EventChannel  local.fromsko.mobile/mesh_state — 状态与节点快照推送
 */
internal class MeshBridge(
    context: Context,
    private val main: Handler,
    private val methods: MethodChannel,
    private val events: EventChannel,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, AutoCloseable {

    private val appContext = context.applicationContext
    private val poller = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "mesh-poll").apply { isDaemon = true }
    }
    private var sink: EventChannel.EventSink? = null
    private var polling = false
    private var startAtMs = 0L
    private var timeoutReported = false
    private var closed = false

    /** 本机在 mesh 里的 IP：以启动时配置的 ipv4 为准（路由表首条不一定是自己）。 */
    @Volatile private var selfIpFromConfig = ""

    /** 每个节点上一次采到的累计收发字节，用来算增量。key = 虚拟 IP。 */
    private data class BytePair(var rx: Long, var tx: Long)
    private val lastPeerBytes = mutableMapOf<String, BytePair>()

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        EtClient.get().setListener { state, message ->
            post { emitStatus(state.name, message) }
        }
    }

    // ── EventChannel ──

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
        refreshNow()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ── MethodChannel ──

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(buildSnapshot())
            "refresh" -> { refreshNow(); result.success(null) }
            "start" -> result.success(start(call))
            "stop" -> { EtClient.get().stop(appContext); stopPolling(); emitStatus("IDLE", "已停止"); result.success(null) }
            "prepareVpn" -> result.success(prepareVpn())
            "probe" -> {
                val host = call.argument<String>("host") ?: return result.error("bad_args", "host required", null)
                val port = call.argument<Int>("port") ?: 0
                val timeout = call.argument<Int>("timeoutMs") ?: 2000
                poller.execute { result.success(EtClient.get().probeTcp(host, port, timeout)) }
            }
            "httpGet" -> {
                val host = call.argument<String>("host") ?: return result.error("bad_args", "host required", null)
                val port = call.argument<Int>("port") ?: 80
                val path = call.argument<String>("path") ?: "/"
                val timeout = call.argument<Int>("timeoutMs") ?: 3000
                poller.execute { result.success(EtClient.get().httpGet(host, port, path, timeout)) }
            }
            else -> result.notImplemented()
        }
    }

    /** 申请 VPN 授权：返回 true 表示已有授权，false 表示已拉起系统确认框。 */
    private fun prepareVpn(): Boolean {
        val intent = VpnService.prepare(appContext)
        if (intent == null) return true
        // 宿主 Activity 不在本类手里，只能交给 MainActivity 转；用静态钩子。
        MeshVpnPermission.request(intent)
        return false
    }

    private fun start(call: MethodCall): String? {
        val netName = call.argument<String>("networkName") ?: return "networkName 不能为空"
        val secret = call.argument<String>("secret") ?: return "secret 不能为空"
        val ipv4 = call.argument<String>("ipv4") ?: return "ipv4 不能为空"
        val hostname = call.argument<String>("hostname") ?: ""
        val peers: List<String> = call.argument<List<String>>("peers") ?: emptyList()

        val cfg = EtConfig(netName, secret, ipv4)
        // 留空时 EasyTier 会回退到系统主机名，而 Android 上是 "localhost"，
        // 结果网内所有没填名字的手机都叫同一个名字。这里兜底成可辨识的名字。
        cfg.hostname(hostname.ifBlank { defaultHostname() })
        peers.filter { it.isNotBlank() }.forEach { cfg.addPeer(it) }
        cfg.flag("accept_dns", "false")

        startAtMs = System.currentTimeMillis()
        timeoutReported = false
        lastPeerBytes.clear()
        selfIpFromConfig = ipv4.substringBefore('/')

        val err = runCatching { EtClient.get().start(appContext, cfg) }.getOrElse { it.message ?: "启动异常" }
        if (err == null) {
            emitStatus("STARTING", "正在启动 EasyTier…")
            startPolling()
        } else {
            emitStatus("ERROR", err)
        }
        return err
    }

    // ── 轮询 ──

    private fun startPolling() {
        if (polling) return
        polling = true
        poller.scheduleWithFixedDelay({
            if (closed || !polling) return@scheduleWithFixedDelay
            runCatching {
                val engine = runCatching { EtClient.get().state.name }.getOrDefault("IDLE")
                if (engine == "STARTING" && !timeoutReported && startAtMs > 0 &&
                    System.currentTimeMillis() - startAtMs > 15_000) {
                    timeoutReported = true
                    emitStatus("ERROR", "启动超时（15s 未进入 RUNNING）：检查是否已有其它 VPN、ROM 是否禁用 VPN")
                }
                if (engine == "RUNNING") emitSnapshot(engine)
                else post {
                    val msg = if (engine == "ERROR") (EtClient.get().lastError ?: "") else ""
                    emitStatus(engine, msg)
                }
            }.onFailure { Log.w(TAG, "poll fail: ${it.message}") }
        }, 0, 5, java.util.concurrent.TimeUnit.SECONDS)
    }

    private fun stopPolling() {
        polling = false
    }

    private fun refreshNow() {
        poller.execute {
            runCatching { emitSnapshot(runCatching { EtClient.get().state.name }.getOrDefault("IDLE")) }
        }
    }

    // ── 快照 ──

    private fun emitSnapshot(engine: String) {
        post {
            val s = sink ?: return@post
            s.success(buildSnapshot(engine))
        }
    }

    private fun emitStatus(engine: String, message: String) {
        val s = sink ?: return
        s.success(mapOf("engine" to engine, "message" to message))
    }

    internal fun buildSnapshot(engine: String = runCatching { EtClient.get().state.name }.getOrDefault("IDLE")): Map<String, Any?> {
        val c = EtClient.get()
        val rawPeers = runCatching { c.peers() }.getOrDefault("{}")
        val routes = parseRoutes(runCatching { c.routes() }.getOrDefault("{}"))
        val stats = parseStats(runCatching { c.stats() }.getOrDefault("{}"))
        // list_peer 只给 peer_id；IP / hostname / 延迟 / cost 都在 list_route 里。
        // 两边按 peerId 合并，才是「谁、什么 IP、快不快、直连还是中继」的完整画像。
        val peers = mergePeers(parsePeers(rawPeers), parseRoutes(runCatching { c.routes() }.getOrDefault("{}")))
        // 本机 IP：优先用启动配置里填的那个；没有才退回路由表。
        val self = selfIpFromConfig.ifBlank {
            routes.firstOrNull()?.get("virtualIp") as? String ?: ""
        }
        return mapOf(
            "engine" to engine,
            // lastError 是 SDK 里跨会话留存的旧值，只有真在 ERROR 状态才让它露出来，
            // 否则断开之后状态卡会一直挂着上次的报错。
            "message" to if (engine == "ERROR") (c.lastError ?: "") else "",
            "self" to self,
            "peers" to peers,
            "routes" to routes,
            "stats" to stats,
            "samples" to sampleTraffic(peers),
        )
    }

    /** 把 routes 的 IP/hostname/延迟/cost 合并进 peers（按 peerId 对齐）。 */
    private fun mergePeers(
        peers: List<Map<String, Any?>>,
        routes: List<Map<String, Any?>>,
    ): List<Map<String, Any?>> {
        if (peers.isEmpty()) return routes.map { r ->
            mapOf(
                "name" to (r["hostname"] ?: ""),
                "virtualIp" to (r["virtualIp"] ?: ""),
                "url" to "",
                "latencyMs" to (r["latencyMs"] ?: -1.0),
                "direct" to (r["direct"] ?: false),
                "cost" to (r["cost"] ?: -1L),
                "rxBytes" to 0L, "txBytes" to 0L,
            )
        }
        // list_peer 外层是 PeerInfo，peer_id 在 JSON 里是数字；routes 的 peer_id 也是数字。
        // 两边都统一成字符串 key 再对齐。
        val byId = routes.associateBy { "${it["peerId"]}" }
        return peers.map { p ->
            val r = byId["${p["peerId"]}"]
            val host = (r?.get("hostname") as? String)?.ifBlank { null }
            // 延迟以连接实测的 RTT 为准；路由的 path_latency 只是路径估计，仅作兜底。
            val connLat = (p["latencyMs"] as? Double) ?: -1.0
            val routeLat = (r?.get("latencyMs") as? Double) ?: -1.0
            p + mapOf(
                "virtualIp" to (r?.get("virtualIp") ?: p["virtualIp"] ?: ""),
                "name" to (host ?: p["name"] ?: ""),
                "latencyMs" to (if (connLat > 0) connLat
                    else if (routeLat > 0) routeLat else -1.0),
                "cost" to (r?.get("cost") ?: p["cost"] ?: -1L),
                "direct" to (r?.get("direct") ?: p["direct"] ?: false),
            )
        }
    }

    /**
     * 流量记录：EtClient 的 peers() 里带 rx_bytes/tx_bytes 累计值。
     * 这里算「本次会话增量」= 当前累计 - 上次记录，并在每次采样时更新基线。
     * 采样只保留最近一次的结果，交给 Dart 侧累积成历史。
     */
    private fun sampleTraffic(peers: List<Map<String, Any?>>): List<Map<String, Any?>> =
        peers.mapNotNull { p ->
            val ip = p["virtualIp"] as? String ?: return@mapNotNull null
            val rx = (p["rxBytes"] as? Number)?.toLong() ?: 0L
            val tx = (p["txBytes"] as? Number)?.toLong() ?: 0L
            val prev = lastPeerBytes[ip]
            val dRx = if (prev == null) 0L else (rx - prev.rx).coerceAtLeast(0)
            val dTx = if (prev == null) 0L else (tx - prev.tx).coerceAtLeast(0)
            lastPeerBytes[ip] = BytePair(rx, tx)
            mapOf("virtualIp" to ip, "name" to (p["name"] ?: ""), "rxDelta" to dRx, "txDelta" to dTx)
        }

    // ── JSON 解析（宽容：字段缺失不崩） ──

    private fun asArray(raw: String): List<JSONObject> = runCatching {
        val t = raw.trim()
        when {
            t.startsWith("[") -> (0 until JSONArray(t).length()).map { JSONArray(t).getJSONObject(it) }
            t.startsWith("{") -> {
                val o = JSONObject(t)
                val arrKey = o.keys().asSequence().firstOrNull { k -> o.opt(k) is JSONArray }
                if (arrKey != null) (0 until o.getJSONArray(arrKey).length())
                    .map { o.getJSONArray(arrKey).getJSONObject(it) }
                else emptyList()
            }
            else -> emptyList()
        }
    }.getOrDefault(emptyList())

    private fun JSONObject.str(vararg keys: String): String =
        keys.firstNotNullOfOrNull { k -> if (has(k)) optString(k) else null } ?: ""

    private fun JSONObject.num(vararg keys: String): Long =
        keys.firstNotNullOfOrNull { k -> if (has(k)) optDouble(k, -1.0).toLong() else null } ?: -1L

    private fun JSONObject.dbl(vararg keys: String): Double =
        keys.firstNotNullOfOrNull { k -> if (has(k)) optDouble(k, -1.0) else null } ?: -1.0

    private fun parsePeers(raw: String): List<Map<String, Any?>> = asArray(raw).map { o ->
        val url = o.str("url", "peer_url", "addr", "endpoint")
        val ip = o.str("vpn_ip", "virtual_ip", "ip")
        val connType = o.str("conn_type", "type", "mode")
        val latency = o.dbl("latency_ms", "latency", "delay_ms", "rtt")
        // 统计在 conns[] 里；取第一条有数据的连接。
        var rx = 0L; var tx = 0L
        var connLatencyUs = -1.0
        runCatching {
            val conns = o.optJSONArray("conns")
            if (conns != null) for (i in 0 until conns.length()) {
                val c = conns.getJSONObject(i)
                val st = c.optJSONObject("stats")
                if (st != null) {
                    rx += st.optString("rx_bytes", "0").toLongOrNull() ?: 0L
                    tx += st.optString("tx_bytes", "0").toLongOrNull() ?: 0L
                    val us = st.optString("latency_us", "0").toLongOrNull() ?: 0L
                    if (us > 0 && (connLatencyUs < 0 || us < connLatencyUs)) {
                        connLatencyUs = us.toDouble()
                    }
                }
            }
        }
        mapOf(
            "peerId" to o.str("peer_id"),
            "name" to o.str("hostname", "name").ifBlank { url.ifBlank { ip } },
            "virtualIp" to ip,
            "url" to url,
            "latencyMs" to (if (connLatencyUs > 0) connLatencyUs / 1000.0
                else if (latency > 0) latency else -1.0),
            "direct" to (connType.contains("direct", true) ||
                (connType.isBlank() && o.num("cost") <= 1)),
            "cost" to o.num("cost"),
            "rxBytes" to rx,
            "txBytes" to tx,
        )
    }

    /**
     * Route 的真实形态（实测）：
     *   "ipv4_addr":{"address":{"addr":3368601800},"network_length":24}
     * addr 是 u32 整数，按大端字节序转点分十进制。
     */
    private fun u32ToIpv4(n: Long): String =
        "${(n shr 24) and 255}.${(n shr 16) and 255}.${(n shr 8) and 255}.${n and 255}"

    private fun parseRoutes(raw: String): List<Map<String, Any?>> = asArray(raw).map { o ->
        val ip = runCatching {
            when (val a = o.opt("ipv4_addr")) {
                is String -> a.substringBefore('/')
                is JSONObject -> {
                    val addrObj = a.optJSONObject("address")
                    val rawAddr = addrObj?.opt("addr") ?: a.opt("addr")
                    when (rawAddr) {
                        is Number -> u32ToIpv4(rawAddr.toLong())
                        is String -> rawAddr.toLongOrNull()?.let { u32ToIpv4(it) } ?: rawAddr
                        else -> ""
                    }
                }
                else -> ""
            }
        }.getOrDefault("")
        // path_latency 单位是微秒（实测 10201 → 10.2ms）。
        val latencyUs = o.num("path_latency")
        mapOf(
            "peerId" to o.str("peer_id"),
            "virtualIp" to ip,
            "hostname" to o.str("hostname", "name"),
            "version" to o.str("version"),
            "cost" to o.num("cost"),
            "latencyMs" to if (latencyUs > 0) latencyUs / 1000.0 else -1.0,
            "direct" to (o.num("cost") <= 1),
            "proxyCidrs" to (o.optJSONArray("proxy_cidrs")?.let { arr ->
                (0 until arr.length()).map { arr.optString(it) }
            } ?: emptyList<String>()),
        )
    }

    private fun parseStats(raw: String): Map<String, Any?> = runCatching {
        val o = JSONObject(raw)
        mapOf(
            "rxBytes" to o.num("rx_bytes", "rx", "recv_bytes"),
            "txBytes" to o.num("tx_bytes", "tx", "send_bytes"),
            "peerCount" to o.num("peer_count", "peers"),
            "raw" to raw,
        )
    }.getOrDefault(mapOf("rxBytes" to 0L, "txBytes" to 0L, "peerCount" to 0, "raw" to raw))

    // ── 工具 ──

    private fun post(block: () -> Unit) = main.post(block)

    override fun close() {
        closed = true
        polling = false
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        poller.shutdownNow()
    }

    companion object {
        private const val TAG = "FromskoMesh"

        /**
         * 没填主机名时给一个能认出来的默认值。
         *
         * 用型号而不是系统 hostname：后者在 Android 上恒为 "localhost"，
         * 同网多台手机就全撞名了。带一段设备 id 的尾号，同型号的多台也能区分。
         */
        private fun defaultHostname(): String {
            val model = Build.MODEL?.trim().orEmpty()
                .replace(Regex("[^A-Za-z0-9._-]"), "-")
                .ifBlank { "android" }
            val tail = Build.FINGERPRINT.hashCode().toUInt().toString(16).takeLast(4)
            return "$model-$tail"
        }
    }
}

/** VPN 授权转交：MainActivity 注册后由桥层触发系统确认框。 */
internal object MeshVpnPermission {
    private var launcher: ((Intent) -> Unit)? = null

    fun register(l: (Intent) -> Unit) { launcher = l }
    fun request(intent: Intent) { launcher?.invoke(intent) }
}
