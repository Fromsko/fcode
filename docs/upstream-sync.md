# 官方协议同步与来源

YCode 是独立的非官方 Android 客户端，不是官方手机端的分支。官方手机端不开源；YCode 的界面参考官方 App 的截图自行设计和实现，不包含官方 App 的代码或图片素材。

## 协议

- `vendor/bao_link`、`vendor/bao_iroh` 来自 [BaoCode](https://github.com/baocode-dev/baocode) 官方提交 `4ba7d951`（1.9.4 之后）的 `packages/` 目录，Dart 与 Rust 绑定成对同步。
- 只多一个可选方法 `quota`（额度查询），声明在 `vendor/bao_link/lib/src/protocol.dart`。官方电脑端不支持时，手机端只显示「此电脑不支持额度查询」，不影响聊天、文件和 Bot；超时、断线这类真实错误照常报失败。
- `LinkMethods.bulk` 选择性对齐官方 `b59bb984`：`setMe`、`saveBot` 也各走独立流，最大 1 MiB 的头像不再堵住控制流。电脑端对独立流上的任何请求都照常应答，旧电脑同样适用；代价是回复不再保证排在控制流的 `state` 之后，保存 Bot 一律以回复里的 Bot 为准，列表随后由 `state` 刷新。
- `vendor/bao_link/lib/src/peer.dart` 有本地连接恢复修补：请求写失败及时返回，独立流写失败复位该流，无等待方的控制消息写失败结束连接；独立流超时包含开流等待，迟到的流不再发送请求。回前台的 `state` 探测使用电脑端已支持的独立请求流，避免排在大历史回复之后；`open`、`earlier` 与会话增量仍在控制流保持顺序。256 KiB 及以上的消息在工作 isolate 解析，控制流按原顺序应用结果。不改变 link v2 的消息格式，不自动重发请求；这些不是上述官方提交自带的改动。
- 排队消息由手机端在本地保存和发送，不需要协议扩展。

官方改了 `packages/bao_link`、`packages/bao_iroh` 或 `lib/link/` 时：先比较 `4ba7d951` 和新提交的差异，有选择地同步，保留 `quota`，再更新本文记录的提交；不要直接覆盖整个 `vendor`。

## 选择性功能同步

- Bot 消息语义选择性对齐正式版 `v1.9.6`（`f0912dc8`）的 `lib/link/chat_codec.dart`：标签属性与引用、成功 `bot_send` 的 `sent`（空字符串可表示仅图）、私聊/群回合归属、语气提示与推荐回复。保留手机已有的图片弱缓存，不整体替换编解码文件。
- `vendor/bao_link/lib/src/bots.dart` 仅补 `writesFirst`：缺字段默认开启，仅关闭时序列化 `false`；原 `proactive` 能力和兼容配置保持原样。不是整个 vendor 已升级到 1.9.6；上面的协议来源基线与本地 `quota`、写失败、超时、大消息 isolate 和独立探测修补不变。
- 私聊/群聊共用电脑的原始 Bot 会话。只在手机呈现、复制和图片浏览等消费处过滤，不改 `SessionBuffer` / Mirror 的数组和索引。分页窗口没有前置归属字段：窗口从回合中间开始时，未知前缀保守隐藏，用户可用“加载更早消息”恢复；成功的私聊 `bot_send`（包括仅图）单独显示。此处没有扩展电脑协议。
- 推荐回复是按“电脑 + Bot”隔离的手机本地设置，默认关闭。立即发送与本地排队都在真正发出请求时读取当前开关，只有 Bot 私聊的 `send` 携带 `suggest`；普通智能体不携带。点建议只填现有输入框，保留附件，由用户确认发送。关闭再开启、切换会话、提交新轮次与点选后均不复活旧建议。
- Bot 资料保存仍回传完整可管理字段并核对电脑返回值；未确认不显示成功，不自动重试创建。旧端省略 `writesFirst` 与新端默认开启的 wire 形状相同，无法据此识别版本；请求关闭却未回读 `false` 时明确报告未确认，不误判为网络不支持。
- 群聊选择性对齐 `v1.9.6` 的公开 `groups.dart`、`LinkState.groups`、七个群聊 RPC 和 `group` 事件；群图片使用独立请求流。按电脑与群隔离订阅，消息按 `seq` 排序去重；打开响应之前的事件排队，旧连接和旧请求结果用代际隔离。重开保留已展开的消息数，回前台沿用原来的连接检查与可靠基线复用规则。
- 群设置保存核对整份回读，允许空名称由电脑生成及官方规范化；旧端忽略新设置时报告未确认，但保留已确认身份，防止重复创建。不同次成功的新建操作使用不同身份；删除需要用户确认。不改变 Bot 原始会话 Mirror。
- 消息模型与展示选择性补齐官方 `83c4dc40` 的 `AgentItem.ranBefore`，累计显示此前和本次运行时长。多目录项目由电脑返回带目录前缀的路径，仍使用现有 `files/folder/read` 和文件引用接口，不另造 RPC。
- 以官方 `112bfa65`（`v2.0.0` 之后）为核对快照，补齐电脑早已发送、手机此前未解码的用户消息字段：`stopped`（`b79433ef`）让被停止的回合也折叠，没有回答时停止原因留在折叠外，折叠行写「处理 X 后停止」；`agent`（`a73fadce`，`fromAgent`）让子智能体经 SendMessage 发来的消息显示成它的卡片，不当成用户气泡，不能编辑，不计入「我发的消息」跳转、模型切换标记和本地排队的收下判断，Bot 聊天里归入工作过程。编辑定位与 `worked`、`usage` 一样忽略回合结束才写回的 `stopped`。
- 子智能体卡片显示所用模型（`db59ebbc`），按电脑的规则命名：先在电脑发来的模型菜单里找 `@上游/模型id`，用菜单里的名字（如「GPT-6.1-sol」），只有一个上游有该模型时记下上游名；找不到时 Claude 模型写成「Haiku 5.5」，其余原样显示。电脑悬停才看到的上游和完整 id，手机写在子智能体详情页的模型一栏里。

## 主线新增手机能力

- 以官方 `83c4dc40` 为核对快照，选择性接入 `bb61280b` 的 `upload` 与 `51d61103` 的 `have` 续传；两项都晚于正式 `v1.9.6`。应用版本字符串不足以判断是否支持这些功能，旧电脑明确返回 `unknown/unsupported` 才判为不支持，超时与断线不混作能力判断。
- 上传使用现有 Android 平台通道的系统文件选择器，后台按原始字节限制单文件 8 MiB。只上传用户所选文件，不自动发送文本、不自动重试写请求；电脑或 SSH 主机返回的绝对路径原样保存为输入框上方的待发文件卡片（草稿只记已确认的名称、大小和路径，不存文件字节或手机 URI），点发送时才统一拼成正文末尾的 `@路径` 并加入 `mentions`，不新增 wire 字段；历史消息末尾独立的绝对路径引用以文件卡片显示，复制和编辑使用原文。文件引用与编辑恢复适配官方 `lib/chat/composer/composer_files.dart` 的带引号路径及精确 token 规则。系统分享入口未扩展，群聊协议仍只发送图片。
- 续传通过官方双 32 位 `linkDigest` 对原始 JSON 条目计算摘要，保留未知字段和键顺序。每台电脑的 Mirror 跨连接复用，关闭后的历史最多保留 32 份，取消配对与身份重置时清理；没有新增跨 App 进程的磁盘历史缓存。首包恢复后才向 AppState 返回零起点完整结果，基线失配只对只读 `open` 完整重开一次，失败保留旧历史并明确报错；旧电脑忽略 `have` 时继续使用全量快照。
- Android 不注册 iPhone 专属 `push/away` APNs 接口，也不经外部推送服务发送聊天正文；继续使用已有的可选前台服务和本机通知。公开协议没有 Stash 或完整 Git 面板 RPC，本轮不扩展这些电脑端能力。
- 验证覆盖 Dart 单元、内存 Peer/PhoneLink/AppState 集成与 Flutter widget；已完成 Android arm64 release 编译、正式签名与同包覆盖安装，文档选择器与原生 iroh/QUIC 链路尚待真机端到端功能验收。

## 兼容约定

- 只用 link v2：iroh/QUIC、Ed25519、ALPN `baocode/link/2`。旧的 X25519 配对记录保留并标为「需要重新配对」，不自动信任，也不自动拨号。
- 中继以电脑公布的策略为准：direct 电脑不碰任何中继；配对时在 hello 之前只走局域网地址。
- 断线不重放写请求；增量补丁对不上基线时重新打开订阅。

## 来自 BaoCode 的文件

以下文件从 BaoCode 电脑端（官方提交 `cff287f1`）复制或改编，适配了手机的主题和交互，适用 GPL-3.0-only，版权归 BaoCode 作者。修改它们之前，先对照电脑端的同名文件。

- `lib/chat/`：`chat_models.dart`、`chat_output.dart`、`step_folds.dart`
- `lib/chat/markdown/`：`code_citation.dart`、`file_link.dart`、`finite_selection_edges.dart`、`hover_builder.dart`、`hover_scrollbar.dart`、`inline_code.dart`、`lazy_segment.dart`、`markdown_cjk.dart`、`markdown_math.dart`、`markdown_tags.dart`、`markdown_view.dart`、`mermaid_code_block.dart`、`safe_selection_indexes.dart`、`will_change_paint.dart`
- `lib/chat/widgets/`：`activity_row.dart`、`agent_message_card.dart`、`agent_step.dart`、`assistant_text.dart`、`chat_item_view.dart`、`command_step.dart`、`edge_fade_mask.dart`、`edit_step.dart`、`fade_curve.dart`、`flip_switcher.dart`、`fold_line.dart`、`live_selectable_text.dart`、`notice_row.dart`、`pixel_loader.dart`、`plan_card.dart`、`rolling_text.dart`、`shell_highlight.dart`、`shimmer_text.dart`、`step_clock.dart`、`step_header.dart`、`step_images.dart`、`strings.dart`、`terminal_text.dart`、`thinking_section.dart`、`thinking_spark.dart`、`tool_call_row.dart`、`turn_footer.dart`
- 其他：`lib/link/chat_codec.dart`、`lib/theme/material_file_icons.dart`、`lib/ui/tasks/chat_page.dart`、`lib/ui/widgets/model_icon.dart`

图标等素材的来源见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
