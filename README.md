# CP-YouHua

面向小白的中转机 + 落地机安装脚本。

当前版本：`v6.31`

## 这两个脚本分别做什么

- `install_transit.sh`：安装在美西 CN2 GIA 中转机上，只做 IPv4 Nginx stream SNI 盲传中转，不安装 Xray/V2Ray/Trojan/sing-box 等代理核心。
- `install_landing.sh`：安装在美国落地机上，申请 Cloudflare DNS-01 证书，生成 Xray 4 个节点，并只允许中转机 IP 访问落地代理端口。

推荐顺序：

1. 先装落地机，生成“中转导入 Token”。
2. 再装中转机，把落地机 Token 导入中转机。
3. 在中转机菜单里查看订阅链接或节点信息。

## 安装前准备

你需要准备：

- 两台干净 Debian 12 VPS。
- 中转机公网 IPv4。
- 落地机公网 IPv4。
- 一个托管在 Cloudflare 的域名，例如 `example.com`。
- 一个子域名给落地机用，例如 `us01.example.com`。
- Cloudflare API Token，权限至少需要：
  - `Zone:DNS:Edit`
  - `Zone:Zone:Read`

重要提醒：

- 不要把 GitHub Token、Cloudflare Token、服务器密码、UUID、Trojan 密码发到聊天、截图、Issue 或 Git 仓库里。
- Cloudflare 里落地域名必须是“仅 DNS / 灰云”，不要开启小黄云代理。
- 中转机和落地机都按 IPv4 业务路径设计，不要把节点改成 IPv6。
- 如果落地机还要安装 1Panel、Docker、OpenClaw 或 HermesAgent，安装落地脚本时把需要外部访问的端口填到“额外端口”里。

## 一键下载安装

在服务器上用 `root` 登录后执行。

落地机：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/vpn3288/CP-YouHua/main/install_landing.sh)
```

中转机：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/vpn3288/CP-YouHua/main/install_transit.sh)
```

如果服务器没有 `wget`，可以先装：

```bash
apt update && apt install -y wget curl
```

## 第一步：安装落地机

在落地机运行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/vpn3288/CP-YouHua/main/install_landing.sh)
```

按提示输入：

- 落地机域名：例如 `us01.example.com`
- Cloudflare API Token：只用于 DNS-01 申请证书
- 是否创建 DNS 灰云 A 占位记录：建议直接回车，默认 `Y`
- DNS 占位 IP：不懂就直接回车，默认 `203.0.113.10`
- Trojan 密码：不懂就直接回车，脚本会自动生成
- 中转机公网 IP：填你的中转机 IPv4
- 落地机监听端口：不懂就直接回车，默认 `8443`
- 额外端口：没有 1Panel/Docker 就直接回车；有就填端口，例如 `10086 8080`
- 确认开始安装：输入 `y`

安装完成后，脚本会显示类似下面的命令：

```bash
bash install_transit.sh --import <一长串Token>
```

把这整行命令保存好，下一步要在中转机执行。

## 第二步：安装中转机并导入落地机

在中转机运行落地机生成的导入命令：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/vpn3288/CP-YouHua/main/install_transit.sh) --import '<落地机生成的Token>'
```

如果你已经把 `install_transit.sh` 下载到了中转机，也可以执行：

```bash
bash install_transit.sh --import '<落地机生成的Token>'
```

中转机脚本会安装 Nginx stream、配置 TCP 443、阻断 UDP 443，并把这个落地机加入路由表。

## 第三步：查看节点和订阅

在中转机执行：

```bash
bash install_transit.sh
```

进入菜单后选择：

- `5`：显示当前所有节点及订阅链接
- `1`：继续导入新的落地机 Token
- `2`：删除指定落地机路由
- `3`：清除本系统所有数据
- `4`：退出

节点导入提醒：

- VLESS-gRPC 节点需要保留 `serviceName`、`authority=域名`、`alpn=h2` 和 `mode=multi`。
- VLESS-WS 节点需要保留 `alpn=http/1.1` 和脚本生成的 `path`。
- Trojan-TCP 节点需要保留 `alpn=http/1.1`，不要改成空 ALPN、`h2` 或 `http/1.0`。

## 常用检查命令

中转机状态：

```bash
bash install_transit.sh --status
```

落地机状态：

```bash
bash install_landing.sh --status
```

预期结果：

- 中转机 Nginx 正常运行。
- 中转机 TCP 443 放行。
- 中转机 UDP 443 被 DROP。
- 中转机 `.meta` 和 `.map` 路由记录一致。
- 落地机 Xray 正常运行。
- 落地机代理端口只允许中转机 IP 访问。
- 落地机证书和续期任务存在。
- IPv6 不形成业务路径。

## 落地机管理菜单

在落地机执行：

```bash
bash install_landing.sh
```

常用功能：

- 新增节点：给新的域名或新的中转机生成节点。
- 删除节点：删除指定落地节点。
- 修改端口：修改落地机监听端口。
- 显示配对信息：重新显示给中转机导入用的 Token。
- 卸载清理：删除本脚本安装的服务和配置。

## 卸载

中转机卸载：

```bash
bash install_transit.sh --uninstall
```

落地机卸载：

```bash
bash install_landing.sh --uninstall
```

卸载时需要按提示输入确认词。脚本会尽量清理自己创建的 Nginx/Xray/systemd/iptables/cron/logrotate/管理目录等内容。

## 重新 DD 系统后怎么做

如果你把 VPS 重装成干净 Debian 12：

1. 先确认 SSH 能登录。
2. 重新安装落地机脚本。
3. 复制落地机新生成的 Token。
4. 重新在中转机导入 Token。
5. 执行 `--status` 检查状态。

不建议直接复用旧机器上的 `/etc/transit_manager` 或 `/etc/landing_manager`。

## 常见问题

### 输错了怎么办？

大多数安装输入都支持重新输入。看到“格式错误，请重新输入”时，按提示重新填即可。

### Cloudflare Token 要填哪种？

使用 API Token，不要使用全局 API Key。Token 至少需要：

- `Zone:DNS:Edit`
- `Zone:Zone:Read`

测试完成后建议轮换 Token。

### DNS 占位 IP 是什么？

落地脚本可以给域名创建 Cloudflare 灰云 A 记录。这个 A 记录只用于 DNS 表面记录，不会写入中转导入 Token。

默认值是：

```text
203.0.113.10
```

如果你不懂，安装时直接回车即可。

### 为什么不能开 Cloudflare 小黄云？

本脚本使用的是中转机 SNI 盲传到落地机的 TLS/Xray 架构。Cloudflare 代理会改变连接路径，通常会导致节点不可用。域名必须保持“仅 DNS / 灰云”。

### 1Panel 或 Docker 端口怎么办？

落地机安装时会问“需要放行的额外端口”。把 1Panel 或 Docker 需要外部访问的端口填进去，例如：

```text
10086 8080
```

不要把落地代理端口本身填进去，否则脚本会拒绝，避免把代理端口开放给全网。

### 如何新增第二台落地机？

在新落地机安装 `install_landing.sh`，生成新的 Token。

然后到中转机执行：

```bash
bash install_transit.sh --import '<新落地机Token>'
```

### 如何排查状态不一致？

先分别执行：

```bash
bash install_transit.sh --status
bash install_landing.sh --status
```

如果脚本提示 `.meta/.map`、防火墙、证书或服务状态异常，按提示重新导入 Token、进入菜单修复，或卸载后重装。

## 本地开发和静态检查

在本仓库本地检查：

```bash
git pull --ff-only
git status --short --branch
git ls-files --eol
bash -n install_transit.sh
bash -n install_landing.sh
git diff --check
bash tests/local_static_invariants.sh
bash tests/pre_real_machine_local_gate.sh
```

主笔和审查者指南：

- `guides/main_writer_task_guide.md`
- `guides/reviewer_task_guide.md`

变更记录：

- `JiLu.md`
