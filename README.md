# Office Tabs

为 Mac 上的 Microsoft Word、Excel 和 PowerPoint 提供原生文档标签栏。把打开的文档放在一排标签中，点击即可切换窗口。

[下载最新版本](https://github.com/dxeledx/office-tabs-mac/releases/latest) · [提交问题](https://github.com/dxeledx/office-tabs-mac/issues) · [MIT License](LICENSE)

## 功能

- **一排标签管理文档**：查看已打开的 Office 文档，点击标签切换窗口。
- **跟随 Office 显示**：标签栏随当前窗口移动和缩放，切换到其他应用时自动收起。
- **应用主题色**：Word 蓝色、Excel 绿色、PowerPoint 橙色，并适配系统深色外观。
- **整理文档顺序**：拖动标签排序，按应用筛选，或通过下拉列表查找文档。
- **快捷文档操作**：打开文件、关闭标签、在访达中定位文档；未保存的内容由 Office 提示保存。
- **顶部空间管理**：窗口最大化后自动为标签栏预留空间，保持 Office 标题栏可用。

## 安装

需要 macOS 13 或更新版本，以及 Microsoft Office 桌面应用。

1. 从 [Releases](https://github.com/dxeledx/office-tabs-mac/releases/latest) 下载 Apple Silicon 安装包。
2. 解压，将 `Office Tabs.app` 拖入“应用程序”文件夹并打开。
3. 按首次运行引导，前往“系统设置 → 隐私与安全性 → 辅助功能”，启用 **Office Tabs**。部分 macOS 版本将此项称为“设备控制和数据访问”。
4. 打开 Office 文档，标签栏会随窗口显示。

辅助功能授权用于读取窗口信息，以及切换和关闭文档窗口。Intel Mac 可按下方步骤从源码构建。

## 使用

| 操作 | 方法 |
| --- | --- |
| 切换文档 | 点击对应标签 |
| 调整顺序 | 左右拖动标签 |
| 关闭文档 | 点击标签上的 `×` |
| 筛选应用 | 点击标签栏左侧的应用菜单 |
| 查看文档列表 | 点击右侧的下拉按钮 |
| 打开文件 | 点击 `+` |
| 定位文件 | 右键标签，选择“在访达中显示” |
| 调整显示与布局 | 点击 `…` 或系统菜单栏中的 Office Tabs 图标 |

默认开启“跟随当前文档窗口”和“自动预留顶部空间”。拖动窗口时，标签栏跟随移动；拖到屏幕顶部最大化后，会在鼠标松开、窗口位置稳定后留出顶部空间，再显示标签栏。

需要手动放置时，取消“跟随当前文档窗口”，然后拖动标签栏空白处。“恢复默认位置”可重新启用窗口跟随。进入 macOS 原生全屏后，标签栏会收起，文档仍可通过菜单栏中的列表切换。

## 开发

使用 Swift 和 AppKit 构建，通过 macOS Accessibility API 跟踪和控制 Office 窗口。

安装 Xcode Command Line Tools，使用 Swift 5.9 或更新版本：

```bash
git clone https://github.com/dxeledx/office-tabs-mac.git
cd office-tabs-mac
./scripts/build-app.sh
```

应用生成于 `dist/Office Tabs.app`，构建架构与当前 Mac 一致。将其放入“应用程序”后运行。重新构建后若系统未识别原有授权，可在辅助功能列表中移除 Office Tabs，再添加新构建的应用。

运行窗口布局回归测试：

```bash
./scripts/test-layout.sh
```

### 项目结构

```text
Sources/OfficeTabs/
  AppDelegate.swift          应用生命周期与标签栏布局
  OfficeWindowMonitor.swift 窗口发现、事件监听与几何采样
  TabBarView.swift           标签栏界面与交互
  WindowPlacement.swift     窗口布局计算
scripts/
  build-app.sh              构建与打包
  test-layout.sh            布局回归测试
Tests/
  WindowPlacementTests.swift
```

## 许可证

[MIT](LICENSE)
