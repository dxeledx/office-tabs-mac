# Office Tabs

macOS 原生 Office 文档标签栏。将已打开的 Word、Excel 和 PowerPoint 文档放在一排标签中，点击即可切换窗口。源代码采用 MIT 许可证。

## 构建与安装

需要 macOS 13 或更新版本，以及 Xcode Command Line Tools。构建脚本生成当前 Mac 架构的应用；本机已构建并验证的安装包为 Apple Silicon（ARM64）版本。Intel Mac 可在本机从源码构建。

```bash
./scripts/build-app.sh
```

将生成的 `dist/Office Tabs.app` 拖入“应用程序”文件夹，然后打开 `/Applications/Office Tabs.app`。应用在菜单栏运行。

首次运行时，按引导进入“系统设置 → 隐私与安全性 → 辅助功能”，允许 **Office Tabs**。授权后，打开 Office 文档即可显示标签栏。重新构建或移动应用后，如系统未识别授权，可在辅助功能列表中移除该项，再添加安装后的应用。

## 使用

- 点击标签切换文档；关闭按钮交由 Office 处理，未保存文档仍由 Office 提示保存。
- 左侧菜单选择所有文档或只显示某一种 Office 应用。
- 标签栏随前台 Office 应用变色：Word 为蓝色、Excel 为绿色、PowerPoint 为橙色。切换到其他应用时，标签栏自动隐藏。
- 拖动标签调整顺序，顺序保留在本次运行期间；右键标签可关闭文档或在访达中显示文件。
- 标签栏跟随当前 Office 窗口。可在菜单中调整“自动预留顶部空间”；取消“跟随当前文档窗口”后，可拖动标签栏空白处手动定位。
- 通过菜单栏图标显示或隐藏标签栏，也可重新打开权限引导。

标签栏是通过 macOS 公共辅助功能接口定位和切换窗口的独立面板，与 Office 窗口保持分离。它读取窗口标题、文件路径和窗口状态，不读取文档正文；应用没有联网或遥测功能。

## 验证范围

2026-11-03，本机已完成 v0.1.0 的 release 构建、本地签名校验和安装，并验证：

- Word：同时识别两个文档窗口，点击标签可双向切换，当前文档的标签随之高亮。关闭含未保存修改的临时文档时，Word 显示保存确认；取消后，文档和标签均保留。验证结束后，临时空白文档通过“不保存”关闭。
- Excel：空白工作簿显示为标签，可激活窗口并高亮当前标签，也可通过标签关闭空白工作簿。
- PowerPoint：空白演示文稿显示为标签，可激活窗口并高亮当前标签；不同 Office 应用的文档标签可同时列出。
- 跨应用切换与主题：从 Word 标签切换到 PowerPoint 后，整个标签栏由蓝色变为橙色；选择 Excel 文档后，标签栏为绿色。
- 拖动排序：将 PowerPoint 标签拖至 Word 标签前，标签按调整后的顺序显示。
- 显示范围：切换到非 Office 应用后标签栏隐藏，返回 Office 后恢复显示并采用对应的主题色。
- 原生按钮：新增、文档列表、设置和关闭按钮均已通过截图检查；验证用的 Excel 工作簿与 PowerPoint 演示文稿已关闭，PowerPoint 的保存确认和“不保存”关闭流程正常。

全屏 Space 和多显示器行为仍待分别实测。不同 Office 版本暴露的窗口信息可能不同。

## 代码结构

- `Sources/OfficeTabs/Models.swift`：Office 应用及窗口状态。
- `Sources/OfficeTabs/OfficeWindowMonitor.swift`：窗口发现、状态监听与切换。
- `Sources/OfficeTabs/TabBarView.swift`：原生标签栏及交互。
- `scripts/build-app.sh`：构建、打包和本地签名。
- `scripts/make-icon.swift`：可重现的应用图标生成。

辅助功能权限由 macOS 管理。退出后，标签栏停止运行；移除应用即可卸载。
