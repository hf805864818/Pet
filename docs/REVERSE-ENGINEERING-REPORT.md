# PetDFY 逆向分析报告

> 对象：`逆向小肥鱼.zip`（32 MB，1074 个文件）+ `PetDFY_1.2_dafeiyuOVO_iphoneos-arm64e.deb`（1.9 MB）
> 方法：ZIP 解包（GBK 文件名修复）+ deb ar 解包 + Mach-O fat 头解析 + 字符串提取 + plist 解析
> 状态：Observed（直接观测）/ Inferred（推导，标链）/ Assumed（假设，带验证动作）

## 1. 输入物总览

| 项 | 内容 |
|---|---|
| ZIP | 1074 文件：801 PNG + 132 `.m` + 114 `.h` + 13 JSON + 6 MD + 4 deb + 2 TXT + 2 PY |
| deb 1 | `PetDFY_1.2_dafeiyuOVO_iphoneos-arm64e.deb`（v1.2，主包） |
| deb 2 | `大肥鱼〇V〇安全版回退包.deb`（v0.0.1，回退包，dylib 与 deb1 相同 SHA256） |

两个 deb 内的 `PetDFY.dylib` **SHA256 完全相同**：
`D87EDD09AF3EF1CAAECFE22193B4AE61CC91BDFA7A189EE56BCCCEE27E2F8A42`

## 2. deb 结构

### 2.1 deb 1（v1.2）

```
debian-binary (2.0)
control.tar.gz  → control, postinst
data.tar.lzma  → 45 entries
```

**control**：
- Package: `com.ojbkclub.petdfy`
- Name: 大肥鱼〇V〇
- Section: Tweaks
- Depends: mobilesubstrate, preferenceloader, firmware (>= 16.0)
- Architecture: iphoneos-arm64e
- Version: 1.2, Installed-Size: 8900

**data 树**：
```
Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib    ← 核心 tweak
Library/MobileSubstrate/DynamicLibraries/PetDFY.plist     ← 过滤器：com.apple.springboard
Library/PreferenceLoader/Preferences/PetDFYPrefs.plist
Library/PreferenceBundles/PetDFYPrefs.bundle/            ← 设置 bundle
    Info.plist (com.susudear.petdfyprefs, NSPrincipalClass=PDRootListController)
    Root.plist / Provider.plist / DeviceControl.plist / Speech.plist / Assets.plist
    en/zh-Hans/zh-Hant Localizable.strings
    icon.png / icon@2x.png / icon@3x.png / PetDFYHeaderIcon.png
Library/Application Support/PetDFY.bundle/               ← 素材 bundle
    Info.plist (com.susudear.petdfy.assets)
    Whale.metal                                          ← Metal 着色器
    asset-manifest.json (484 PNG + sha256)
    asset-spec.json (asset_version=2fe80e3eb2385c84)
    .asset-state
    originals/  live/  en/zh-Hans/zh-Hant Localizable.strings
Library/Application Support/PetDFY/petdfy-voice
```

### 2.2 deb 2（v0.0.1 回退包）

在 deb 1 基础上额外包含：
- `usr/bin/petdfy-v61-audit`（只读审计脚本）
- `usr/local/bin/petdfy-assetbridge-check`（只读预检脚本）
- `usr/share/petdfy-assetbridge/manifest.example.json`（素材索引示例）
- `PetDFYPrefs.bundle/RepoIcon.png`
- control 版本改为 `0.0.1`，描述为"安全版回退包"

## 3. PetDFY.dylib 分析

### 3.1 Mach-O 结构（Observed）

- **格式**：fat Mach-O（`0xCAFEBABE`），2 个 slice
  - arch[0]: arm64（cputype `0x100000c`，subtype `0x0`），offset `0x40000`，size `0x12cdd0`
  - arch[1]: arm64e（cputype `0x100000c`，subtype `0x80000002`），offset `0x1340000`，size `0x134fe0`
- **filetype**：`0x6`（MH_DYLIB）
- **ID_DYLIB**：`/.jbroot/Library/MobileSubstrate/DynamicLibraries/PetDFY.dylib`
- **UUID**：无（已 strip）
- **Encryption**：无
- **符号表**：无（LC_SYMTAB / LC_DYSYMTAB 均缺失，已 strip）
- **ObjC 运行时段**：旧式（`__objc_methlist` / `__objc_stubs` / `__objc_classrefs` / `__objc_selrefs` / `__objc_const`）
- **加载的 dylib**：无外部依赖（纯 Foundation/UIKit/MetalKit 系统框架，通过框架导入）

### 3.2 类清单（Observed，51 个）

从 `__objc_classrefs` 与字符串表提取，与 `src/` 源码骨架完全一致：

**Core（渲染/动画/绘制，20 类）**
WNClip, WNGlowSurface, WNHitMask, WNLiveRig, WNMesh, WNMotion, WNPainter, WNPreparedDeformer, WNRenderer, WNSpring, WNUploadSurface

**Core（视图/控制器/管理，10 类）**
PDActiveInterfaceOrientationMonitor, PDAssetManager, PDHostRootView, PDInteractionView, PDLocalizationBundle, PDOverlayController, PDPetView, PDPreferences, PDRootController, PDSoundPlayer, PDWindow

**Sources（AI/对话/语音，10 类）**
PDAIAlarms, PDAIMemory, PDAIPetRuntime, PDChatController, PDChatPassthroughView, PDChatService, PDCloudVoiceInput, PDComposerTextView, PDDoubaoSSEDecoder, PDDoubaoTTS

**Sources（设备操控/MCP，13 类）**
PDDeviceAXScope, PDDeviceNativeExecutor, PDDeviceTools, PDKeyboardMonitor, PDNative_AccessibilityManager, PDNative_AppManager, PDNative_ClipboardManager, PDNative_IOSMCPHIDManager, PDNative_MCPAXAttributeBridge, PDNative_MCPAXNodeSource, PDNative_MCPAXQueryContext, PDNative_MCPAXRemoteContextResolver, PDNative_MCPLogger, PDNative_MCPUIElementSerializer, PDNative_MCPUIElementsFacade, PDNative_ScreenGeometry, PDNative_ScreenManager, PDNative_TextInputManager

**Sources（语音/对话 UI，6 类）**
PDReplySpeech, PDSpeechBubbleView, PDVoice, PDVoiceServiceConnection, PDVoiceTextReveal

### 3.3 字符串证据（Observed）

从 dylib 提取 7673 条唯一字符串（7398 ASCII + 275 UTF-16）。关键证据：
- 偏好域：`com.susudear.petdfyprefs`
- 素材域：`com.susudear.petdfy.assets`
- 注入过滤器：`com.apple.springboard`
- AI 默认端点：`https://api.openai.com/v1`
- AI 默认模型：`gpt-4o-mini`
- 豆包音色默认：`zh_female_xiaohe_uranus_bigtts`
- 素材下载 URL 占位符：`placeholder`
- 15 套服装 ID 与 8 套配色方案 ID 均出现在字符串表

### 3.4 方法签名

`__objc_methlist` 段含 833 条方法记录（24 B/条：SEL + types + IMP）。
`__objc_selrefs` 段含选择器引用。源码骨架 `src/` 的 `.h` 文件已按此还原全部方法签名。

## 4. 偏好设置结构（Observed，从 Root.plist 等）

### 4.1 Root.plist（主设置）

| 键 | 默认 | 说明 |
|---|---|---|
| Enabled | YES | 启用大肥鱼 |
| Interactive | YES | 允许触摸互动 |
| InputMode | grab | 单击手势：grab/stroke |
| DoubleTapAction | none | 双击：none/voice/chat |
| LongPressAction | menu | 长按：menu/voice/chat/none |
| Scheme | deepseek | 配色：deepseek/harness/chatgpt/claude/gemini/qwen/kimi/minimax |
| Outfit | maid | 服装：maid/cape/crew/sailor/miko/dragon/nurse/winter_deep/... |
| ChatReturnKeyAction | newline | 回车键：newline/send |
| Responsive | YES | 响应式 |
| FPS | 60 | 帧率：30/60/120 |
| Sound | YES | 动作音效 |
| KeyboardAvoidanceEnabled | YES | 键盘避让 |
| KeyboardAvoidanceExtra | (0,0) | 键盘避让额外偏移 |

### 4.2 Provider.plist（AI 供应商）

| 键 | 默认 | 说明 |
|---|---|---|
| AIBaseURL | https://api.openai.com/v1 | AI 服务端点 |
| AIModel | gpt-4o-mini | 模型 |
| AIUserName | (空) | 用户名 |
| AIContextTokens | 128000 | 上下文 token 上限 |
| AIThinking | off | 思考模式：off/minimal/low/medium/high/xhigh/max |
| AIReasoningEffort | off | 推理强度 |
| AITemperature | 0.7 | 温度 |
| AIMaxTokens | (空) | 最大 token |
| AIEndpointPath | /responses /chat/completions | 端点路径 |
| AIExtraHeaders | {"Header-Name":"value"} | 额外请求头 |
| AIExtraBody | {} | 额外请求体 |
| AIEnabled | YES | AI 总开关 |
| AITouchEnabled | YES | AI 触摸唤醒 |
| AITouchWakeOn | all | 唤醒方式：poke/pet/throw/drop/all/custom |
| AISelf_* | 各项 | AI 自主行为参数（figure/scheme/roam/snore/sound/scale/bubbleSize/fontSize/theme/hoverButtons/user） |

### 4.3 DeviceControl.plist（设备操控）

总开关 `DeviceControlEnabled`（默认 YES），24 个工具开关：
`DeviceTool_get_screen_info / screenshot / get_ui_elements / get_element_at_point / describe_screen / tap_screen / swipe_screen / long_press / double_tap / drag_and_drop / tap_element / wait_for_element / wait_for_disappear / input_text / type_text / press_key / get_clipboard / set_clipboard / launch_app / kill_app / list_apps / list_running_apps / get_frontmost_app / get_app_info / open_url`

### 4.4 Speech.plist（对话声音）

| 键 | 说明 |
|---|---|
| AIChatSound | YES | 对话音效开关 |
| AISpeechMode | native/doubao | 原生 / 豆包 |
| AIDoubaoSpeaker | zh_female_xiaohe_uranus_bigtts | 豆包音色码 |
| AIDoubaoPitch | -12~+12 | 音调 |
| AIDoubaoSpeechRate | 50%~200% | 语速 |
| AIDoubaoLoudnessRate | 50%~200% | 音量 |

## 5. 素材结构（Observed）

### 5.1 THEMES.json
15 套服装主题，默认 `winter_deep`（深海冬雪）。`originals_kept` 保留 maid/cape/crew/sailor 四套原版。

### 5.2 assetbridge/manifest.json
AssetBridge v2，15 套服装索引（id/name/model/index），默认 `maid`。

### 5.3 originals/model.json
骨骼/网格/变形器模型定义，含 `parts`（部件列表）与 `deformers`（变形器字典）。

### 5.4 asset-manifest.json
484 张 PNG 的路径 + 字节数 + sha256 清单，`upstream_commit=dc10274f12c1605903a878502e9b0e72a4f0a055`。

### 5.5 asset-spec.json
素材版本 `2fe80e3eb2385c84`，文件 `PetDFY-assets-2fe80e3eb2385c84.zip`，16 MB。

## 6. 源码骨架性质（Inferred + Assumed）

`src/` 为**逆向还原骨架**，非原版源码：
- `PetDFY.h` 明确标注："由 Mach-O 元数据生成：类/父类/ivar/方法签名/属性均为真实结构，方法体为空实现，仅供编译与结构验证"
- 各 `.m` 文件头部标注还原依据（如 `PDPreferences.m` 标注"二进制实测 0x42d04 (612 B) 逐条重写"）
- 部分方法体为等价实现（如偏好读写走 CFPreferences），部分为存根
- **未编译、未签名、未真机测试**（`v59_checks.json` 中 `compiled: false, runtime_test: false`）

### 关键未验证项（Assumed）
- `outfitInfo` 完整生成逻辑**尚未恢复**——源码只读取模型内可选的 `outfitInfo` 字典，不存在时用空字典
- 15 套运行时注册与切换**未真正实现**——原版 dylib 未改，`Outfit=maid` 回退未解决
- 构建依赖（theos 工具链版本、签名证书）未验证

## 7. 验证动作清单

| 项 | 状态 | 验证动作 |
|---|---|---|
| deb 结构 | Observed | ar 解包 + tar 解包，已执行 |
| dylib 类清单 | Observed | fat Mach-O 解析 + 字符串提取，已执行 |
| dylib 方法签名 | Observed | `__objc_methlist` 解析，已执行 |
| 偏好键值 | Observed | plistlib 解析 Root/Provider/DeviceControl/Speech/Assets，已执行 |
| 素材清单 | Observed | JSON 解析 + 文件计数，已执行 |
| 源码编译 | NOT RUN | 需 theos + iOS SDK 16.0+，未执行 |
| 真机运行 | NOT RUN | 需越狱设备，未执行 |
| outfitInfo 完整还原 | NOT RUN | 需进一步反汇编 WNLiveRig/WNRenderer 方法体 |
| 15 套运行时切换 | NOT RUN | 需真机验证运行时加载器 |

## 8. 结论

本交付包含从 `逆向小肥鱼.zip` 与 deb 包逆向还原的**完整项目源码树**：
- `src/`：51 个类的 Objective-C 骨架（签名真实，方法体等价/存根）
- `assets/`：15 套服装 + 8 套配色 + deepsea-winter-prototype 补丁的全部贴图与 JSON
- `deb-runtime/`：deb 内全部运行时资源（plists / 本地化 / Metal 着色器 / 脚本 / 参考 dylib）
- `build/`：theos 构建文件（Makefile / control / entitlements / 过滤器 / Info.plist）
- `docs/`：原始交付文档 + 本逆向报告

源码骨架与 dylib 类清单**完全一致**，但**不是可直接编译部署的原版源码**——方法体为逆向等价实现，关键运行时逻辑（outfitInfo 生成、15 套切换）尚未完全恢复，需在真机环境进一步验证。
