# 来源说明

本项目的“系统调优与维护”功能整合自：

- 项目：`onelxw/vpsgood`
- 地址：https://github.com/onelxw/vpsgood
- 整合版本：`10.3.0-personal`

`vpsgood` 中记录的初始功能思路和部分交互流程来源于：

- 项目：`BeacherZ/vps99.sh`
- 地址：https://github.com/BeacherZ/vps99.sh
- 审计和参考提交：`cce023145611f221967d67039207fcc01b245b49`
- 参考脚本 SHA-256：`475effdcb9e432085468b94ddc45a94f3e8ad01727acaf5cac8d7ae9b36ab66a`

XanMod + BBRv3 功能需求参考了 `Eric86777/vps-tcp-tune`（参考提交 `573c66da82561cefc0f00d872d2954b17227a395`），但没有复制其多功能脚本代码。这里只按 XanMod 官方 APT 流程实现内核安装、环境检查和失败处理；代理部署、DNS 修改、测速等功能没有引入。

截至参考时点，`BeacherZ/vps99.sh` 仓库中没有发现明确的 `LICENSE` 文件。没有明确许可证通常不等于允许任意复制和公开再分发。因此：

- 私有、自用前仍应自行评估适用法律和平台条款。
- 公开发布前建议先取得原作者许可，或确认最终代码已经构成不复制受保护表达的独立实现。
- 不应擅自为原作者代码补充 MIT、GPL 等许可证。

本说明用于保留来源记录，不表示相关原作者认可或维护本项目。
