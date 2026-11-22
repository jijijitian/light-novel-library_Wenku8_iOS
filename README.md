<div align="center">

# 轻小说文库 iOS

轻小说文库（wenku8.net）的第三方 iOS 客户端。支持云端书架同步、离线下载、标签浏览与完整的阅读设置。

[![Release](https://img.shields.io/github/v/release/jijijitian/wenku8-reader?label=Release&color=5b8def)](https://github.com/jijijitian/wenku8-reader/releases/latest)
[![iOS](https://img.shields.io/badge/iOS-17.0%2B-333333)](https://github.com/jijijitian/wenku8-reader)
[![License](https://img.shields.io/badge/License-GPL--2.0-2b6cb0)](https://github.com/jijijitian/wenku8-reader/blob/master/LICENSE)

</div>

轻小说文库 iOS 版是一个用 SwiftUI 编写的阅读客户端，界面采用 iOS 26 起的液态玻璃风格，
同时兼容 iOS 17 及以上系统。

本项目参考 [MewX/light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android)
的功能划分与交互结构，为 iOS 平台独立实现。

> 所有小说内容均来自轻小说文库公开网页，版权归原作者与出版机构所有。
> 本项目为非官方、非盈利的第三方客户端，仅供学习交流使用。

## 主要功能

### 首页与探索

- 首页每日更新：今日热榜、最近更新、新书风云、每周书单
- 探索页整合站点首页的全部推荐板块，可展开查看或跳转到对应榜单
- 12 个排行榜：日、周、月的点击与推荐榜，以及年度、最新入库、字数、热度等分类
- 热度排名：总榜与各文库榜，共 20 个榜单
- Tags 云集：按题材分类浏览全站标签，附站点的标签使用说明
- 按文库浏览：按文库分类查找作品

### 书籍

- 详情页显示作品标签，点击标签可查看同标签的其他作品
- 标签书单支持最近更新、热门、已完结、已动画化四种查看方式
- 书评列表与楼层，支持分页浏览
- 按书名或作者搜索，自动保存搜索历史

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

### 界面

- 液态玻璃材质，适配浅色、深色与着色模式
- 封面取色：详情页与书评页的背景会跟随书籍封面配色
- 原生标签栏与系统返回手势
- 适配 iPad，支持横屏阅读

## 下载

App 未上架 App Store，需自行签名安装。可在 [Releases](https://github.com/jijijitian/wenku8-reader/releases)
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

打开即可浏览首页与搜索，无需任何配置。

如需同步书架、查看排行榜或按标签浏览，请前往 **书架 → 登录**，使用文库账号登录。

### 站点域名

在 **设置 → 数据来源** 中可以在 `wenku8.net`、`wenku8.cc`、`wenku8.com` 三个域名之间切换。
三处指向同一个站点，某个域名无法访问时换一个即可，账号与书架不受影响。

## FAQ

### 为什么部分页面需要登录？

文库对未登录访客只开放部分内容：排行榜、标签页、站点首页的推荐板块都需要登录后才会显示。
登录一次即可长期使用。

### 为什么个别书籍无法打开？

少数书籍在文库网页端本身就不可读，App 会在失败时给出明确提示，不会静默留白。

### 账号密码会被保存吗？

不会。密码仅在登录时提交给文库，App 不存储密码，登录状态保存在系统 Cookie 中，退出登录时清除。

### 数据来自哪里？

全部内容来自轻小说文库公开网页。本 App 不存储、不转售任何作品内容。

### 支持哪些系统？

iOS 17.0 及以上。液态玻璃效果需要 iOS 26 或更新版本，旧系统会自动使用半透明材质。

## 反馈

使用中遇到问题或有功能建议，欢迎在 [Issues](https://github.com/jijijitian/wenku8-reader/issues) 中提出。

## 致谢

- [MewX/light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android)：功能与交互参考，UI 设计：ZERO
- [celia-sh/Novella](https://github.com/celia-sh/Novella)：封面取色与书籍详情页的配色方案参考

## 许可

本项目基于 [GPL-2.0](https://github.com/jijijitian/wenku8-reader/blob/master/LICENSE) 协议开源，与原始 Android 项目一致。
