# 贡献指南

欢迎提交软件规则、复现问题和行为改进。报告问题时请删除用户名、文件路径、窗口标题、服务启动参数等私人信息。不要直接附上完整本机扫描或会话文件。

## 新增软件识别规则

编辑 `rules/apps.json`，提供：稳定的 `id`、准确的可执行文件名、分类、允许的动作、中文用途及影响说明。在 PR 中附厂商文档或可复核的本地证据，说明测试系统和软件版本。

可用分类：`candidate`、`review`、`keep`、`manual`。`protected`、`unresolved` 由运行时决定。动作只能是内置的 `close`、`terminate`、`service`；安全软件的规则采用 `manual`，通过厂商支持的方式操作。规则不包含脚本、任意命令、远程 URL 或自动批准。

不要把含糊的文件名当作确定用途。例如 Tobii 的 `platform_runtime_RGB_service.exe` 并不能仅凭 RGB 判定为灯效；WebView2、Node 等通用进程需要结合路径及父子关系解释。规则匹配的目的只是建议，不能取代执行前的文件身份校验。

## 验证

运行 `tests/Test-ResearchMode.ps1`，检查 `git diff --check`。PowerShell 源文件保留 UTF-8 BOM 以兼容 Windows PowerShell 5.1。改变执行或恢复逻辑时，增加验证行为的测试；真实服务操作只能在明确授权的隔离环境测试。

提交前确认没有包含 `.researchmode`、`local-data`、报告、批准记录、凭据或真实会话日志。不要为了通过测试降低执行链、PID 启动时间或文件身份校验。
