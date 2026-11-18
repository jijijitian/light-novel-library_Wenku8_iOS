# 图标

纯色底 + 一个居中的大字，取安卓版一直使用的那一个字：**軽**（Hiragino Sans W7）。

| 文件 | 外观 | 配色 |
| --- | --- | --- |
| `AppIcon.png` | 浅色 | 主色底 + 白色字 |
| `AppIcon-Dark.png` | 深色 | 近黑底 + 主色字 |
| `AppIcon-Tinted.png` | 着色 | 近黑底 + 白色字（灰度，由系统上色） |

三种外观就是 iOS 允许读者为主屏幕图标选择的全部样式（设置 → 主屏幕 → 自定）。
iOS 26 的「透明」玻璃样式没有对应的资源位：系统从默认图标自行派生，`actool` 会静默
忽略 `clear` 条目，所以不需要也无法单独提供。

图标由 `tools/make-icon.swift` 生成，不要手改 PNG：

```bash
swiftc -O tools/make-icon.swift -o /tmp/make-icon
/tmp/make-icon Support/Assets.xcassets/AppIcon.appiconset HiraginoSans-W7 0.70
```
