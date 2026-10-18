---
dev-loop: memory
format: v1
epic: resource-center
total-merged: 0
last-merge: none
---

# resource-center

- [挂载] docs/design/resource-center.md
- [决策] 一期定位 = 本地文件库为主（用户拍板 2026-10-18，方案准入判结构性引入）：goodhub 自身管理文件收/发，纯仓内闭环；一期 text-only，二进制/MCP 聚合/跨 App 传出留二期与 M3
- [结论] 注入正解 = $ref 句柄 + `read_local_resource` 工具按需读（禁全文直灌）；结构落点 `lib/resources/` 新内核域（ResourceStore），UI 经 coordinator 门面（chat_page 第 13 边红线）；与 ref_store 合流不合并（暂存即焚 vs 持久库）
- [红线] 权限走 permission_gateway L2 确认（首读会话豁免）；PII 出站唯一面 = pii_fence，工具执行器不二次遮蔽；管理页禁直连 sandbox/mcp
- [决策] IA 归位（2026-10-19 用户拍板）：资源中心 = **独立页** `lib/ui/resource_center_page.dart`，入口在会话侧边栏底部（紧随「设置」，对齐 TaskLedgerPage 2026-10-18 同款迁移先例）；设置页回退纯配置面（八段，文件头边界声明已同步）。**使用面 = composer（run 级附件）/ 管理面 = 独立页（持久库），二者不再互为前置**；面板级错误行统一收敛于 `components/panel_error_row.dart`（两宿主共用，禁各抄一份）。**入口收口**：composer「+」= 本次会话**统一挂载菜单**（服务绑定 + 附加资源 / 管理资源中心）；附件行按需展开（有待发项才 44dp，空态收 0）——新增挂载类能力一律先进「+」菜单，禁在药丸上再开常驻行。**美学一致性一轮已落地**：自绘 `_ResourceChip` 替 Material `InputChip`（与 `StatusCapsule`/`ContextChip` 同族）；导入钮改 `upload_file_outlined` 与 composer「+」分化；`ui-design.md` §5 补登「底部输入条胶囊 24dp」独立档位（消「全局禁 >16dp」与药丸实现的长期冲突，实现不动）。**判重已落地**（原二期候选，因直选路径提前）：`import()` 返回 `ResourceImportResult` record（`{entry, reused}`），同名加 `(n)` 序号、同内容（sha256 字节级）复用既有条目不落副本；**空哈希永不参与复用**——历史条目不得互判为同内容

## 断点
- [断点] 下一步：**M1 真机验收**（由用户侧载执行，AI 侧代码与测试均已就位）。清单：① 侧边栏 → 资源中心 导入文本/改名/删除/外部打开（唤起系统应用且不露库内 uuid 路径）；② composer「+」→ 附加资源… → 从系统选择… → 发送 → L2 确认卡 → Agent 调 `read_local_resource` 读全文完成任务；③ 大文件附加 → 截断宿主注可见且模型**不重复调用**；④ 管理页 / picker 重进无清单重复；⑤ 同一文件重复直选 → 提示「内容已在资源中心」且**不新增条目**。M1 三件套（T1 内核 / T2 管理段 / T3 注入链）+ IA 归位 + 判重已落地；全量 859 绿、analyze 0 issue、arch-guard + docs-lint 通过，已提交 `948904c`。**真机验收过了才可走 ::done 收敛复盘（升舱 L2→L3）**——验收未完成前本 epic 不收尾、域内待办不清零。
