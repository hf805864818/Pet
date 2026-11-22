# PetDFY 大肥鱼〇V〇（素材导入修复版）

iOS 越狱桌面宠物 tweak，仅注入 `com.apple.springboard`。
本仓库为**逆向还原源码 + 素材导入链路修复**，并带 GitHub Actions 自动编译打包 deb。

> 素材（15 套服装 / 116 逐帧动作，约 120 MB）不入库，安装后由用户在设置页导入。

---

## 当前修复（本次提交重点）

**现象**：设置页「从文件导入 ZIP」后无反应，角色不显示；同一素材包在
`PetDFY_1.2.1_RootHide.deb` 上正常。

**根因**

1. 导入依赖 `posix_spawn("/usr/bin/unzip")` —— RootHide 下该绝对路径不存在，静默失败。
2. `/Library/Application Support/PetDFY.bundle` 硬编码，未走 jbroot。
3. 资源根按 mtime 选最新，**半写目录抢占** → 读不到 `live/model.json` → `PDPetView` 初始化失败 → 角色不显示。
4. 导入门槛要求 ZIP 同时含 `live/model.json` + `clips.plist`，纯服装包被跳过。
5. 落盘位置与参考包的真实 bundle 根不重合。

**修复**（只增不删）

| 文件 | 说明 |
|---|---|
| `src/Core/PDJailbreak.h` | 越狱根解析：rootful / `/var/jb` / `.jbroot-*` / `/rootfs` |
| `src/Core/PDZipExtract.h/.m` | 进程内 ZIP 解压（zlib）：stored+deflate、ZIP64、UTF-8/CP437、路径穿越防护、单顶层目录剥离 |
| `src/Core/PDAssetInstaller.h/.m` | 安装编排：扫描→校验→staging→双写→`.asset-state`+状态键+Darwin 通知 |
| `src/Core/PDOverlayController.m` | 资源根结构打分；导入优先进程内安装器，失败回退旧 unzip；门槛放宽；同包去重 |
| `src/Core/PDFramePlayer.m` | 帧根走统一越狱根解析 |
| `src/Core/WNRenderer.m` | `Whale.metal` 回退遍历 jbroot 候选根 |
| `src/Core/PDAssetManager.h/.m` | 新增 `installAssetsIfNeeded`，原 `advance` 状态机未改 |
| `Makefile` | 新增 theos 构建（arm64 + arm64e） |

详见 [`docs/FIX-ASSET-IMPORT.md`](docs/FIX-ASSET-IMPORT.md)。

---

## 仓库结构

```
.
├── .github/workflows/build.yml   CI：theos 编译 + 打包 + 校验 + 上传 deb
├── Makefile                      theos 构建定义
├── control                       deb 元数据
├── PetDFY.plist                  注入过滤器（com.apple.springboard）
├── ci/
│   ├── prepare-layout.sh         从 vendor/base 解出设置面板与 bundle 骨架
│   └── verify-deb.sh             产物校验（架构/过滤器/面板/修复点）
├── src/
│   ├── Entry.m                   MobileSubstrate 构造入口
│   ├── PetDFY.h                  伞形头
│   ├── Core/                     渲染、动画、悬浮层、素材管理
│   └── Sources/                  AI 对话、语音、设备操控、MCP 桥
├── docs/                         逆向报告与修复说明
├── vendor/base/                  参考包（提供 PetDFYPrefs.bundle / Whale.metal 骨架）
├── build.sh / package.sh         设备内构建与手工打包（保留）
└── tools/                        push / watch 脚本（无 git 环境也可推送）
```

---

## 构建

### CI（推荐）

推送到 `main` 或手动触发 `build-deb`：

1. `macos-14` runner
2. `brew install ldid dpkg xz`
3. 克隆 `theos/theos` + `theos/sdks`（iPhoneOS16.x）
4. `ci/prepare-layout.sh` 解出 layout
5. `make package FINALPACKAGE=1 DEBUG=0`
6. `ci/verify-deb.sh` 校验
7. 上传 Artifact `PetDFY-deb`

### 本地（macOS）

```sh
export THEOS=~/theos
cp -R /path/to/sdks/iPhoneOS16.5.sdk "$THEOS/sdks/"
bash ci/prepare-layout.sh
make package FINALPACKAGE=1 DEBUG=0
```

### 设备内（原方式）

```sh
./build.sh     # 需要 TheosRuntime 与 iOS SDK，路径见脚本顶部
./package.sh /path/to/PetDFY_1.2.1_RootHide.deb
```

---

## 安装后验证

1. 卸载旧版并 respring，安装 CI 产出的 deb。
2. 设置 → 大肥鱼 → 下载 → 「从文件导入 ZIP…」，选择合并素材包。
3. 看日志：
   ```sh
   log stream --predicate 'eventMessage CONTAINS "PetDFY.Import"'
   ```
   成功应有 `[PetDFY.Import] installed N files -> <root>`。
4. 回主屏应看到角色；设置页状态应变为「素材已就绪」。

失败分支见 `docs/FIX-ASSET-IMPORT.md` 的日志表。

---

## 许可与边界

- 源码为逆向还原工程，**未经完整真机验收**；`docs/` 内保留了证据边界说明。
- 素材 / 二创形象版权归原作者，**禁止商用**；本仓库不含素材本体。
- `vendor/base/` 内参考包仅用于在 CI 中提供设置面板与 bundle 骨架，便于复现构建。
