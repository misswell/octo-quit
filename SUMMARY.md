# OctoPilot 开发总结

本文档总结近期 OctoPilot 的主要开发工作，涵盖新功能、界面与性能优化、可分发构建及发布流程。

## 一、BLE 解锁功能

在原有「退出规则 / 启动规则」基础上，新增 BLE 解锁功能：根据蓝牙低功耗（BLE）设备的接近程度自动锁定和解锁 Mac。

核心实现位于 `Sources/OctoPilot/BLEUnlock.swift`，主要能力包括：

- **设备扫描与选择**：扫描附近 BLE 设备，解析 MAC 地址与名称（蓝牙偏好 plist + 系统蓝牙数据库 + Apple 设备型号表），按信号强度排序展示。
- **接近判定**：基于 RSSI 滑动均值（最近 5 次）与双阈值（解锁 RSSI / 锁定 RSSI，均可独立禁用），配合「锁定延迟」与「无信号超时」两个计时器。
- **锁屏与解锁**：登录密码安全存入钥匙串；锁屏时模拟键盘输入解锁；支持「用屏幕保护程序锁定」「锁定时关闭屏幕」「接近时唤醒」「唤醒但不解锁」。
- **活动 / 被动模式**：默认主动连接设备读取 RSSI（更稳定）；可切换被动模式仅靠扫描，避免与其他蓝牙设备相互干扰。
- **媒体控制**：锁屏时暂停「正在播放」，解锁后恢复（运行时加载系统媒体框架，失败则降级）。
- **事件脚本**：锁/解锁时可运行 `~/Library/Application Scripts/com.misswell.octopilot/event`，参数 `away` / `lost` / `unlocked` / `intruded`。
- **屏幕状态观察**：显示器睡眠/唤醒、系统睡眠/唤醒、屏保、解锁等系统事件。

入口：
- 主窗口侧边栏「BLE 解锁」板块（完整配置）
- 菜单栏菜单（启用、立即锁定、选择设备、管理）

设置随 `~/Library/Application Support/OctoPilot/config.json` 持久化（配置版本升至 5），中英双语。

## 二、界面设计

BLE 板块采用独立的视觉语言，区别于普通列表：

- **圆形信号仪表盘**：标题旁圆环显示实时 RSSI，按强度绿/黄/红变色，中心显示数值与接近状态。
- **信号强度条**：设备列表每项用 4 格信号条直观展示强弱。
- **RSSI 范围条**：阈值区用水平条可视化——绿色解锁区、红色锁定区、黑色竖线标记当前位置。
- **卡片化分组**：触发阈值 / 时间参数 / 行为选项 / 密码与锁定 各成卡片。
- **彩色状态点**：启用卡片用圆点 + 文字表示蓝牙、接近、未检测等状态。
- **密码状态徽标**：用图标显示密码已保存 / 未设置。

## 三、性能优化

针对办公室等设备密集场景，解决扫描列表卡顿与顺序跳动：

- **刷新合并**：设备列表发布最多每 200ms 一次，突发广播不再逐条刷新主线程。
- **设备上限**：候选列表最多 100 台，优先保留信号强的设备。
- **单一清理定时器**：用一个 5 秒定时器清理失联设备，替代为每台设备反复创建 Timer。
- **名称解析缓存**：设备名称/MAC 只解析一次，避免重复读盘。
- **稳定排序**：默认按加载顺序（首次发现时间）显示，不再因 RSSI 实时变化而跳动。
- **排序选择器**：提供「加载顺序 / 名称 / 信号」三种排序切换。
- **懒加载列表**：使用 `LazyVStack` 渲染设备行。

回归测试：`Tests/OctoPilotTests/BLEUnlockPerformanceTests.swift` 验证突发刷新被合并为一次发布。

## 四、Bug 修复

- **菜单栏设备入口无反应**：原 SwiftUI 子菜单无法可靠触发扫描，改为点击直接打开主窗口 BLE 板块选择设备。
- **权限弹窗叠加**：启用 BLE 时不再同时弹出辅助功能系统窗 + 应用内提示 + 蓝牙窗；拆分到不同用户动作，蓝牙权限推迟到扫描时。
- **BLE 辅助功能重置**：BLE 提示新增「重置权限并退出」按钮，与退出规则板块一致，调用 `tccutil reset Accessibility` 并退出。

## 五、可分发构建

从 ad-hoc 签名升级为 Apple 公证的可分发应用：

- `Resources/OctoPilot.entitlements`：Hardened Runtime 所需权限。
- `Scripts/build-app.sh`：检测到 `OCTOPILOT_DEVELOPER_ID` 时用 Developer ID + Hardened Runtime 签名，否则回退 ad-hoc。
- `Scripts/distribute-app.sh`：一键签名 → 提交 Apple 公证 → 装订票据 → 打 zip → Gatekeeper 校验；支持钥匙串公证 profile（不接触明文密码）。
- `.github/workflows/build.yml`：日常 push/PR 走 ad-hoc artifact；打 `v*` tag 自动签名+公证+发 Release（需配 6 个 Apple secrets）。
- 签名身份：`Developer ID Application: Guofeng Liu (U8U443D7ZL)`，公证凭证存于钥匙串 profile `OctoPilot`。

发布新版本的本地命令：

```sh
OCTOPILOT_DEVELOPER_ID="Developer ID Application: Guofeng Liu (U8U443D7ZL)" \
OCTOPILOT_NOTARY_PROFILE="OctoPilot" \
./Scripts/distribute-app.sh
```

## 六、发布记录

- 清理了 GitHub 上所有历史版本（v1.0.0 ~ v1.1.0，共 25 个 release 及对应 tag）。
- 重新发布 **v1.1.1**：https://github.com/misswell/OctoPilot/releases/tag/v1.1.1
  - 已签名 + Apple 公证 + Hardened Runtime
  - 产物：`OctoPilot-1.1.1-macos.zip`，双击运行无 Gatekeeper 拦截

## 七、分发方式说明

OctoPilot 依赖辅助功能、系统蓝牙文件、媒体框架、模拟键盘等深度系统能力，采用 **Developer ID 公证分发**（非 App Store）。这种方式适合此类系统工具，用户下载 zip 解压即可运行。App Store 因强制沙盒、禁止私有 API、禁止读系统文件等限制，不适用于当前功能形态。

## 八、测试

`swift test` 共 9 个测试通过，覆盖启动规则编解码、辅助功能重置、本地化、版本格式，以及 BLE 设备列表刷新合并的回归测试。

## 九、后续可选改进

- 配置 GitHub 仓库的 6 个 Apple secrets，让打 tag 自动公证发版。
- 备份 Developer ID 私钥到安全位置（当前在 `/tmp`，重启会清空）。
- 考虑为 BLE 设备名解析增加更友好的兜底（系统蓝牙数据库不可读时的提示）。

## 十、发版运维经验（2026-07-21，v1.1.4）

推送 `v1.1.4` tag 触发 `dist` job 后 49 分钟仍 `queued`、Release 迟迟不出。诊断与教训：

- 用 `gh api repos/misswell/OctoPilot/actions/jobs/<job_id> --jq '{s:.status,c:.conclusion,steps:[.steps[]|{name:.name,s:.status,c:.conclusion}]}'` 拿 job 级状态；`gh run view --job` 不显示 step 状态，不可用。
- `job_status=queued` + `steps=[]` = **runner 在排队等 macOS runner，不是构建失败**；同日 GitHub API 还 503，属平台抖动。
- tag push 时 `build` job `conclusion=skipped` 是 `.github/workflows/build.yml` 里 `if: !startsWith(github.ref,'refs/tags/v')` 的正常跳过。
- 应对：① 等 runner 分配；② `gh run cancel <run_id> -R misswell/OctoPilot` 后重推 tag / `gh run rerun`，有时更快；③ 本机 `./Scripts/distribute-app.sh` 打包+公证再 `gh release create v1.1.4 OctoPilot-1.1.4-macos.zip` 手动上传，绕开 CI（需本地 `OCTOPILOT_DEVELOPER_ID` 等凭证）。

结论：macOS runner 排队是发版「卡住」高频原因，别误判为构建失败；先查 job status 再下结论。（本节为 OctoPilot 项目级发版记录。）
