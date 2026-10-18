---
dev-loop: memory
format: v1
epic: resource-center
total-merged: 1
last-merge: 2026-10-19
---

# resource-center

- [挂载] docs/design/resource-center.md
- [决策] 一期定位 = 本地文件库（结构性引入，用户拍板 10-18）：goodhub 自管文件收/发，纯仓内闭环；一期 text-only，二进制 / MCP 聚合 / 跨 App 传出留二期与 M3
- [结论] 注入 = `$ref` 句柄（run 级即焚）+ `read_local_resource` 按需读，禁全文直灌；落点 `lib/resources/` 内核域，UI 经 coordinator 门面（chat_page 第 13 边红线）；与 ref_store 合流不合并
- [决策] **IA 归位（用户拍板 10-19）**：管理面 = 独立页 `ui/resource_center_page.dart`（侧边栏底部紧随「设置」，对齐 TaskLedgerPage 2026-10-18 同款迁移先例）；使用面 = composer「+」统一挂载菜单（服务绑定 + 附加资源… + 管理资源中心…）；设置页回退纯配置面（八段，文件头 scope 边界声明同步）
- [结论] **选择即收集，非先收集才可选**：直选系统文件 → 经 `import` 闸门入库 → 返回 `collected`；消除「先导入才能用」的硬门槛。撤销语义 = 只撤销增量（新入库才给撤销，复用既有条目不给）
- [红线] 权限走 permission_gateway L2（首读会话豁免）；PII 出站唯一面 = pii_fence；管理页禁直连 sandbox/mcp；面板级错误行唯一实现 = `components/panel_error_row.dart`
- [约束] 挂载物生命周期须在 UI 可辨（session 级绑定 / run 级附件 / 应用级持久库），禁让用户凭「都是输入框上面一条」自行推断；新增挂载类能力先进「+」菜单，禁再开常驻行；附件行仅在有待发项时展开
- [约束] 判重两级：同名加 `(n)`（改名产生的同名不同内容走此路）／同内容 sha256 复用不落副本；**空哈希永不参与复用**——早于判重特性落库的历史条目不得互判为同内容

## 断点
- [断点] 下一步：**M1 真机验收**（由用户侧载执行，AI 侧代码与测试均已就位）。清单：① 侧边栏 → 资源中心 导入文本/改名/删除/外部打开（唤起系统应用且不露库内 uuid 路径）；② composer「+」→ 附加资源… → 从系统选择… → 发送 → L2 确认卡 → Agent 调 `read_local_resource` 读全文完成任务；③ 大文件附加 → 截断宿主注可见且模型**不重复调用**；④ 管理页 / picker 重进无清单重复；⑤ 同一文件重复直选 → 提示「内容已在资源中心」且**不新增条目**。**验收过了才可走 ::done 收敛复盘（升舱 L2→L3）**——未完成前本 epic 不收尾、域内待办不清零
