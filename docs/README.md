# PetDFY 15 Themes — v62 源码候选交付

## 基线
- 素材：`PetDFY_15Themes_DeepseaDefault_AssetBridge.zip`（独立交付，不重复包含在源码 ZIP 中）
- DEB：v61 SettingsAligned（独立交付）
- 源码：v59 逆向重建候选源码，**不是**从 v61 DEB 还原出的完整、可重编译源码。

## 交付内容
- `src/`：现有候选 Objective-C 源码，包含 `WNLiveRig.m` 等。
- `assetbridge/`：从固定素材 ZIP 中提取的注册清单。
- `DEB_control_v61_reference.txt`：实际 v61 DEB 元数据。
- `BASELINE_SHA256.json`：基线文件校验。
- `verify_models.py`：此前的模型检查脚本。

## 实现边界
**当前 v61 DEB 并未真正实现 15 套运行时注册和切换。** 原版动态库未改，`Outfit=maid` 回退尚未解决；`outfitInfo` 生成与渲染刷新未经过真机验证。
**不要直接将此候选源码编译覆盖已安装 DEB。** 尚缺可确认的原版加载入口、完整构建依赖及运行时验证。

## 下一步开发
1. 从 v61 动态库确认偏好读取、服装白名单及模型加载入口。
2. 将 ZIP 中 `winter_deep` 等 15 个 ID 映射到运行时加载器，避免只改设置 plist。
3. 将用户请求状态与实际生效状态分开，失败不得写回 `maid`。
4. 构建模型预加载、切换提交、回滚与渲染刷新，并在设备上逐套验证。
5. 完成 RootHide 编译与安装回归后再标记修复成功。
