<div align="center">

# 轻小说文库 iOS

轻小说文库（wenku8.net）的第三方 iOS 客户端。支持云端书架同步、离线下载、多种数据源与完整的阅读设置。

[![Release](https://img.shields.io/github/v/release/jijijitian/light-novel-library_Wenku8_iOS?label=Release&color=5b8def)](https://github.com/jijijitian/light-novel-library_Wenku8_iOS/releases/latest)
[![iOS](https://img.shields.io/badge/iOS-17.0%2B-333333)](https://github.com/jijijitian/light-novel-library_Wenku8_iOS)
[![License](https://img.shields.io/badge/License-GPL--2.0-2b6cb0)](https://github.com/jijijitian/light-novel-library_Wenku8_iOS/blob/master/LICENSE)

</div>

轻小说文库 iOS 版是一个用 SwiftUI 编写的阅读客户端，界面采用 iOS 26 起的液态玻璃风格，
同时兼容 iOS 17 及以上系统。

本项目参考 [MewX/light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android)
的功能划分与交互结构，为 iOS 平台独立实现。

> 所有小说内容均来自轻小说文库公开网页，版权归原作者与出版机构所有。
> 本项目为非官方、非盈利的第三方客户端，仅供学习交流使用。

## 主要功能

### 书籍浏览

- 首页每日更新：今日热榜、最近更新、新书风云、每周书单
- 13 个排行榜：日、周、月的点击与推荐榜，以及最新入库、字数、完结、动画化等分类
- 按书名或作者搜索，自动保存搜索历史
- 按文库分类逐页浏览

### 阅读器

- 四种配色：纸白、护眼、夜间、跟随系统
- 字号与行距实时调节，无需退出阅读
- 两种翻页方式：上下滑动与左右翻页
- 首行缩进可单独开关
- 章节目录随时跳转，阅读进度自动记录
- 插图支持全屏缩放查看

### 书架与同步

- 与文库账号的书架双向同步，分组与网站保持一致
- 本地收藏的书籍会在同步时上传，不会只留在设备上
- 每本书的阅读进度独立记录

### 离线阅读

- 整本书连同插图下载到本机，无网络时正常阅读
- 支持按卷下载，并在中断后继续
- 断网后书架、封面、简介与目录照常显示
- 在设置中查看缓存占用、按书籍清理

### 数据源

- 默认使用社区维护的中转服务，排行榜与分类可正常访问
- 可关闭中转，仅使用文库网页版
- 混合模式：以中转数据为主，中转获取不到的内容自动从网页版补充
- 站点域名可在 wenku8.net、wenku8.cc、wenku8.com 之间切换

### 界面

- 液态玻璃材质，适配浅色、深色与着色模式
- 原生标签栏与系统返回手势
- 适配 iPad，支持横屏阅读

## 下载

App 未上架 App Store，需自行签名安装。可在 [Releases](https://github.com/jijijitian/light-novel-library_Wenku8_iOS/releases)
页面下载 `.ipa` 文件，或用 Xcode 直接编译到设备。

**设备要求**：iOS 17.0 或更新版本。

## 使用说明

### 安装

任选一种方式签名安装：

- **Xcode**：克隆仓库后执行 `bash tools/bootstrap-xcodeproj.sh device`，用 Xcode 打开工程即可
- **AltStore / SideStore / Sideloadly**：导入 release 中的 `.ipa`，使用自己的 Apple ID 重签
- **企业证书或自签工具**：按惯用方式签名

首次安装后需在 **设置 → 通用 → VPN 与设备管理** 中信任开发者证书。
免费证书有效期为 7 天，到期后重新签名即可。

### 首次使用

打开即可浏览，无需任何配置。

如需同步书架或查看排行榜，请前往 **我的书架 → 登录**，使用文库账号登录。
登录后可同步云端书架、访问需要登录的排行榜，以及按标签浏览书籍。

### 数据源选择

在 **设置 → 数据源** 中切换：

| 模式 | 说明 |
| --- | --- |
| 中转 | 默认。由中转服务提供数据，响应较快，榜单完整 |
| 混合模式 | 同时使用中转与网页版，中转缺失的内容由网页版补充 |
| 关闭中转 | 仅使用文库网页版，排行榜等页面需要登录 |

站点域名通常无需调整，当前不可访问时可切换到其他域名。

## FAQ

### 为什么部分排行榜需要登录？

文库网页版对未登录访客不开放排行榜页面。开启中转服务即可访问，或登录自己的文库账号。

### 为什么个别书籍无法打开？

少数书籍在文库网页版本身就不可读。使用中转服务通常可以解决，App 会在失败时给出明确提示。

### 账号密码会被保存吗？

不会。密码仅在登录时提交给文库，App 不存储密码，登录状态保存在系统 Cookie 中，退出登录时清除。

### 数据来自哪里？

全部内容来自轻小说文库公开网页。本 App 不存储、不转售任何作品内容。

### 支持哪些系统？

iOS 17.0 及以上。液态玻璃效果需要 iOS 26 或更新版本，旧系统会自动使用半透明材质。

## 反馈

使用中遇到问题或有功能建议，欢迎在 [Issues](https://github.com/jijijitian/light-novel-library_Wenku8_iOS/issues) 中提出。

## 致谢

- [MewX/light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android)：功能与交互参考，UI 设计：ZERO
- [celia-sh/Novella](https://github.com/celia-sh/Novella)：封面取色与书籍详情页的配色方案参考

## 许可

本项目基于 [GPL-2.0](https://github.com/jijijitian/light-novel-library_Wenku8_iOS/blob/master/LICENSE) 协议开源，与原始 Android 项目一致。
