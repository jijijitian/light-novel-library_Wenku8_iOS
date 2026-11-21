# 标签（Tag）功能方案

目标：详情页显示书籍标签，点击标签查看包含该标签的所有书籍。

---

## 1. 现状核实

### 已实测

**中转的列表接口已经带标签。** `action=novellist` 每条 `<item>` 里都有：

```xml
<item aid='4536'>
  <data name='Title'><![CDATA[你好，我是诱惑魔王大人的圣女]]></data>
  <data name='Author' value='虎月ゆめ'/>
  <data name='BookStatus' value='已完结'/>
  <data name="Tags" value='奇幻 冒险 百合 女性视角'/>
</item>
```

**中转的书籍详情也带标签。** `action=book&do=bookinfo&aid=4536`：

```xml
<data name="Tags" value="奇幻 冒险 百合 女性视角"/>
```

> 注意是本 App 现在用的 `book&do=info` **没有** `Tags`，`book&do=bookinfo` 才有。
> 两者返回的字段并不完全一致（例如 BookStatus 一个写「已完成」一个写别的），接入时要留意。

**标签是空格分隔的单个字符串。** 上游 Android 客户端的单元测试也是这么断言的：
`"校园 青春 女性视角"`、`"穿越 校园 青春"`。中文标签内部不含空格，所以按空白切分是安全的。

**中转不支持按标签过滤。** 试过三种写法，多传的参数被直接忽略、返回的是完整列表：

```
action=novellist&sort=lastupdate&tag=校园&page=1&t=0        → 返回 num=437 的全量列表
action=novellist&sort=lastupdate&searchtype=tag&...        → 同上
action=taglist&tag=校园                                    → Bad request.
```

**中转的搜索不接受标签类型：**

```
action=search&searchtype=tag&searchkey=校园  → Bad request.
```

### 未验证（需要一次确认）

- **站点标签列表页的 URL**。网页端点击标签会跳到一个书单页，但我无法在未登录状态下拿到它：
  - `/modules/article/search.php?searchtype=tag&searchkey=…` → **302 跳登录**
  - `/search.php?searchtype=tag&…` → 200，但只是搜索表单
  - `/modules/article/taglist.php`、`/tag/…` → 404
- **标签是否只在登录后出现**。匿名抓 `/book/4536.htm` 的完整 HTML 里没有「标签」二字。

> 这一条决定二期能不能做。确认方法：在网页端登录后打开任意书籍页，长按一个标签复制链接，或截图给我。

---

## 2. 结论：分两期做，一期不依赖任何未确认的信息

| | 一期（现在就能做） | 二期（需要确认标签列表页） |
| --- | --- | --- |
| 详情页显示标签 | ✅ 中转开启时可用 | 网页版数据源也可用 |
| 点击标签 → 全部书籍 | ❌ 只能看本地已收录 | ✅ 完整书单 |
| 依赖 | 无 | 标签列表页 URL |

### 为什么一期不能做完整的「全部书籍」

中转不给按标签筛选，站点搜索又要登录。剩下的办法只有**把整站爬一遍建索引**：

```
437 页 × 20 本 ≈ 8700 本，每页间隔 1.2 秒 ≈ 9 分钟
```

这既不合规（中转有配额），也不可靠（新书会漏）。所以一期只做**本地索引**：把用户实际浏览过的书登记下来。

---

## 3. 一期设计

### 3.1 数据层

```swift
// Sources/Wenku8Core/Models.swift
public struct NovelTag: Hashable, Sendable {
    public var name: String          // 展示用原文
    public var key: String           // 归一化：去空白、小写化后用于去重
}

public struct NovelSummary {
    // ...
    public var tags: [NovelTag] = []
}
```

解析：

```swift
// RelayParser
case "Tags":
    info.tags = value("Tags")?.split(whereSeparator: \.isWhitespace).map(NovelTag.init) ?? []
```

`RelayParser.summaries` 与 `bookinfo` 两条路径都要接。

### 3.2 本地标签索引

新增 `TagIndex`（`Sources/Wenku8Core/TagIndex.swift`），落盘在 `Application Support/TagIndex.json`：

```swift
struct TagIndex: Codable {
    var books: [Int: [String]]       // aid → 标签
    var updatedAt: [Int: Date]       // aid → 最后登记时间
}
```

写入时机（**零额外请求**）：任何一次列表或详情返回时，顺手登记它带来的标签。

```swift
await TagIndex.shared.record(novel)         // 来自列表
await TagIndex.shared.record(detail)        // 来自详情
```

读取：`TagIndex.shared.novels(tag: "校园")` → `[Int]`，再和已有缓存的书目信息拼接。

### 3.3 界面

**详情页**（`NovelDetailView`）：简介下方一行标签胶囊。

```
奇幻  冒险  百合  女性视角
```

- 点击 → 打开标签书单页
- 中转关闭且网页版拿不到标签时，这一行整个不显示（不显示空行）

**标签书单页**（新文件 `TagNovelListView`）：复用现有 `PagedNovelList` 的网格与骨架屏。

```
┌──────────────────────────────┐
│ ← 校园                        │
│   已收录 12 本                │
│                              │
│ [封面] [封面] [封面]          │
└──────────────────────────────┘
```

**空态要讲清楚为什么空**，不能让人以为站上没书：

> 中转服务不提供按标签筛选，这里只显示本机已收录的书籍。
> 关闭中转并登录后，可查看完整书单。

### 3.4 与数据源规则的关系

现在的硬规则是「中转开启只走中转，关闭只走网页版」。标签是**随数据一起来的**，不额外发请求，因此不违反这条规则：

- 中转开启 → 标签来自中转的列表/详情
- 中转关闭 → 标签来自站点页面（如果拿得到）

二期如果要用站点的标签列表页，那是**新的请求**，必须遵守同一规则：中转开启时不偷偷去打站点。

---

## 4. 二期设计（待确认后）

先确认标签列表页的 URL，再决定接入方式。两种可能：

**情况 A：标签页是普通 GET 页面**（如 `/tag/xxx` 或 `searchtype=tag`）

```swift
public func novels(tag: String, page: Int) async throws -> [NovelSummary] {
    if relayIsAvailable {
        // 中转不支持 → 明确拒绝，不混用
        throw Wenku8Error.unavailable("中转服务不支持按标签浏览，请关闭中转后重试")
    }
    let html = try await client.desktop("/<确认后的路径>?tag=…&page=\(page)")
    return DesktopParser.novelCards(html)
}
```

**情况 B：必须登录才有结果**

那么标签书单只在中转关闭且已登录时可用；未登录时按钮变成提示「登录后可查看该标签的全部书籍」。

两种情况都能落到现有结构里：`PagedNovelList` + 一个 `TagNovelListModel`。

---

## 5. 工作量估计

| 阶段 | 内容 | 规模 |
| --- | --- | --- |
| 一期 A | 解析 `Tags`（列表 + bookinfo） | 半天 |
| 一期 B | `TagIndex` 落盘与登记 | 半天 |
| 一期 C | 详情页标签行 + 标签书单页 | 1 天 |
| 二期 | 标签列表页接入（取决于确认结果） | 1–2 天 |

---

## 6. 风险

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 标签格式变化（改用逗号/竖线分隔） | 标签被切错 | 先按空白切；如果出现单字标签异常，检查原始 `Tags` 值 |
| 本地索引越积越多 | 存储膨胀 | 索引用 aid 做键、只存标签字符串，8700 本约 300KB，可接受 |
| 本地索引与站点不同步 | 标签页显示的书已下架 | 展示时以本地书目缓存为准，打不开的条目自动跳过 |
| 二期标签页需要登录 | 未登录不可用 | 明确提示，不做静默降级 |

---

## 7. 需要你确认的两件事

1. **标签列表页的 URL**：网页端登录后，点一个标签，把地址栏那串发我（或长按标签复制链接）。
2. **标签在书页上的位置**：是正文上方、简介下方，还是侧栏？这决定详情页把它放在哪。

有这两条，二期就能一次做对；没有也能先把一期落地。
