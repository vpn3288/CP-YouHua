# CP-YouHua 实机安装测试清单

本清单用于从本地静态验证进入 Debian 12 中转机/落地机实机测试。不要在本文件写入 Token、密码、UUID、服务器私钥或临时日志。

## 0. 安全前置

1. 轮换所有曾经暴露在聊天、日志或终端历史中的 GitHub Token、Cloudflare Token 和服务器密码。
2. 若 SSH 提示 `REMOTE HOST IDENTIFICATION HAS CHANGED`：
   - 先通过 VPS 控制台确认机器确实已 DD 重装。
   - 记录控制台展示的 SSH host key 指纹。
   - 可在 WSL 中运行 `bash tests/ssh_hostkey_probe.sh <ip>=SHA256:<控制台指纹>` 只读比较当前公网 SSH 指纹。
   - 仅在指纹一致后执行 `ssh-keygen -R <ip>` 并重新连接。
   - 不要全局关闭 host key 检查。
3. Cloudflare 测试 Token 使用最小权限和测试 Zone：
   - `Zone:DNS:Edit`
   - `Zone:Zone:Read`
   - 测完立即吊销或轮换。
4. 实机测试命令、截图和日志不得提交 Git。

## 1. 本地基线

在仓库根目录运行：

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

预期：

- 工作区干净。
- 两脚本为 LF。
- 两脚本语法通过。
- 本地静态不变量测试通过。
- 无明文密钥样式命中。

## 2. 中转机安装测试

目标：只做 IPv4 Nginx stream SNI 盲传中转，不安装代理核心。

测试步骤：

1. 确认干净 Debian 12，只监听 SSH。
2. 上传当前 `install_transit.sh`。
3. 测试错误输入：
   - `LANDING_TOKEN` 为空。
   - `LANDING_TOKEN` 为普通垃圾字符串。
   - `LANDING_TOKEN` 为形似 Base64 但不可解析 JSON 的字符串。
4. 预期错误输入在依赖安装、Nginx、iptables 和管理目录写入前失败。
5. 使用真实落地 Token 后安装。
6. 检查：
   - `nginx -t`
   - `systemctl is-active nginx`
   - TCP 443 监听。
   - UDP 443 DROP。
   - 无 IPv6 业务监听。
   - `/etc/transit_manager/conf/*.meta` 与 `/etc/nginx/stream-snippets/*.map` 一致。
   - `--status` 正常。
   - 菜单生成订阅正常。

## 3. 落地机安装测试

目标：Cloudflare DNS-01 签证书，Xray 4 协议单端口回落，代理端口只允许中转 IP。

测试步骤：

1. 确认干净 Debian 12，只监听 SSH。
2. 上传当前 `install_landing.sh`。
3. 测试错误输入：
   - 域名格式错误。
   - Cloudflare Token 格式错误。
   - 中转 IP 格式错误。
   - 端口非法。
   - headless 模式设置 `FAKE_IP`。
4. 预期错误输入有提示并可重新输入；headless `FAKE_IP` 在副作用前失败。
5. 使用最小权限测试 Token 运行完整安装。
6. 检查：
   - 证书存在且 acme 续期 cron 存在。
   - `systemctl is-active xray-landing`
   - fallback 只监听 IPv4 环回。
   - 主端口只允许中转 IP。
   - IPv6 未形成业务路径。
   - 4 个节点信息生成正常。
   - `--status` 正常。
   - 额外端口不破坏 1Panel/Docker 场景。

## 4. 链路与回滚测试

1. 从落地复制 Base64 Token 到中转导入。
2. 检查中转 `.meta/.map`、Nginx reload、订阅输出。
3. 验证节点连通性。
4. 中断测试：
   - 安装中 Ctrl-C。
   - 证书失败。
   - Nginx reload 失败。
   - Xray restart 失败。
5. 每次失败后检查：
   - 无 80/8443/45231/45232 异常残留监听。
   - systemd 无异常 active 服务。
   - iptables 链清理或回滚。
   - 管理目录无半状态误导。
6. 分别执行 `--uninstall` 后重装，确认可重复安装。

## 5. DD 重装循环

每轮实机测试结束后，重新 DD Debian 12，再重复本清单。只有在干净系统中连续通过首装、错误输入、回滚、节点连通、卸载重装后，才进入下一类优化。
