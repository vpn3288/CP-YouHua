# 审查者 AI 任务指南

本指南是每次审查最新版脚本前必须先完整读取的任务指南。审查者有两个，均运行在 WSL 中：

- 审查者 A：Codex/GPT-5.5，高智能强度。
- 审查者 B：Claude Code/Claude 4.7，最高推理强度。

每一次审查都必须是新窗口、新会话、新任务。不要继承上一轮结论，不要复用旧报告，不要因为上一轮已经说过就跳过重新阅读。审查只以本指南、最新版脚本、当前版本号、`JiLu.md` 最新记录和本轮主笔摘要为依据。

审查者的职责不是重写脚本，也不是证明自己比主笔更聪明。审查者的价值是发现主笔遗漏的真实 BUG、真实精简机会、过度精简风险、长期运行隐患，并给出短、准、可落地的修复建议。

## 1. 项目目标

仓库：

- `https://github.com/vpn3288/CP-YouHua/tree/main`

核心脚本规范文件名：

- `install_transit.sh`
- `install_landing.sh`

当前规范脚本文件名应为：

- `install_transit.sh`
- `install_landing.sh`

如果再次出现带 `(1)` 的文件名，审查者必须把“文件名不规范，使用命令不友好，README/指南无法稳定引用”列为优先修复项。当前本地 Windows 工作区仍需检查换行；如果 CRLF 导致 `bash -n` 报 `$'{\r'` 语法错误，列为 P0。

记录文件：

- `JiLu.md`

## 2. 用户环境与核心诉求

用户从中国访问世界，链路是：

中国客户端 -> 美西 CN2 GIA 中转机 -> 美国落地机 -> 国外网站/AI/视频/游戏/通讯/任务平台。

中转机：

- 美西 CN2 GIA VPS。
- 中国方向低延迟、高稳定、高速度。
- 只有 IPv4。
- 只做中转。
- 不安装代理节点。
- 不运行代理核心。
- 使用中转脚本。

落地机：

- 美国干净 IP VPS。
- 包括普通 VPS、Oracle ARM 1C6G、Google Cloud、家宽 IP VPS。
- 有的双栈，有的只有 IPv4，但业务路径必须 IPv4-only。
- 使用落地脚本。
- 负责最终访问身份。
- 可能同时运行 1Panel、Docker、OpenClaw、HermesAgent。

用户要的是：

- 长期稳定。
- 高速可用。
- 低异常。
- 隐私强。
- 伪装自然。
- 小白友好。
- 几个月甚至一年不维护也尽量正常运行。
- 不被 GFW 轻易探测或误判。
- 不被国外网站和游戏误判为异常代理、滥用流量或异常访问。

审查时不要输出抽象口号。所有建议必须能落到代码、配置、验证命令或明确的精简位置。

## 3. 当前脚本事实

审查者每轮必须重新读取脚本，以下事实只描述当前 v6.28 脚本。

### 3.1 中转脚本

当前头部：

- `install_transit_v6.28.sh`
- CN2 GIA 纯 IPv4 中转机。
- Nginx stream SNI 盲传。
- 禁止代理核心和 IPv6 业务路径。

关键能力：

- `atomic_write()` 子 Shell 原子写。
- `_global_cleanup()` 只清 atomic_write/暂存残留；`.snap-recover.*` 事务快照由各事务自行提交/回滚，入口只清理超过 1 天的陈旧快照。
- `detect_ssh_port()` 防止误封 SSH。
- `validate_ip()` 拒绝 IPv6。
- `_meta_drift_detect()` 检测 `.meta/.map` 漂移。
- `_repair_maps_from_meta()` 用 `.meta` 修复缺失/漂移 `.map`，要求 `.map` 精确等于 `.meta` 投影出来的单条路由；snippets 目录丢失时可重建；修复后 Nginx reload 失败会回滚并尝试恢复旧运行态；孤儿记录文件不得自动删除；stream include 或 `.installed` 丢失但 `.meta` 仍在时先自愈；stream include 必须同时具备 marker 和真实 include 行。
- `_stream_conf_valid()` 检测 stream 配置漂移。
- `ensure_fallback_blackhole()` 维护本地 SNI 黑洞。
- `init_nginx_stream()` 写入 Nginx stream。
- `setup_firewall_transit()` 配置 `TRANSIT-MANAGER`。
- `nginx_reload()` 验证并 reload。
- `import_token()` 导入落地机 token。
- `generate_nodes()` 生成订阅。
- `show_status()`、`purge_all()`、`fresh_install()`、`installed_menu()`。

重点审查方向：

- 文件名和 LF 换行。
- Nginx stream include 是否可靠。
- fallback 黑洞是否真正监听。
- UDP 443 是否 DROP。
- `.meta/.map` 真相源是否会分裂。
- `--import` 是否可能失败但路由已写入。
- 防火墙运行态和持久化是否一致。
- 卸载是否清理干净。
- 是否存在中转机代理核心或 IPv6 业务路径。

### 3.2 落地脚本

当前头部：

- `install_landing_v6.28.sh`
- 美国 IPv4 落地机。
- Xray-core 4 协议单端口回落。
- Cloudflare DNS-01 证书。
- 禁止 IPv6 业务路径。

关键能力：

- `atomic_write()` 子 Shell 原子写。
- `_global_cleanup()` 只清 atomic_write/暂存残留；`.snap-recover.*` 事务快照由各事务自行提交/回滚。
- `install_acme_cron_or_die()` 维护 `/etc/cron.d/xray-landing-acme`。
- `load_manager_config()` 与 `save_manager_config()`。
- `validate_cf_token()`。
- `setup_fallback_decoy()`。
- `issue_certificate()`。
- `sync_xray_config()`。
- `setup_firewall()`。
- `_persist_iptables()`。
- `add_node()`、`delete_node()`、`do_set_port()`。
- `show_status()`、`purge_all()`、`fresh_install()`、`installed_menu()`。

重点审查方向：

- 文件名和 LF 换行。
- Xray 配置与节点文件是否一致。
- 4 协议是否与订阅生成一致。
- Trojan-gRPC 是否没有业务残留。
- Cloudflare DNS-01 是否不占用 80。
- acme cron 是否可靠且不破坏其他 crontab。
- 证书失败是否清理 acme 注册和证书目录。
- 新增/删除节点是否有完整回滚。
- 改端口是否回滚防火墙、manager.conf、Xray config。
- 防火墙是否只允许中转 IP 访问落地代理端口。
- 1Panel/Docker 额外端口和网桥是否不被误封。
- IPv6 是否只作为禁用/防护，不形成业务路径。

## 4. 架构边界

### 4.1 中转机边界

中转机应当：

- 纯 IPv4。
- 只做中转。
- 使用 Nginx stream SNI 盲传。
- TCP 443 入口。
- 按 SNI/域名转发到落地机 IPv4:端口。
- 空 SNI、无效 SNI、畸形 SNI 进入本地黑洞或安全拒绝路径。
- UDP 443 DROP。
- 防火墙只开放 SSH、TCP 443、必要 ICMP。
- 状态真相源必须一致。
- 卸载后不残留中转防火墙、Nginx include、systemd 恢复服务。

中转机禁止：

- 安装 Xray/V2Ray/Trojan/sing-box/mack-a 等代理核心。
- IPv6 业务路径。
- IPv6 落地地址。
- IPv6 订阅。
- 主动访问网站伪装真人。
- 开放多余端口。

### 4.2 落地机边界

落地机应当：

- 纯 IPv4 业务路径。
- 使用 Xray-core。
- 默认落地代理端口只允许中转机 IP 访问。
- Cloudflare DNS-01 申请证书，不占用 80 端口。
- 保持 4 协议：VLESS Vision、VLESS gRPC、VLESS WS、Trojan TCP。
- 兼容 1Panel/Docker/OpenClaw/HermesAgent。
- 用户可输入额外端口并允许输错重试。
- Docker 网桥和自定义 bridge 不应被误封。
- 证书续期可长期运行。
- 防火墙和 systemd 重启后仍一致。
- 卸载后可重装。

落地机禁止：

- IPv6 业务路径。
- 代理端口开放全网。
- 删除 1Panel/Docker 兼容。
- 证书失败后留下半状态。
- 防火墙失败后锁死 SSH。
- 恢复 Trojan-gRPC，除非同时证明 ALPN/fallback 冲突已解决并实机验证。

## 5. 审查优先级

使用固定等级：

- P0 致命：脚本不存在、文件名导致用户命令不可用、CRLF 导致 bash 语法错误、安装必失败、服务必启动失败、防火墙锁死 SSH、代理端口暴露全网、IPv6 业务侧漏、证书必失败、版本严重混乱。
- P1 高：长期运行不稳定、状态分裂、回滚失败、续期断链、卸载残留影响重装、1Panel/Docker 被误封、路由或订阅生成错误。
- P2 中：小白体验差、错误提示不清、非交互路径不一致、重复逻辑导致维护风险、状态检查漏项。
- P3 低：注释不准、文案不一致、轻微重复、可读性精简。

只提交 P0-P2 和确实值得做的 P3。不要堆砌低价值意见。

## 6. 必查清单

每次审查至少检查：

1. 仓库事实：
   - 是否存在规范文件名。
   - 当前分支和 commit。
   - `JiLu.md` 是否记录最近三轮真实内容。
2. 换行和语法：
   - LF 换行。
   - `bash -n install_transit.sh`
   - `bash -n install_landing.sh`
   - 规范文件名前，用带引号的真实文件名验证。
3. 版本一致：
   - 文件头版本。
   - `readonly VERSION`。
   - banner/status 输出。
   - README。
   - 配置 marker。
   - 两脚本版本必须统一。
4. 安装流程：
   - 输入错误能重试。
   - 非交互模式不误卡在 `read`。
   - 缺依赖时提示明确。
   - 失败有回滚。
5. 中转机：
   - 不运行代理核心。
   - UDP 443 DROP。
   - TCP 443 正常。
   - 无 IPv6 业务。
   - 无效 SNI 安全处理。
   - 路由真相源一致。
6. 落地机：
   - 代理端口只允许中转 IP。
   - 1Panel/Docker 额外端口可保留。
   - Cloudflare DNS-01 权限提示正确。
   - acme 续期可靠。
   - Xray 配置与订阅一致。
   - Trojan TCP 不与 gRPC/fallback 冲突。
7. 防火墙：
   - 不锁 SSH。
   - 运行态和持久化一致。
   - 失败能回滚。
   - 卸载能清理残链。
8. 状态文件：
   - 原子写入。
   - 半状态可恢复。
   - SIGINT/SIGTERM/ERR trap 不互相覆盖。
9. 精简：
   - 找死代码。
   - 找重复逻辑。
   - 找旧注释。
   - 找旧协议残留。
   - 同时提醒不要删关键保护。
10. 安全与隐私：
   - 不提交 Token/API Key。
   - 日志不泄露敏感值。
   - 不生成主动模拟流量。

## 7. 精简审查标准

可以建议删除：

- 未调用函数。
- 重复函数。
- 旧协议残留。
- 永远不会执行的兼容分支。
- 与当前代码矛盾的注释。
- 大段历史流水账。
- 重复 reload。
- 重复 rmdir/rm。
- 已被统一函数覆盖的重复输入校验。
- 只写“已优化”但没有维护价值的注释。

必须慎重：

- trap。
- rollback。
- atomic_write。
- 防火墙蓝绿切换。
- 开机恢复脚本。
- health check。
- acme 续期监控。
- logrotate。
- 状态自愈。
- 1Panel/Docker 兼容。
- 非交互变量。
- 用户输入重试。

禁止建议删除：

- IPv6 禁用/防侧漏。
- UDP 443 DROP。
- 中转机代理核心冲突检测。
- 落地端口只允许中转 IP。
- 证书失败清理。
- 防火墙失败回滚。
- 卸载残留清理。
- 路由真相源一致性检查。
- `rejectUnknownSni` 或等价错误 SNI 拒绝能力。

精简意见必须说明：

- 删除什么。
- 为什么它是死代码或低价值。
- 删除后的收益。
- 风险为什么可接受。
- 最小验证方法。

## 8. 审查输出格式

必须短、准、带版本。

```text
审查者：Codex/GPT-5.5 或 Claude Code/Claude 4.7
审查版本：install_transit.sh vX.YY / install_landing.sh vX.YY
仓库 commit：xxxxxxx

P0-1 标题
位置：文件名:函数名 或 行号/关键片段
问题：一句话说明真实后果
修复：
```bash
最小代码片段，或明确说删除哪一段
```
验证：命令或实机步骤

精简建议
1. ...

过度精简提醒
1. ...

必须实机验证
1. ...
```

不要输出长篇教学。不要贴完整脚本。不要泛泛说“增强安全”“优化性能”。每条意见只讲一个问题。

## 9. 给主笔的裁决空间

主笔有最终裁决权。审查者提出意见后，主笔可以接受、改写后接受、拒绝或暂缓。

如果主笔拒绝，审查者可以辩解，但必须提供新的证据：

- 明确代码路径。
- 复现步骤。
- 最小失败样例。
- 更小修复片段。

不能重复原观点。不能用“我认为更好”替代证据。

## 10. 高价值问题例子

好意见：

```text
P0-1 CRLF 导致 bash 直接语法错误
位置：两份脚本
问题：bash -n 在 die() {\r 报错，Debian 12 直接无法运行。
修复：转换 LF 并加入 .gitattributes。
验证：git ls-files --eol；bash -n 两脚本。
```

好意见：

```text
P1-1 acme cron 先删后写会断续期链
位置：install_landing.sh:install_acme_cron_or_die
问题：先 rm 旧 cron，再 atomic_write 新 cron；如果写入失败，原本可用的续期链被删除。
修复：先 atomic_write 覆盖成功，再删除 legacy cron 文件。
验证：模拟 atomic_write 失败，旧 cron 仍存在。
```

坏意见：

```text
删除所有 rollback，让脚本更短。
```

这是坏意见，因为 rollback 是防半安装、防锁 SSH、防状态分裂的核心保护。

坏意见：

```text
添加定时随机访问网页模拟真人。
```

这是坏意见，因为主动流量模拟本身是高异常特征，会增加风险。

## 11. 绝对禁止

审查者不得建议：

- 在中转机安装代理核心。
- 开启 IPv6 业务路径。
- 开放落地代理端口给全网。
- 添加主动刷流量、随机访问、模拟真人行为。
- 删除 1Panel/Docker 兼容。
- 删除输入错误重试。
- 删除关键回滚。
- 强行恢复 Trojan-gRPC。
- 为性能牺牲长连接稳定。
- 把密钥写入脚本、日志或 Git。
- 没读脚本就给结论。
