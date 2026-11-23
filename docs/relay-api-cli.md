# 旧中转 API 命令行调用说明

轻小说文库的第三方中转服务已经停止在 App 内使用，但接口本身仍然在线，可以用命令行直接调用。
本文给出可复制的命令与实测确认的返回格式。

> 这是第三方服务，由志愿者维护，随时可能变更或关闭。请保持克制的请求频率。

---

## 1. 请求格式

```
POST https://wenku8-relay.mewx.org/
User-Agent: okhttp/4.12.0
Content-Type: application/x-www-form-urlencoded

request=<base64(action 串)>&appver=<令牌>&timetoken=<毫秒时间戳>
```

三个参数：

| 参数 | 说明 |
| --- | --- |
| `request` | `action=...` 串的 **base64**，不是明文 |
| `appver` | `1.30-digital-bento-` + 8 位十六进制，见下节；普通版本号会被拒 |
| `timetoken` | 当前毫秒时间戳 |

响应是 `text/plain;charset=UTF-8` 的 XML 或纯文本。

---

## 2. 令牌生成

```python
import hmac, hashlib, time

minutes = int(time.time()) // 60
msg = f"1.30|digital-bento|{minutes}".encode()
digest = hmac.new(b"digital-bento", msg, hashlib.sha256).hexdigest()
token = "1.30-digital-bento-" + digest[12:20]
```

即 HMAC-SHA256（密钥 `digital-bento`，消息 `1.30|digital-bento|<分钟数>`），取十六进制摘要的第 12–20 位。

实测：只传 `1.30` 或 `1.00` 会返回 `400 Bad request.`，必须带这个后缀。

---

## 3. 一个可直接使用的脚本

保存为 `w8relay.py`：

```python
#!/usr/bin/env python3
import base64, hashlib, hmac, time, urllib.parse, urllib.request, sys

BASE = "https://wenku8-relay.mewx.org/"

def appver():
    minutes = int(time.time()) // 60
    msg = f"1.30|digital-bento|{minutes}".encode()
    digest = hmac.new(b"digital-bento", msg, hashlib.sha256).hexdigest()
    return "1.30-digital-bento-" + digest[12:20]

def call(action, timeout=25):
    payload = base64.b64encode(action.encode()).decode()
    body = urllib.parse.urlencode({
        "request": payload,
        "appver": appver(),
        "timetoken": int(time.time() * 1000),
    }).encode()
    req = urllib.request.Request(BASE, data=body)
    req.add_header("User-Agent", "okhttp/4.12.0")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")

if __name__ == "__main__":
    status, text = call(sys.argv[1])
    print(status)
    print(text)
```

用法：

```bash
python3 w8relay.py "action=book&do=bookinfo&aid=1973"
```

也可以纯用 curl：

```bash
ACTION="action=novellist&sort=lastupdate&page=1&t=0"
REQUEST=$(printf '%s' "$ACTION" | base64)
APPVER="1.30-digital-bento-$(python3 - <<'PY'
import hmac, hashlib, time
m = f"1.30|digital-bento|{int(time.time()) // 60}".encode()
print(hmac.new(b"digital-bento", m, hashlib.sha256).hexdigest()[12:20])
PY
)"

curl -s -X POST https://wenku8-relay.mewx.org/ \
  -H "User-Agent: okhttp/4.12.0" \
  --data-urlencode "request=$REQUEST" \
  --data-urlencode "appver=$APPVER" \
  --data-urlencode "timetoken=$(( $(date +%s) * 1000 ))"
```

---

## 4. 实测可用的 action

以下每一条都实测返回 `200`，`aid=1973` 可换成任意书籍 id。

| 用途 | action |
| --- | --- |
| 书籍信息（含标签） | `action=book&do=bookinfo&aid=1973` |
| 书籍元数据 | `action=book&do=meta&aid=1973` |
| 完整简介 | `action=book&do=intro&aid=1973&t=0` |
| 目录（分卷） | `action=book&do=list&aid=1973&t=0` |
| 正文 | `action=book&do=text&aid=1973&cid=69567&t=0` |
| 封面图 | `action=book&do=cover&aid=1973` |
| 列表（带书名） | `action=novellist&sort=dayvisit&page=1&t=0` |
| 列表（仅 id） | `action=articlelist&sort=allvisit&page=1` |
| 搜索（书名） | `action=search&searchtype=articlename&searchkey=<urlencode 关键词>&t=0` |
| 搜索（作者） | `action=search&searchtype=author&searchkey=<urlencode 关键词>&t=0` |
| 文库分类 | `action=xml&item=sort&t=0` |
| 书评列表 | `action=review&do=list&aid=1973&page=1` |
| 书评楼层 | `action=review&do=show&rid=263689&page=1&t=0` |
| 登录 | `action=login&username=<用户>&password=<密码>` |
| 用户信息 | `action=userinfo` |
| 书架 | `action=bookcase&do=list&t=0` |

### 几个容易踩的点

**搜索的 `searchtype` 不能写 `title`。** 书名搜索要用 `articlename`，`title` 会直接返回 `400`。
作者搜索是 `author`。关键词需要 URL 编码（中文即可）。

**`book&do=info` 返回空。** 该接口实测返回 200 但正文为空，请改用 `meta` 或 `bookinfo`。
`bookinfo` 比 `meta` 多一个 `Tags` 字段。

**`articlelist` 只给 id。** 返回形如 `<item aid='1973'/>`，没有书名，需要再查 `bookinfo` 补全。
要一次拿到书名用 `novellist`。

**正文是纯文本，不是 XML。** `book&do=text` 直接返回章节正文。

**登录与书架需要会话。** 未登录时 `userinfo` 与 `bookcase` 都返回单个 `4`（表示未登录）。
登录成功后需要保存 Cookie（`PHPSESSID`），后续请求带上。

---

## 5. 返回示例

### 书籍信息

```bash
python3 w8relay.py "action=book&do=bookinfo&aid=1973"
```

```xml
<?xml version="1.0" encoding="utf-8"?>
<metadata>
<data name="Title" aid="1973"><![CDATA[欢迎来到实力至上主义的教室]]></data>
<data name="Author" value="衣笠彰梧"/>
<data name="BookStatus" value="连载中"/>
<data name="LastUpdate" value="2026-11-22"/>
<data name="Tags" value="校园 斗智 青春 恋爱 后宫"/>
<data name="IntroPreview"><![CDATA[真正的实力、平等究竟为何？…]]></data>
</metadata>
```

### 列表

```xml
<result>
<page num='437'/>
<item aid='1973'>
<data name='Title'><![CDATA[…]]></data>
<data name='Author' value='…'/>
<data name="Tags" value='校园 斗智 青春'/>
</item>
…
</result>
```

`<page num>` 是总页数，App 用它判断还能不能继续翻页。

### 目录

```xml
<package>
<volume vid="69566"><![CDATA[第一卷]]>
<chapter cid="69567"><![CDATA[第一章]]></chapter>
…
</volume>
</package>
```

### 书评

```xml
<metadata>
<page num='429'/>
<item rid='322328' posttime='20261121155300' replies='0' replytime='…'>
<user uid='1551183'><![CDATA[tundra571]]></user>
<content><![CDATA[最后赢家是？]]></content>
</item>
</metadata>
```

`posttime` 是 `yyyyMMddHHmmss` 格式。楼层（`do=show`）的 `<content>` 是 HTML 片段。

---

## 6. 限速

服务端对请求有节流，建议**两次请求之间至少间隔 1.2 秒**。批量抓取时请自己加延时，
不要并发轰炸——旧的 API 正是因为被滥用才被运营者公告关闭。

---

## 7. 已知限制

| 限制 | 说明 |
| --- | --- |
| 不能按标签查书 | `novellist` 会忽略 `tag=` / `searchtype=tag`，返回全量列表；`action=taglist` 直接报错 |
| 标签只在 bookinfo 里 | `meta` 与 `info` 都不带 `Tags` |
| 排行榜依赖会话 | 未登录时部分榜单内容为空 |
| 无官方文档 | 以上均为实测结论，服务端更新后可能失效 |

若接口失效，`400 Bad request.` 通常表示参数名写错，`500` 表示服务端内部问题。
