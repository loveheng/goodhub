---
dev-loop: devlog
format: v1
epic: thirdconnect
total-merged: 1
last-merge: 2026-10-19
---

（开发过程日志按行追加：[变更]/[验证]/[note]/[SSOT 修正]；≥5 条自动归并进 memory.md——dev-loop §2）
- [2026-10-19] [变更]: 归并——devlog 20 条历史（TC1~TC14 决策 / T-trans-1~4 与 T-sdk-1~2 落地 / G1~G5 网关 / 手动验收闭环 / SSE 缓冲与 FGS/Impeller 修复 / 2026-10-15 流内间隙超时改造）提炼入 memory.md；memory 缺失的 5 项（流内间隙改造、SSE 缓冲 bug 与回归钉子、reverseDemo 预期架构认知、thirdconnect.md §9/§10/§11 增补、信任闸门两修复）补入「归并补充」节；断点行更新为当前真实挂起（reverseDemo 宿主推理闭环）
- [2026-10-19] [验证]: context-lint --root 复跑 → thirdconnect MERGE 告警清零（20→0）；memory.md 断点恒 1 行、挂载行恰 1 条、内容未超 150 行软上限
- [2026-10-20] [变更]: 插件 SDK 拆独立仓：新建 loveheng/goodhub-mcp-sdk（:contract 契约唯一物理副本 + :plugin-core SDK + :sample-dummy-plugin 靶子），goodhub 仓移除 android-sdk/ 目录；新增契约防漂移门禁 check-contract-sync（golden 指纹 + 与契约仓逐字节比对），已挂 pre-commit-gate；新增 install-dummy-plugin 脚本（真机 e2e 前置装靶子）
- [2026-10-20] [验证]: 新仓 ./gradlew clean :contract:assembleRelease :plugin-core:assembleRelease :sample-dummy-plugin:assembleDebug test publishToMavenLocal → BUILD SUCCESSFUL；单测 12/12（契约 5 + 派发器 7）；publishToMavenLocal 产出两个 AAR + POM，plugin-core POM 传递依赖 contract；dexdump 核验 AIDL 类唯一落位于 contract AAR、sample APK 内含契约类；goodhub flutter analyze 0 issue + :app:compileDebugKotlin BUILD SUCCESSFUL + check-contract-sync --self-test PASS + pre-commit-gate --self-test PASS；未执行: flutter build apk 全量打包与真机 e2e（靶子 APK 需先经 install-dummy-plugin 装到设备）
- [2026-10-20] [SSOT修正]: TC14 旧「SDK 封装为 goodhub-mcp-plugin-core.aar，落在 goodhub 仓 android-sdk/ 目录」➔ 新「SDK 与契约拆独立仓 loveheng/goodhub-mcp-sdk；契约 SSOT = 该仓 :contract 模块（AIDL + McpContract 常量），goodhub 侧留宿主副本，由 check-contract-sync 机械防漂移」
- [2026-10-20] [变更]: 宿主改用契约坐标（AIDL 物理单副本）：goodhub 删 android/app/src/main/aidl/ 自带副本，android/app 改依赖 com.zzh.goodhub.mcp:goodhub-mcp-contract:0.1.0（复合构建 includeBuild 优先 / mavenLocal 兜底，toolbox run sdk-dep 一键发布）；契约门禁升 v2（禁宿主自拷 AIDL + 坐标版本与契约仓 VERSION 绑定一致，登记见 scripts/agent-tools/contract.lock）；SDK 仓加 GitHub Packages 发布配置（tag 触发 CI 发布 + POM 元数据）与 Dart 业务层接管口子（handleJsonRpc 等 4 个 protected 成员 + 2 单测）
- [2026-10-20] [验证]: flutter analyze 0 issue + flutter build apk --debug BUILD SUCCESSFUL + :app:dependencies 实测 com.zzh.goodhub.mcp:goodhub-mcp-contract:0.1.0 -> project :goodhub-mcp-sdk:contract（复合构建生效）+ check-contract-sync --self-test PASS 与真实校验 OK + docs-lint OK + pre-commit-gate OK + sdk-dep 实测发布成功；SDK 仓 assembleRelease+test+publishToMavenLocal BUILD SUCCESSFUL、单测 14/14（契约 5 + 派发器 9）；未执行: 真机 e2e（靶子 APK 需先经 install-dummy-plugin 装到设备）、GitHub Packages 实际发布（远端仓未创建）
- [2026-10-20] [SSOT修正]: 契约防漂移 旧「宿主侧 AIDL 副本 + golden sha256 逐字节比对」➔ 新「AIDL 契约物理单副本（SDK 仓 :contract），宿主经 Maven 坐标消费；门禁改为校验『无宿主自拷 AIDL + 坐标版本与契约仓 VERSION 绑定一致』」
- [2026-10-20] [变更]: SDK 仓完成远端发布闭环：补 GitHub Packages 发布配置与 tag 触发 CI（tag 版本须与 VERSION 文件一致）、修 CI（去 setup-android 改用 runner 预装 SDK）、新增离线分发件打包 scripts/dist.sh（标准 Maven 目录 + zip，免认证消费）、补 README 消费说明；goodhub 侧加 GitHub Packages 仓库通路（需 GITHUB_TOKEN）作为复合构建/mavenLocal 之外的第三通路
- [2026-10-20] [验证]: SDK 仓远端已建并发布：git tag v0.1.0 推送 → CI 全绿（main run success + tag run 的「构建+单测」「发布到 GitHub Packages」两作业全 success，含 tag 版本与 VERSION 一致性校验）→ 坐标 com.zzh.goodhub.mcp:goodhub-mcp-contract:0.1.0 / goodhub-mcp-plugin-core:0.1.0 已上 GitHub Packages；CI 修 tag 触发条件（push.tags v*）与去 setup-android（改用 runner 预装 SDK，main run 由 failure 转 success）；新增 scripts/dist.sh 离线分发件（dist/maven-repo 40 文件 + zip 50KB，免认证）；第三方消费端到端验证——临时消费者工程仅引 implementation("com.zzh.goodhub.mcp:goodhub-mcp-plugin-core:0.1.0") 即可编译继承 GoodHubPluginService 的插件（api 传递依赖使契约类可见），BUILD SUCCESSFUL；实测 GitHub Packages 的 Maven 端点匿名拉取返 401（强制认证），故补离线分发件与 token 两条通路；goodhub flutter build apk --debug BUILD SUCCESSFUL + check-contract-sync OK
