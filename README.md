# GlassScan v1.0 (iOS 26 Liquid Glass)

独立的 **iOS 26 真液态玻璃（Liquid Glass）** 校园生活助手：**胖乖洗澡 + U净洗衣/烘干（含空闲看板与支付宝拉起付款）+ 统一扫码与采样导出**，零第三方依赖，直接走 XcodeGen + GitHub Actions (`macos-26`) 编译出未签名 IPA。

## 核心功能

- **胖乖洗澡（纯云端）**
  - 自动从历史订单与门店附近列表（`appointNew/near/newMachines`）拉取整层/整校淋浴隔间与实时空闲状态，支持收藏常用隔间，**免扫码一键开阀**。
  - 实时出水计时器 + **远程一键停阀结算**（`goods/endWater` → `order/afterPay/creating` → `order/detail`）+ 积分抵扣开关 + 每日签到 + 近期洗澡账单。
- **U净洗衣 / 烘干（纯云端）**
  - **收藏洗衣房空闲看板**：支持关键字搜索与真机 GPS 附近门店搜索，在宿舍即可查看洗衣机 / 烘干机 / 洗鞋机实时空闲数。
  - **扫码下单 → 拉起本机支付宝付款 → 云端启动**：动态渲染服务端洗涤/烘干档位、时长、水温、智能投放；通过原生 SafePay URL Scheme（`glassscan://` 回跳）拉起支付宝收银台，切回前台自动核对支付状态并一键云端启动（`orders/{id}/control/start`），自动注册本地取衣提醒通知。
- **统一液态玻璃扫码 & 调试导出**
  - 全屏 `AVFoundation` 实时取景（手电筒 / 点击对焦 / 双指缩放 / 相册识码），支持「业务直达」与「采样探测」双模式，保留完整脱敏 JSON 导出。
- **真 iOS 26 Liquid Glass**
  - 最低目标 `iOS 26.0`，全屏 `MeshGradient` / 相机光学背景 + `GlassEffectContainer` + `.glassEffect(.regular.interactive(), in: ...)` + `.glassEffectID` + `.buttonStyle(.glass)` / `.glassProminent` + 原生悬浮 `TabView`（`.tabBarMinimizeBehavior(.onScrollDown)`）。
