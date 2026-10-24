---
status: active
updated: 2026-10-14
---

# self-update · 打包推 R2 + 应用内自动更新

> 同款移植自 goodshare 发布体系（整包自更新层）；SU3 拍板（2026-10-14）：仅整包自更新，config 热更（公告/flags）后续按需加。

## 1. 发布侧（打包推 R2）

一键脚本：`bash scripts/release-r2.sh [-n|--dry-run] [--commit]`

流程：读 `pubspec.yaml` 版本（`x.y.z+N`）→ `flutter build apk --release --split-per-abi --target-platform android-arm64 --dart-define=UPDATE_SOURCE_URL=<源>` → sha256 → 生成 `updates/goodhub-update.json` → 零依赖 Node 脚本（AWS SigV4）直传 R2。

前置配置（仓库根 `.env`，参考 `.env.example`，已 gitignore）：

| 变量 | 说明 |
| --- | --- |
| `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | Cloudflare R2 API Token 凭证 |
| `R2_BUCKET` | 桶名，默认 `goodhub-updates` |
| `R2_PUBLIC_DOMAIN` | bucket 绑定的自定义公开域（r2.dev 有限速不作生产源） |
| `REMOTE_PREFIX` | 对象前缀，默认 `updates` |
| `CHANGELOG` | 留空取最近一条 git commit |

产出：`https://<域名>/updates/goodhub-update.json` + `app-release.apk`。构建时 `--dart-define=UPDATE_SOURCE_URL` 把源编进 APK，装上即自带默认更新源。

清单格式：

```json
{
  "versionCode": 2003,
  "versionName": "1.0.1",
  "applicationId": "com.zzh.goodhub",
  "apkUrl": "https://<域>/updates/goodhub/app-release.apk",
  "sha256": "<apk sha256，必填>",
  "changelog": "最近一条 commit 信息"
}
```

> `applicationId` = 串包防御字段（2026-10-14 增）：多 app 共用同一 R2 桶/域名时，客户端拉到清单先比对本机包名，不一致直接拒更。发布侧由 `release-r2.sh` 从 `android/app/build.gradle.kts` 提取写入；旧清单无该字段时客户端宽容跳过。
>
> `versionCode` 口径 = **拆分包 APK 真实 versionCode**（Flutter `--split-per-abi` 自动加 1000×ABI_VERSION，arm64-v8a = +2000），非 pubspec 的 pub build 号。客户端与本机 `PackageInfo.buildNumber` 严格比对，口径错位（写 pub 号）会恒判「无新版」，下载入口不出现（2026-10-24 修复）。

## 2. 客户端侧（应用内自动更新）

| 件 | 落点 | 职责 |
| --- | --- | --- |
| 清单模型 | `lib/update/update_manifest.dart` | `UpdateManifest` 解析 + `isNewerThan`（versionCode 严格大于才提示）；`applicationId` 身份字段（可空，兼容旧清单）；`UpdateException` |
| 更新服务 | `lib/update/update_service.dart` | 源管理（用户手填 > 编译期内置 `kDefaultUpdateSourceUrl`）；清单拉取后包身份校验（清单 `applicationId` vs 本机包名，不一致拒更）；流式下载边下边算 sha256，不匹配即删包报错 |
| 安装器 | `lib/update/installer.dart` | `open_filex` 拉起系统安装器（Android 8+ 首次引导「安装未知应用」授权） |
| 更新页 | `lib/ui/update_page.dart` | 检查/下载（进度条）/安装三态 + 更新源查看修改；安装前二次包身份比对（纵深防御）；入口 = chat_page ⚙ 调试菜单「检查更新」 |

依赖（goodshare 同款，SU2 拍板）：`crypto` / `package_info_plus`（^9.0.1，10.x 与 flutter_secure_storage 的 win32 约束互斥）/ `open_filex`。Manifest 权限：`REQUEST_INSTALL_PACKAGES`。

## 3. 安全纪律

- 清单 `sha256` 必填，客户端强校验；更新源可随时在 App 内改，发现污染立即换源。
- **每 app 独立 `REMOTE_PREFIX`**（goodhub = `updates/goodhub`，shiguang = `updates/shiguang`）：共用桶内各占子目录，杜绝根目录互相覆盖（重）与串包（串）。
- **包身份校验**：清单带 `applicationId`，客户端 check() 拉取即比对，安装前再比对一次；sha256 保字节完整，applicationId 保「是自己的包」，两层缺一不可。
- R2 凭证只存 `.env` / 环境变量，严禁入 git。
