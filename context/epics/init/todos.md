---
memo: todos
format: v3
epic: init
---

# init · 域内待办
- [ ] [2026-10-10] (风险) [long] (暂缓) 反向 Server 角色（:8766 对外暴露特权工具）暂缓不做；服务对象澄清：对接桌面 AI 平台（MCP 客户端，如 Claude Desktop/Cursor/ZCode），非其他 MCP server app；若重启反向能力，走「桌面平台先记录待完成 → 宿主批量处理」形态（FC6），非实时直调——触发条件：出现第一个桌面平台需宿主做事的真实场景 (src: 用户, 裁决)
- [ ] [2026-10-11] (风险) [long] goodshare MCP server 生命周期绑 UI 可见性：退后台后 8765 停止监听（进程/前台服务仍活），回前台才恢复——同机回环（goodhub 前台+goodshare 后台）场景致命，T4c 联调期间两度撞上（Connection refused）。修复方向在 goodshare 侧：server 挂前台服务或独立监听保活，须核对 F1.4 双向保活纪律（跨仓，触发条件：下一个真实依赖同机回环的任务） (src: agent, T4c 真机联调)
