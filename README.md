# Reminder (macOS MVP)

原生 macOS 护眼提醒最小版本（SwiftUI + UserNotifications + AppKit）。

## 功能

- 工作提醒间隔可调：默认 `20` 分钟，范围 `5-120` 分钟
- 休息时长可调：默认 `5` 分钟，范围 `1-60` 分钟
- 支持连续滑杆调节 + `±0.5` 分钟精细调节 + 输入框精确输入
- 首次启动 `.app` 时自动触发 macOS 原生通知授权弹窗
- 使用 macOS 原生通知提醒，并提供通知动作按钮“确定休息”
- 默认策略：系统非全屏时展示全屏提醒（开始休息/稍后 5 分钟），系统全屏时改用通知提醒
- 全屏休息倒计时支持“退出全屏”（仅退出覆盖层，休息计时持续）
- 点击“确定休息”后进入休息倒计时，结束后自动重置为新的工作周期
- 若未点击“确定休息”，每 `5` 分钟重复提醒
- 锁屏时：工作计时暂停；休息计时继续
- GUI 实时显示“工作中 / 等待确认休息 / 休息中”状态
- 状态与配置持久化，重启应用后恢复

## 本地运行

```bash
swift build
swift run Reminder
```

首次运行会请求通知权限。

## 图标资源

图标主稿与导出文件位于 `assets/`：

- `assets/AppIcon-1024.png`（1024x1024）
- `assets/AppIcon-1024@2x.png`（2048x2048）
- `assets/AppIcon.iconset/`（含 `@2x` 各尺寸）
- `assets/AppIcon.icns`（打包使用）

重新生成图标：

```bash
swift scripts/render_app_icon.swift assets/icon_source.png 1024
swift scripts/render_app_icon.swift assets/AppIcon-1024@2x.png 2048
./scripts/generate_icns.sh assets/icon_source.png assets
```

## 自动化测试

```bash
swift test
```

当前已覆盖规则：

- 工作计时（默认值、边界、锁屏暂停）
- 未确认休息时每 5 分钟重复提醒
- 点击“确定休息”后进入休息计时并自动回到工作计时
- 锁屏状态下休息计时继续
- 重启后状态持久化恢复

## 通知后端说明

- `.app` Bundle 运行：使用 `UserNotifications (UNUserNotificationCenter)`（Sequoia 推荐路径）
- `swift run` 开发运行：自动降级为 `NSUserNotificationCenter`，避免无 Bundle 导致的启动崩溃
- “系统是否全屏”当前用前台窗口尺寸启发式判断（与屏幕同尺寸即视为全屏）

## 打包为 .app

```bash
./scripts/package_app.sh
```

默认产物：

- `dist/Reminder.app`

可选自定义参数：

```bash
BUNDLE_ID=com.yourcompany.Reminder APP_VERSION=0.1.1 APP_BUILD=42 ./scripts/package_app.sh
```

## 打包为 .dmg（可下载安装）

```bash
./scripts/package_dmg.sh
```

默认产物：

- `dist/Reminder-v0.1.1-macOS.dmg`

可选自定义参数：

```bash
APP_VERSION=0.1.1 APP_BUILD=2 ./scripts/package_dmg.sh
```
