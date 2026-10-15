---
memo: todos
format: v2
---

# 待办列表

## misc

- [ ] [2026-10-13] (清理) [short] 存量 analyze info：lib/ui/gateway_loop_debug_page.dart:670 deprecated_member_use（'value'→'initialValue'，Flutter 3.33 弃用）——行号自 :635 漂移（2026-10-15 对账修正）；非 M4 范围，散修轮顺手清 (src: agent)
- [ ] [2026-10-11] (测试) [short] T5 拦截卡三态真机验证（M2-T7 余量）：goodhub 盾牌页开「遮蔽失败注入」→ 出 Amber 卡 → 「取消」=轨道✕请求未外发；再跑点「明文发送一次」=请求真外发。fail-closed 态单测已盖 (src: agent)
- [ ] [2026-10-11] (风险) [long] architecture §16 门槛校准待拍板（M2-T7 余量）：现网包实为 qwen25-1.5b-Q8（1.49GB 文件）全载增量 ~1.9GB/峰值 PSS 2.70GB——a) 可用门槛起调 ≥3.5GB（Q8 口径）b) 换发 INT4 包（内存减半，维持 2.5GB）c) 双档按设备选包（M3）。定案前 Q8 维持现网 (src: agent, T7 实测)
- [ ] [2026-10-10] (风险) [long] (暂缓) 反向 Server 角色（:8766 对外暴露特权工具）暂缓不做；服务对象=桌面 AI 平台（MCP 客户端）；若重启走「桌面平台先记录待完成 → 宿主批量处理」形态（FC6），非实时直调——触发条件：出现第一个桌面平台需宿主做事的真实场景 (src: 用户, 裁决)
- [ ] [2026-10-11] (风险) [long] goodshare MCP server 监听与 activity 生命周期耦合（T7 机制定案）：后台 stopped 态保活 16min+ 无恙；死因唯一=activity 销毁（BACK/系统清任务连带走 Dart VM），am start 可能复用残态 activity 不恢复——恢复唯一可靠路径=force-stop 冷启动或划掉任务卡；处置=不改 goodshare 代码，联调起手式=核对开关+listening+冷启动，M3 真实场景高频复现再评估跨仓硬化 (src: agent, T4c+T7 实测定案)

- [ ] [2026-10-11] (测试) [short] T5 拦截卡三态真机验证（M2-T7 余量）：goodhub 盾牌页开「遮蔽失败注入」→ 出 Amber 卡 → 「取消」=轨道✕请求未外发；再跑点「明文发送一次」=请求真外发。fail-closed 态单测已盖 (src: agent)
- [ ] [2026-10-11] (风险) [long] architecture §16 门槛校准待拍板（M2-T7 余量）：现网包实为 qwen25-1.5b-Q8（1.49GB 文件）全载增量 ~1.9GB/峰值 PSS 2.70GB——a) 可用门槛起调 ≥3.5GB（Q8 口径）b) 换发 INT4 包（内存减半，维持 2.5GB）c) 双档按设备选包（M3）。定案前 Q8 维持现网 (src: agent, T7 实测)
- [ ] [2026-10-10] (风险) [long] (暂缓) 反向 Server 角色（:8766 对外暴露特权工具）暂缓不做；服务对象=桌面 AI 平台（MCP 客户端）；若重启走「桌面平台先记录待完成 → 宿主批量处理」形态（FC6），非实时直调——触发条件：出现第一个桌面平台需宿主做事的真实场景 (src: 用户, 裁决)
- [ ] [2026-10-11] (风险) [long] goodshare MCP server 监听与 activity 生命周期耦合（T7 机制定案）：后台 stopped 态保活 16min+ 无恙；死因唯一=activity 销毁（BACK/系统清任务连带走 Dart VM），am start 可能复用残态 activity 不恢复——恢复唯一可靠路径=force-stop 冷启动或划掉任务卡；处置=不改 goodshare 代码，联调起手式=核对开关+listening+冷启动，M3 真实场景高频复现再评估跨仓硬化 (src: agent, T4c+T7 实测定案)
