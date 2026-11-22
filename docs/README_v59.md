# PetDFY v59 — 第五套服装状态一致性（候选源码）

## 本轮实际改动
1. 初始化读取偏好值的 v58 逻辑保留。
2. `pd_selectOutfitModel:` 成功后同步更新 `model`、`outfitInfo` 和 `outfit`；失败时保持现有状态。
3. `pd_resetLiveWithScheme:outfit:freeGround:` 拒绝空服装 ID，不再把空值静默替换成 `maid`。
4. 保留先验证贴图路径、再清理渲染器缓存的现有预检顺序。

## outfitInfo 的证据边界
原版二进制中的 `outfitInfo` 完整生成逻辑**尚未恢复**。本候选源码只读取模型内可选的 `outfitInfo` 字典；不存在时使用空字典，以避免将 `view` 数组错误当作字典。空字典不代表原版正确行为，不能据此保证模型渲染。

## 不应直接部署的原因
这是逆向重建的候选工程，非用户已验证 v56 动态库源码。未编译、未签名、未真机测试；未核实已安装 IPA 的 `live/model.json`。当前也没有可证明修复 `Outfit=maid` 写回的真机时间线。

## 交付判断
**不制作冒充已修复的 DEB**。原版 v56 已安装稳定，继续保留。要做真正可安装修复版，需先得到当前 IPA 资源及 v54 `outfit_timeline.tsv`，并建立可用 iOS/RootHide 编译签名链。
