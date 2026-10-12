# Changelog / 更新记录

## 0.7.1

### English

- The Dock now opens a single main window instead of creating duplicates.
- Added a Quit command to the GH Control app menu and the menu bar icon's right-click menu; ⌘Q also works.
- Full quit asks for confirmation, resends the default 75 W request, and checks the driver's last-set cache. If the driver does not confirm it, the app stays open so the user can retry.
- On launch, GH Control checks for a non-75 W request left by an earlier run and attempts to restore 75 W, including after a crash or forced termination.
- Refined the un-applied sPPT status indicator.
- Rebuilt the drag-to-Applications DMG.

### 中文

- Dock 点击复用单个主窗口，不再重复打开窗口。
- GH Control 应用菜单和菜单栏图标右键菜单增加退出入口；也可按 ⌘Q。
- 完全退出前会弹窗确认，重新发送 75 W 默认请求并核对驱动 last-set 缓存；驱动未确认时，应用保持打开，让用户重试。
- 启动时检查上次运行遗留的非 75 W 请求并尝试恢复，包括上次崩溃或被强制结束的情况。
- 收敛了 sPPT“尚未应用”状态标记的样式。
- 重新生成支持拖入“应用程序”的 DMG 安装包。
