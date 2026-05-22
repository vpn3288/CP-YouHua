# CP-YouHua

本仓库用于 `install_transit.sh` 与 `install_landing.sh` 的多 AI 循环审查、精简和长期稳定性优化。

当前版本：`v6.16`

开工前必须先读：

- `guides/main_writer_task_guide.md`
- `guides/reviewer_task_guide.md`

当前规范脚本文件名：

- `install_transit.sh`
- `install_landing.sh`

本地静态不变量检查：

- `bash tests/local_static_invariants.sh`

第一轮真实优化已完成文件名规范化，并确认脚本以 LF 换行保存。

每三轮真实优化后，主笔需要提交并推送脚本，同时在 `JiLu.md` 记录三轮真实优化内容。
