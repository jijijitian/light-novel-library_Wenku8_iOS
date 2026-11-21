# 标签（Tag）功能方案

目标：书籍显示标签，点击标签查看包含它的所有书籍。

本文档的结论都来自登录后对站点的实测（2026-11-21），不是推测。

---

## 1. 站点提供了什么

### 标签书单页

```
https://www.wenku8.net/modules/article/tags.php?t=<GBK 编码的标签>&page=<页码>&v=<排序>
```

实测 `t=校园`（GBK `%D0%A3%D4%B0`）：

```html
<table class="grid" ...>
  <caption>Tags含有 校园 的轻小说</caption>
  <th>按更新查看 | <a href="tags.php?t=校园&v=1">按热门查看</a> |
      <a href="tags.php?t=校园&v=2">只看已完结</a> |
      <a href="tags.php?t=校园&v=3">只看动画化</a></th>
  <tr><td>
    <div style="width:373px;height:136px;...">
      <div style="width:95px;float:left;">
        <a href="/book/4535.htm" title="绝不选择你">
          <img src="http://img.wenku8.com/image/4/4535/4535s.jpg" height="130" width="90"/>
        </a>
      </div>
      <div style="margin-top:2px;">
        <b><a style="font-size:13px;" href="/book/4535.htm" title="绝不选择你">绝不选择你</a></b>
        <p>作者:白鸟かおる/分类:角川文库</p>
        <p>更新:2026-11-21/字数:91K/连载中</p>
        <p>Tags:<span style="font-weight:bold;color: #1b74bc;">穿越 校园 音乐 青春 恋爱</span></p>
        <p>简介:如果人生能够重来一次，你会选择……</p>
      </div>
    </div>
  </td></tr>
</table>

<div class="pagelink"><em id="pagestats">1/60</em>
  <a href="tags.php?t=%D0%A3%D4%B0&page=2">2</a> ...
```

- **20 条/页**，总页数在 `<em id="pagestats">当前/总数</em>`
- `v=0` 按更新（默认）、`v=1` 按热门、`v=2` 只看已完结、`v=3` 只看动画化
- 每张卡片**自带 Tags 行**

### 标签云页

```
https://www.wenku8.net/modules/article/tags.php
```

列出站上全部标签，按类别分组（恋爱系、幻想系、黑深残、人物属性、特殊属性），
链接形如 `<a href=tags.php?t=青春>青春</a>`。

### 三个必须注意的事实

**① 标签参数必须 GBK 编码。** 实测对比：

| 参数 | 结果 |
| --- | --- |
| `%D0%A3%D4%B0`（GBK「校园」） | 20 条，标题「Tags含有 校园 的轻小说」 |
| `%E6%A0%A1%E5%9B%AD`（UTF-8「校园」） | **0 条**，标题还被解成乱码「鏍″洯」 |

**② 两个页面都需要登录。** 匿名访问返回 302：

```
location: /login.php?jumpurl=...modules/article/tags.php...
```

**③ 书籍详情页没有标签。** 登录后抓 `/book/4536.htm`，全文没有 `Tags:` 行，也没有 `tags.php?t=` 链接。
标签只存在于**列表页与标签页的卡片里**。

### 中转侧已具备的

`action=novellist`（首页/排行/文库/搜索）每条都带：

```xml
<data name="Tags" value='奇幻 冒险 百合 女性视角'/>
```

`action=book&do=bookinfo&aid=4536` 也带同样的 `Tags` 字段。
（本 App 现在用的 `book&do=info` 没有，需要改用 `bookinfo` 或两者合并。）

中转**不能**按标签列书：多传 `tag=` / `searchtype=tag` 会被忽略，返回全量列表；
`action=taglist` 直接 Bad request。

---

## 2. 能力矩阵

| 能力 | 中转开启 | 网页版 + 已登录 | 网页版 + 未登录 |
| --- | --- | --- | --- |
| 列表卡片带标签 | ✅ | ✅ | — |
| 详情页显示标签 | ✅（bookinfo） | ❌ 站点书页无标签 | ❌ |
| 标签书单（全部书籍） | ❌ | ✅ | ❌ 需登录 |
| 标签云（浏览全部标签） | ❌ | ✅ | ❌ 需登录 |

---

## 3. 实现方案

### 3.1 数据层

```swift
public struct NovelTag: Hashable, Sendable, Codable {
    public var name: String          // 展示原文，如「校园」
    public var key: String           // 归一化键，用于去重与比较
}

public struct NovelSummary {
    // ...
    public var tags: [NovelTag] = []
}
```

解析：

- `RelayParser`：读 `Tags` 属性，按空白切分
- `DesktopParser`：读卡片里的 `<p>Tags:<span ...>穿越 校园 音乐</span></p>`
- 新增 `DesktopParser.tagCloud(in:)`：读标签云页的全部标签

### 3.2 GBK 编码

站点标签页要求 GBK，`TextDecoding` 已有 GBK 表，加一个反向编码：

```swift
// TextDecoding.swift
public static func formEncodeGBK(_ value: String) -> String? {
    // 用 GBK 表反查每个字符的字节，再做百分号编码；表里没有的字符返回 nil
}
```

调用处若返回 nil（如含生僻字或假名的标签），退回 UTF-8 并按失败处理。

### 3.3 服务层

```swift
public struct TagPage: Sendable {
    public var tag: String
    public var novels: [NovelSummary]
    public var page: Int
    public var totalPages: Int
}

/// 某个标签下的书。仅网页版可用。
public func novels(tag: String, page: Int = 1) async throws -> TagPage

/// 全部标签。仅网页版可用。
public func tagCloud() async throws -> [String]

/// 书籍详情连同标签。中转开启时走 bookinfo。
public func detail(aid: Int) async throws -> NovelDetail   // 增加 tags 字段
```

数据源规则照旧：

```swift
public func novels(tag: String, page: Int) async throws -> TagPage {
    guard !relayIsAvailable else {
        throw Wenku8Error.unavailable("中转服务不支持按标签浏览，请关闭中转后重试")
    }
    guard await isSignedIn else { throw Wenku8Error.needLogin }
    let encoded = TextDecoding.formEncodeGBK(tag) ?? tag
    let html = try await client.desktop(
        "/modules/article/tags.php?t=\(encoded)&page=\(page)"
    )
    ...
}
```

### 3.4 界面

**详情页**：简介下方一行标签胶囊（仅当标签非空时显示）。

```
[奇幻] [冒险] [百合] [女性视角]
```

**标签书单页** `TagNovelListView`：复用现有 `PagedNovelList` 的网格与骨架。

```
← 校园                     共 60 页
  [封面] [封面] [封面]
```

**标签云页**（可选，二期）：按站点分组展示全部标签，作为「按标签找书」的入口。

### 3.5 各数据源下的用户流程

| 场景 | 行为 |
| --- | --- |
| 中转开启，点标签 | 提示「中转不支持按标签浏览，关闭中转并登录后可查看」 |
| 网页版 + 已登录 | 直接进标签书单页 |
| 网页版 + 未登录 | 提示登录 |
| 网页版详情页 | 没有标签（站点书页本身就没有），标签行不显示 |

---

## 4. 分期

| 阶段 | 内容 | 依赖 |
| --- | --- | --- |
| 一期 | `Tags` 解析（中转列表 + bookinfo）、详情页标签行、`NovelSummary.tags` | 无 |
| 二期 | GBK 编码器、标签书单页 | 网页版登录 |
| 三期 | 标签云页、标签排序（更新/热门/完结/动画化） | 同上 |

一期不增加任何请求：标签随已有的列表与详情一起到达。

---

## 5. 风险

| 风险 | 应对 |
| --- | --- |
| 标签页要求登录 | 明确提示，不做静默降级 |
| GBK 编码失败（生僻标签） | 退回 UTF-8 并提示「该标签暂时无法打开」 |
| 站点改版 | 解析集中在 `DesktopParser`，只需改一处 |
| 中转的 `bookinfo` 与 `info` 字段差异 | 统一走 `bookinfo`，或两者合并后取并集 |

---

## 6. 下一步

按一期先落地：解析 `Tags` + 详情页展示。这一步没有风险，也不依赖登录。
确认无误后，再做标签书单页。
