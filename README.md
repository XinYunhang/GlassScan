# GlassScan (iOS 26 Liquid Glass)

独立的校园设备二维码扫描与自动接口探测采样 App，专为 **iOS 26 真液态玻璃（Liquid Glass）** 设计，零第三方依赖，直接走 **XcodeGen + GitHub Actions (`macos-26`)** 编译并产出未签名 IPA 本地自签安装。

## 核心能力

- **真 iOS 26 Liquid Glass UI**：最低目标 `iOS 26.0`，全屏实时取景器作为光学折射背景，悬浮 `GlassEffectContainer` + `.glassEffect(.regular.interactive(), in: ...)` + `.glassEffectID` 形变过渡 + 原生 iOS 26 悬浮 `TabView`（`.tabBarMinimizeBehavior(.onScrollDown)`）+ `.buttonStyle(.glass)` / `.glassProminent`。
- **多源扫码**：实时相机扫码（`AVFoundation`，带手电筒、点击对焦、双指缩放、暗光近距对焦优化）、相册图片识码（`Vision`）、剪贴板/手动输入。
- **扫完即查、自动落盘**：
  1. 自动识别平台（胖乖生活 / U净 / 支付宝 / 微信 / 普通网页 / 纯文本）与 URL 参数拆解；
  2. 自动对比历史记录，即时判断**静态贴纸码 vs 动态码**；
  3. 自动执行只读 HTTP GET 探测（记录每一跳重定向 `Location`、状态码、关键头与响应体预览）；
  4. 配置 U净 JWT 后，自动串联调用 `devices/scanWasherCode` + `app/washer/devices/program/info` 保存完整设备与档位 JSON；
  5. 配置胖乖 Token 后，自动试查 `goods/normal/details` + `goods/normal/skus`，并支持一键同步历史订单（`order/list`）和最近设备（`goods/latestUsed`）。
- **一键脱敏导出**：支持一键复制脱敏 JSON 或通过系统 `ShareLink` 导出 `.json` 文件，自动将手机号、JWT、Token、Authorization 等凭据替换为 `***`；所有登录凭据仅存于本机 Keychain（`ThisDeviceOnly`）。

## 构建与出包（无 Mac）

1. 推送到 GitHub 仓库后会自动触发 `.github/workflows/compile.yml`（`macos-26` + Xcode 26 编译检查）。
2. 编译通过后，手动触发 `.github/workflows/unsigned-ipa.yml` 获取 `GlassScan-unsigned.ipa`，使用 SideStore / AltStore 自签安装到 iOS 26 设备。
