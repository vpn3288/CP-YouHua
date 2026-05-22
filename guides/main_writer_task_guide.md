# 主笔 AI 任务指南

本指南是主笔每次开工前必须先完整读取的最高优先级项目指南。主笔身份是：用户电脑中的独立 Codex，目标模型为 OpenAI GPT-5.5，高智能强度，负责最终工程决策、脚本修改、验证、提交、推送和对审查意见的裁决。

WSL 中的 Codex/GPT-5.5 与 Claude Code/Claude 4.7 是两个审查者，不是主笔。审查者负责发现真实 BUG、真实精简点和过度精简风险；主笔负责判断哪些意见正确、哪些错误、哪些需要改写后接受。

## 1. 仓库事实

目标仓库：

- GitHub: `https://github.com/vpn3288/CP-YouHua/tree/main`
- 分支: `main`
- 记录文件: `JiLu.md`
- 主笔指南: `guides/main_writer_task_guide.md`
- 审查指南: `guides/reviewer_task_guide.md`

当前已上传脚本事实：

- 当前远端提交（本轮 v6.11 未推送前）: `9223d5a fix: harden transit route recovery v6.08`
- 中转脚本当前文件名: `install_transit.sh`
- 落地脚本当前文件名: `install_landing.sh`
- 两脚本头部版本: `v6.11`
- 当前工作区已通过 `git ls-files --eol` 验证为 LF；若未来出现 CRLF 并导致 `bash -n` 报 `$'{\r'`，列为 P0。

第一轮真实优化已完成：

1. 脚本文件名已规范为 `install_transit.sh` 和 `install_landing.sh`。
2. 脚本已确认使用 LF 换行，`bash -n` 可验证。
3. README 与 `JiLu.md` 已记录“文件名与换行修复”。
4. 未改业务逻辑，仓库已进入可执行、可审查状态。

后续所有指南、README、命令和审查提示都应以规范文件名为准。

## 2. 多 AI 分工

### 2.1 主笔

主笔是用户电脑中的独立 Codex/GPT-5.5。

职责：

1. 每轮开工前读取本指南。
2. 拉取最新版仓库，完整阅读最新版中转脚本、落地脚本、README、JiLu。
3. 给两个审查者分别创建全新审查窗口/全新任务。
4. 给每个审查者发送 `guides/reviewer_task_guide.md`、最新版脚本、当前版本号、最近一轮变更摘要。
5. 汇总 WSL Codex/GPT-5.5 和 WSL Claude Code/Claude 4.7 的意见。
6. 逐条裁决：接受、改写后接受、拒绝、暂缓。
7. 对真实 BUG、真实精简点、真实稳定性问题进行精准修复。
8. 运行验证，更新版本号，更新 `JiLu.md`。
9. 默认每三轮真实优化后提交并推送 GitHub；用户要求立即上传时，立刻提交推送。
10. 推送后确认远端 hash，清理工作区，等待下一轮。

主笔拥有最终审核权。审查者可以辩解，但必须提供新的代码证据、复现步骤或更小修复片段。

### 2.2 审查者

审查者有两个，均安装在 WSL 中：

- 审查者 A：Codex/GPT-5.5，高智能强度。
- 审查者 B：Claude Code/Claude 4.7，最高推理强度。

硬规则：

1. 每次审查新版本都必须新窗口、新会话、新任务。
2. 不复用上一轮审查窗口，不继承上一轮结论，不把旧报告当作事实。
3. 每次审查前必须先读取 `guides/reviewer_task_guide.md`。
4. 审查者默认不直接改仓库，只提出问题、精简建议、过度精简提醒和最小修复片段。
5. 审查者必须围绕用户诉求和最新版脚本事实，不得泛泛而谈。

## 3. 用户核心诉求

用户从中国访问世界。链路结构是：

1. 中国客户端。
2. 美西 CN2 GIA 中转机。
3. 美国落地机。
4. 国外网站、AI、视频、博客、软件、游戏、TikTok、通讯软件、问卷和测试任务平台。

中转机条件：

- CN2 GIA 美西 VPS。
- 连接中国延迟低、速度快、稳定。
- 只有 IPv4。
- 使用中转脚本安装。
- 只做中转，不主动安装代理节点，不承担最终访问身份。
- 禁止 IPv6 业务路径。
- 禁止安装 Xray/V2Ray/Trojan/sing-box/mack-a 等代理核心。

落地机条件：

- N 个美国干净 IP VPS。
- 连接中国延迟高、速度慢、稳定性弱。
- 有的 IPv4/IPv6 双栈，有的只有 IPv4，没有纯 IPv6 落地机。
- 使用落地脚本安装。
- 类型包括普通 VPS、Oracle ARM 1C6G、Google Cloud、家宽 IP VPS。
- 统一是 SSH 远程 DD 后的干净 Debian 12。
- 落地机最终对外访问网站与应用。
- 落地机和中转机都禁止 IPv6 业务路径，避免链路身份不一致和侧漏。

用户目标可以工程化理解为：

- 降低可观测异常。
- 降低被 GFW 主动探测、误判、阻断的概率。
- 降低国外服务把用户识别成异常代理、机房滥用、自动化或高风险流量的概率。
- 保持美国普通用户式的稳定访问体验。
- 长期稳定运行，几个月甚至一年尽量不需要维护。

主笔表达时避免空泛口号。工程目标是稳定、低异常、少暴露、少误配置、少侧漏、少半状态、可恢复、小白可安装。

## 4. 当前脚本架构事实

主笔每轮必须重新读取脚本，以下事实只描述当前 `v6.11` 脚本。

### 4.1 中转脚本事实

当前中转脚本头部写明：

- `install_transit_v6.11.sh`
- 架构：CN2 GIA 纯 IPv4 中转机。
- Nginx stream SNI 盲传。
- 禁止代理核心和 IPv6 业务路径。
- 当前版本说明：同步版本号；中转业务逻辑不变。

关键结构：

- `MANAGER_BASE=/etc/transit_manager`
- `CONF_DIR=/etc/transit_manager/conf`
- `NGINX_MAIN_CONF=/etc/nginx/nginx.conf`
- `NGINX_STREAM_CONF=/etc/nginx/stream-transit.conf`
- `TRANSIT_FALLBACK_CONF=/etc/nginx/conf.d/transit-fallback.conf`
- `SNIPPETS_DIR=/etc/nginx/stream-snippets`
- `LISTEN_PORT=443`
- `FW_CHAIN=TRANSIT-MANAGER`

关键能力：

- `atomic_write()` 子 Shell 原子写。
- 全局清理只清 atomic_write/暂存残留；事务快照由各事务自行提交/回滚，避免只读状态检查误删活跃快照。
- SSH 端口探测，避免防火墙误封。
- IPv4 校验，拒绝 IPv6 落地地址。
- `.meta` 与 `.map` 漂移检测。
- 缺失/漂移 `.map` 可根据 `.meta` 修复，且 `.map` 必须精确等于 `.meta` 投影出来的单条路由；snippets 目录丢失时可重建；修复后 Nginx reload 失败会回滚并尝试恢复旧运行态；孤儿记录文件不得自动删除，避免误删订阅真相源；stream include 或 `.installed` 丢失但 `.meta` 仍在时先自愈，不直接进入重装；stream include 必须同时具备 marker 和真实 include 行。
- Nginx stream 配置漂移检测和重写。
- fallback blackhole `127.0.0.1:9999`。
- UDP 443 DROP。
- 中转路由导入 token。
- 生成完整订阅。
- 状态检查、卸载清理、安装标记自愈。

中转脚本未来方向：

- 保持纯中转，不运行代理核心。
- 保持 IPv4-only。
- 保持 Nginx stream SNI 盲传。
- 强化 `.meta/.map` 一致性和导入事务。
- 强化 Nginx stream include、fallback 黑洞、reload/restart 失败回滚。
- 精简旧审查标签、历史注释和重复逻辑，但不能删除回滚、自愈、UDP 443 DROP、IPv6 禁用、防代理核心检测。

### 4.2 落地脚本事实

当前落地脚本头部写明：

- `install_landing_v6.11.sh`
- 架构：美国落地机。
- Xray-core 4 协议单端口回落。
- Cloudflare DNS-01 证书。
- 禁止 IPv6 业务路径。
- 当前版本说明：持久标记脚本安装的 Nginx，卸载时只停止自带 Nginx。

关键结构：

- `LANDING_BASE=/etc/xray-landing`
- `LANDING_CONF=/etc/xray-landing/config.json`
- `LANDING_BIN=/usr/local/bin/xray-landing`
- `LANDING_SVC=xray-landing.service`
- `MANAGER_BASE=/etc/landing_manager`
- `MANAGER_CONFIG=/etc/landing_manager/manager.conf`
- `ACME_HOME=/etc/xray-landing/acme`
- `CERT_BASE=/etc/xray-landing/certs`
- `FW_CHAIN=XRAY-LANDING`
- `FW_CHAIN6=XRAY-LANDING-v6`
- 默认 `LANDING_PORT=8443`

关键能力：

- `atomic_write()` 子 Shell 原子写。
- 全局清理只清 atomic_write/暂存残留；事务快照由各事务自行提交/回滚。
- 安装锁。
- Cloudflare Token 格式校验。
- Cloudflare DNS-01 证书申请。
- 独立 `/etc/cron.d/xray-landing-acme` 续期。
- Xray 下载、安装、systemd 服务。
- 4 协议配置和订阅信息：VLESS Vision、VLESS gRPC、VLESS WS、Trojan TCP。
- Trojan-gRPC 已删除并标注不得恢复。
- 1Panel/OpenResty/Tengine 冲突检测。
- fallback 只监听 IPv4 环回。
- 防火墙只放行 SSH、中转 IP、用户额外端口、Docker 网桥。
- IPv6 防火墙仅作为禁用/防护，不得形成业务路径。
- 新增节点、删除节点、改端口都有事务/回滚。
- 状态检查、卸载清理、安装标记自愈。

落地脚本未来方向：

- 保持 4 协议，不恢复 Trojan-gRPC。
- 保持 Cloudflare DNS-01，不占用 80 端口。
- 保持落地代理端口只允许中转机 IP。
- 保持 1Panel/Docker/OpenClaw/HermesAgent 兼容。
- 强化证书失败清理、acme 续期、Xray config 与节点文件一致性。
- 精简旧审查标签、重复注释、重复清理，但不能删除输入重试、回滚、状态自愈、1Panel/Docker 兼容、IPv6 禁用。

## 5. 使用场景

脚本必须服务这些真实场景：

- 使用 AI 服务。
- 访问网站、博客、视频平台。
- 使用软件和网络通讯工具。
- 玩游戏。
- 看 TikTok。
- 使用固定干净家宽 IP 做测试游戏、问卷调查等赚钱任务。
- 在部分 Oracle ARM 1C6G 落地机上安装 1Panel。
- 通过 1Panel 的 Docker 安装 OpenClaw 或 HermesAgent。
- 1Panel 只需要 Telegram 联通、一个外部端口、反向代理和证书。

脚本不得破坏 1Panel、Docker、OpenClaw、HermesAgent 的基本端口与容器网络需求。

## 6. 永久硬原则

1. 禁止虚假优化：没有真实行为变化、没有风险下降、没有维护收益的改动不要做。
2. 禁止无意义优化：不要为了“看起来高级”引入复杂依赖。
3. 禁止画蛇添足：不要新增协议、新服务、新守护进程、新工具，除非能证明必要。
4. 小白安装优先：所有交互输入必须能输错后重新输入，错误提示要告诉用户怎么修。
5. 长期稳定优先：不要用激进内核参数破坏长连接、视频、AI、通讯软件和游戏。
6. IPv4-only 是硬边界：中转机和落地机都禁止 IPv6 业务路径。
7. 精简要有净收益：只有好处远大于坏处才精简。
8. 不泄露秘密：任何 Token、API Key、UUID、密码不得提交 Git。
9. Debian 12 干净系统优先：脚本应适配 root、SSH、apt、systemd 的基础环境。
10. 主笔必须可验证：每轮都要能说明改了什么、为什么、怎么验证。

## 7. 每轮主笔流程

### 7.1 开工

每轮必须执行：

1. 读取本指南。
2. `git pull --ff-only`。
3. `git status --short --branch`。
4. 确认脚本规范文件名是否存在：
   - `install_transit.sh`
   - `install_landing.sh`
5. 如果异常出现 `install_transit (1).sh`、`install_landing (1).sh`，先恢复规范文件名。
6. 完整阅读两份脚本和 `JiLu.md`。
7. 记录当前脚本版本、文件头版本、README 版本、最近三轮记录。
8. 检查换行：
   - `git ls-files --eol`
9. 基础静态验证：
   - `bash -n install_transit.sh`
   - `bash -n install_landing.sh`
   - 规范文件名前用带引号的真实文件名验证。
10. 如有 `shellcheck`，运行并只处理真实问题。
11. 用 `rg` 查明显残留：
   - 旧协议残留。
   - Trojan-gRPC 当前业务残留。
   - IPv6 业务路径。
   - 未定义函数调用。
   - 版本不一致。
   - TODO/临时调试输出。

### 7.2 新窗口审查

每轮给两个审查者分别创建新窗口/新任务。

审查者提示必须包含：

- `guides/reviewer_task_guide.md` 全文或路径。
- 当前两份脚本全文或可读路径。
- 当前版本号。
- 最近一轮主笔改动摘要。
- 要求审查者不要复用旧结论。

不要把另一位审查者的意见提前喂给当前审查者。两位审查者应独立判断。

### 7.3 裁决审查意见

对每条意见标记：

- 接受：真实 BUG 或高价值精简。
- 改写后接受：方向对，但代码片段不严谨。
- 拒绝：误读代码、虚假优化、破坏稳定、违背 IPv4-only、破坏 1Panel/Docker、破坏安装体验。
- 暂缓：可能有价值，但需要实机验证或用户确认。

拒绝时必须给证据：文件路径、函数名、现有逻辑、验证结果、收益/风险判断。

### 7.4 实施

实施规则：

1. 只改必要范围。
2. Bash 代码必须兼容 `set -euo pipefail`。
3. 所有新增函数必须有调用点。
4. 所有删除函数必须确认无间接调用。
5. 涉及防火墙、证书、Nginx、Xray、systemd 的改动必须有失败保护或回滚。
6. 涉及状态文件的改动必须原子写入，避免半状态。
7. 涉及安装输入的改动必须保留循环重试。
8. 涉及卸载的改动必须检查残留。
9. 涉及精简的改动必须说明删掉后收益和风险。
10. 不得提交密钥、Token、临时日志、测试输出。

### 7.5 版本规则

每次真实优化后，两脚本版本必须统一递增。

当前基线是 `v6.11`。下一轮真实优化应统一为 `v6.12`。默认真实修复要涨版本。

同步范围：

- 文件头脚本名版本。
- `readonly VERSION`。
- banner/status 输出。
- README 当前版本。
- 配置 marker/version 字段。
- `JiLu.md`。

没有真实优化时，不允许只涨版本。

### 7.6 JiLu.md

每轮真实优化都要在 `JiLu.md` 追加记录。每三轮推送时，`JiLu.md` 必须包含这三轮的真实内容。

推荐格式：

```md
## YYYY-MM-DD 第 N 轮 - vX.YY

- 主笔：Codex/GPT-5.5
- 审查者：WSL Codex/GPT-5.5；WSL Claude Code/Claude 4.7
- 本轮目标：修复/精简/验证方向
- 接受意见：
  - ...
- 拒绝意见：
  - ...（理由）
- 修改文件：
  - install_transit.sh
  - install_landing.sh
- 真实改动：
  - ...
- 验证：
  - ...
- 残留风险：
  - ...
- Commit:
  - ...
```

`JiLu.md` 禁止写空话，例如“全面优化”“增强安全”。必须写真实变化。

### 7.7 提交推送

默认每三轮真实优化提交并推送一次。用户要求“本轮上传”或“马上上传”时，立即提交推送。

提交前必须：

1. `git diff --check`
2. `bash -n` 两脚本。
3. `git diff` 自审。
4. 确认 `JiLu.md` 已记录真实内容。
5. 确认没有密钥。

推送后必须确认本地 HEAD hash、远端 `origin/main` hash 和 `git status` 干净。

## 8. 精简标准

可以精简：

- 未调用函数。
- 重复函数。
- 已废弃变量。
- 旧协议残留。
- 与当前架构矛盾的注释。
- 大段历史流水账。
- 永远不会执行的兼容分支。
- 只描述“做了优化”但不解释风险点的注释。
- 已被统一函数覆盖的重复校验。

慎重精简：

- trap/rollback。
- atomic_write。
- 防火墙蓝绿切换。
- 状态自愈。
- 健康检查。
- 证书续期监控。
- systemd 恢复服务。
- logrotate。
- 非交互环境变量路径。
- 1Panel/Docker 端口与网桥兼容。
- 用户输错后的重试。

禁止精简：

- IPv6 禁用和防侧漏。
- UDP 443 DROP。
- 中转机代理核心冲突检测。
- 落地代理端口只允许中转 IP。
- 证书失败回滚。
- 防火墙失败回滚。
- 路由真相源一致性检查。
- `rejectUnknownSni` 或等价错误 SNI 拒绝能力。
- 卸载残留清理。

## 9. 验收标准

最低验收：

1. 脚本规范文件名存在。
2. 脚本 LF 换行。
3. `bash -n` 全部通过。
4. 版本一致。
5. `git diff --check` 通过。
6. `--help` 能运行。
7. 无明显旧协议残留。
8. 无 IPv6 业务路径。
9. 无未定义函数调用。
10. 无密钥进入 Git。

推荐实机验收：

1. Debian 12 干净中转机全新安装。
2. Debian 12 干净落地机全新安装。
3. 错误输入重试。
4. Cloudflare DNS-01 证书申请。
5. Nginx/Xray/systemd 启动。
6. 防火墙重启后仍正确。
7. 1Panel/Docker 额外端口可用。
8. 4 个客户端节点可连接。
9. 卸载后可重装。

无法实机验证时，最终说明必须写清楚“已做静态验证，未做实机安装验证”。

## 10. 对审查者的回复格式

```text
审查意见 X：接受/改写后接受/拒绝/暂缓。
理由：引用脚本事实和收益风险。
处理：改了哪个函数或为什么不改。
验证：运行了什么命令或需要实机验证什么。
```

## 11. 绝对禁止

- 把 API Key、Cloudflare Token、UUID、Trojan 密码提交到 Git。
- 给中转机安装代理核心。
- 开启 IPv6 业务路径。
- 开放落地代理端口给全网。
- 添加主动刷流量、模拟真人访问、随机访问网站。
- 删除 1Panel/Docker 兼容。
- 删除输入错误重试。
- 删除关键回滚和状态自愈。
- 未读脚本就开始修。
- 未验证就提交。
