# 素材导入修复说明（对照 PetDFY_1.2.1_RootHide.deb）

> 只做源码修复与新增，未删除任何既有功能。
> 参考包：`PetDFY_1.2.1_RootHide.deb`（v1.2.1-2，同一套素材包可正常导入并显示角色）

---

## 一、现象

用本工程源码编译出的 deb 安装后：

- 设置 → 下载 → 「从文件导入 ZIP…」，选完文件后**面板抖一下，什么也没发生**；
- 设置页仍显示「素材已移除」；
- 桌面**看不到角色**。

同一份素材包（`PetDFY-1.2-combined-15outfits-116actions.zip`）在 v1.2.1 参考包上导入正常、角色正常显示。

---

## 二、根因（对照参考包逐项对齐后确认）

### 1. 导入依赖 `/usr/bin/unzip`，RootHide 下该路径不存在

旧实现 `PDInstallCombinedArchive()` 用 `posix_spawn` 调 `/usr/bin/unzip`。
RootHide 把越狱内容放在 jbroot（`/.jbroot-XXXX` 或
`/var/containers/Bundle/Application/<UUID>/.jbroot-XXXX`），`/usr/bin/unzip`
这个**绝对路径**并不存在；`PDFindUnzip()` 探不到就直接 `return NO`，
于是「拷贝成功、解压从未发生」——表现正是抖一下、无反应。

参考包 v1.2.1 的 dylib 不依赖外部工具完成素材导入（其字符串表里
`/usr/bin/unzip` 只出现在 App/DEB 安装路径的上下文，不用于素材）。

### 2. 硬编码越狱路径没有走 jbroot

- `PDResourceBundlePath()` 硬编码 `/Library/Application Support/PetDFY.bundle`；
- `WNRenderer` 的 `Whale.metal` 回退也硬编码同一路径。

在 RootHide 上 `mobile` 读写的是系统 `/Library`（不可写、也没有该 bundle），
真身在 jbroot 内。参考包 v1.2.1 的 `postinst` 正是去
`/var/containers/Bundle/Application/.jbroot-*` 做镜像，说明它按 jbroot 约定工作。

### 3. 素材根的选择会被"半成品"目录抢占

旧逻辑在多个候选根里按 `live/model.json` 的 mtime 取最新。
只要某次解压写进了一半（例如只写进了 `originals/`），该目录就会成为
"最新"，被选中当资源根；随后 `WNLiveRig` 读 `live/model.json` 失败直接
`return nil`，`PDPetView` 初始化失败 → `_lastError = @"pet view init failed"`
→ **角色不显示**。

### 4. 导入门槛过严

旧逻辑要求 ZIP 内**同时**含 `live/model.json` 且含 `clips.plist`，
否则整包跳过。纯服装包（无逐帧动作）会被直接忽略。

### 5. 参考包真实的落盘位置

v1.2.1 的 `postinst`：

```sh
bundle="$JB/Library/Application Support/PetDFY.bundle"
for name in originals live .asset-state; do
    chown -hR 501:501 "$bundle/$name"
    chmod 0755 "$bundle/$name"
done
```

说明导入产物应落在 **`PetDFY.bundle` 下的 `originals` / `live` / `.asset-state`**。
本工程原先只往 `Imported/combined/current` 写，两边路径不重合。

---

## 三、修复内容（只增不删）

### 新增文件

| 文件 | 作用 |
|---|---|
| `src/Core/PDJailbreak.h` | 越狱根解析（rootful / `/var/jb` / `.jbroot-*` / `/rootfs`），集中所有业务路径 |
| `src/Core/PDZipExtract.h/.m` | **进程内 ZIP 解压**（zlib），支持 stored/deflate、ZIP64 尺寸、UTF-8/CP437 文件名、路径穿越防护、单顶层目录自动剥离 |
| `src/Core/PDAssetInstaller.h/.m` | 安装编排：扫描投递目录 → 校验结构 → 解压到 staging → 剥离单根 → 双写目标 → 写 `.asset-state` + `AssetDownloadStatus=ready` + Darwin 通知 |
| `package.sh` | 用基础 deb 做骨架、替换 dylib、签名、打包 |
| `docs/FIX-ASSET-IMPORT.md` | 本文 |

### 修改文件

| 文件 | 改动 |
|---|---|
| `Core/PDOverlayController.m` | ① `PDResourceBundlePath()` 改为「越狱根展开 + 结构完整度打分 + mtime 兜底」；② `PDInstallCombinedArchive()` 先走进程内安装器，失败再回退旧的 `unzip` 路径（旧能力保留）；③ 门槛放宽为 `live/model.json` **或** `originals/model.json`；④ 同包已装则直接返回，避免每秒重复解压 |
| `Core/PDFramePlayer.m` | `candidateRoots` 改用统一越狱根解析，并加入素材 bundle 根 |
| `Core/WNRenderer.m` | `Whale.metal` 回退改为遍历 jbroot 展开后的候选 bundle 根（原先硬编码 `/Library/...`） |
| `Core/PDAssetManager.h/.m` | 新增 `- installAssetsIfNeeded`，把参考包的 `install` 语义接上真实安装；**未改动** `advance` 既有状态机 |
| `build.sh` | 链接加 `-lz`（进程内解压依赖 libz） |

### 关键行为

- 安装目标：`<jbroot>/Library/Application Support/PetDFY.bundle`（优先，与参考包一致）
  **+** `Imported/combined/current`（保留 1.2 既有位置），双写兼容。
- 半成品目标不计成功：只有 `assetRootIsComplete:` 通过的目标才算安装成功，
  保证 `PDResourceBundlePath()` 不会选中半写目录。
- 导入后立刻 `discardAssetViews` + 重启悬浮层，无需重启 SpringBoard。

---

## 四、构建与打包

```sh
# 1) 编译（需要 TheosRuntime + iOS16 SDK，路径见 build.sh 顶部）
./build.sh

# 2) 打包：用能正常导入的 1.2.1 deb 做骨架，替换成本次编译的 dylib
./package.sh /path/to/PetDFY_1.2.1_RootHide.deb
# 产物：packages/out/PetDFY_1.2.1_assetimport-fix_iphoneos-arm64e.deb
```

> 本工程不含设置面板源码（`PetDFYPrefs`），所以 `package.sh` 从基础 deb
> 里取 PreferenceBundle / Whale.metal / 素材 bundle 骨架——这也是之前
> 能打出可安装 deb 的做法。

---

## 五、验证步骤（真机）

1. 先卸载旧版、`respring`，安装新 deb。
2. 打开 设置 → 大肥鱼 → 下载，确认「角色素材」状态。
3. 点「从文件导入 ZIP…」，选 `PetDFY-1.2-combined-15outfits-116actions.zip`。
4. 观察 Console 日志（`log stream --predicate 'eventMessage CONTAINS "PetDFY.Import"'`）：
   - 成功：`[PetDFY.Import] installed N files -> <root>`
   - 失败：`extract failed (...)` 或 `no writable install target`
5. 返回主屏幕，角色应出现；设置页状态应变为「素材已就绪」。
6. 双击角色测试逐帧动作（`clips.plist` + `frames/`）。

### 若仍失败，按日志分支

| 日志 | 含义 | 处理 |
|---|---|---|
| `no zip in spool` | 面板没把 ZIP 拷进投递目录 | 检查 `/var/mobile/Library/Application Support/PetDFY/AssetImports` 是否可写 |
| `extract failed (0 files...)` | ZIP 头损坏或非标准 | 用系统「文件」App 重新压缩，确认是 `.zip` 而非 `.7z` |
| `extract failed (N files, err=structure)` | 解压出文件但缺 `originals/` 与模型 | 确认选的是合并素材包，不是单个服装目录 |
| `no writable install target` | bundle 与 data 目录都不可写 | `chown -R 501:501 "<jbroot>/Library/Application Support/PetDFY.bundle"` |

---

## 六、证据边界

- 本次修复基于：参考包的字符串表、`postinst`、`Assets.plist`、本地化文案，
  以及本工程源码的逐行对照（Observed）。
- 参考包 dylib 为 fat Mach-O（arm64 + arm64e），本机 Windows 上的 Ghidra
  不支持 Mach-O，**未能逐指令反汇编**；因此"参考包不依赖外部 unzip"是
  基于字符串/上下文推断（Inferred），非指令级证明。
- 修复后的代码**未在本机编译**（无 iOS SDK / clang），也未真机运行（NOT RUN）。
  已做的静态检查：所有改动文件括号配平通过、`#import` 全部可解析。
