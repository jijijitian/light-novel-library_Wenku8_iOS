# 插图地址服务

为因版权问题下架的作品提供插图地址。这类作品的插图章节页已被文库删除，页面上没有任何图片，
而中转服务仍能返回该章的正文与图片地址，图床也与官网相同。

服务以章节 id 为主键缓存结果：同一章只向中转请求一次，之后直接返回缓存。

## 接口

```
GET /illust?aid=<aid>&cid=<cid>
```

两个参数都必须传：

- **`cid` 用于查缓存**。章节 id 全站唯一，是数据库主键，查库只用它。
- **`aid` 用于未命中时请求中转**。中转的 action 必须带正确的作品 id，否则返回 `null`。

调用方无法预知这次会不会命中，所以每次都要带上 `aid`。

响应（图片地址为绝对地址）：

```json
{
  "cid": 54785,
  "aid": 1614,
  "cached": false,
  "images": [
    "https://pic.777743.xyz/1/1614/54785/67547.jpg",
    "https://pic.777743.xyz/1/1614/54785/67548.jpg"
  ]
}
```

| 情况 | 说明 |
| --- | --- |
| `cached: false` | 本次向中转取得，已写入数据库 |
| `cached: true` | 直接来自数据库 |
| `images: []` | 该章没有插图。同样是有效结果，也会被缓存 |
| 400 | `aid` 或 `cid` 缺失，或不是整数 |
| 502 | 中转不可用。此时不写库，下次请求会重试 |

另有 `GET /health` 返回 `{"ok": true}`。

## 图片地址构成

```
https://pic.777743.xyz/<aid/1000>/<aid>/<cid>/<图片id>.jpg
```

前两段与章节本身即可推出，图片 id 由中转给出。

## 部署

```bash
install -d /opt/wk8illust
install -m 644 server.py /opt/wk8illust/server.py

cat > /etc/systemd/system/wk8illust.service <<'UNIT'
[Unit]
Description=Wenku8 illustration id service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/wk8illust/server.py
Environment=WK8_PORT=8080
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now wk8illust
```

只依赖 Python 3 标准库，无需安装第三方包。

可用环境变量：`WK8_PORT`（默认 8080）、`WK8_DB`（默认 `/opt/wk8illust/illust.db`）。

阿里云等云主机还需要在安全组放行对应端口，否则外部访问不到。

## 数据库

单表，`cid` 为主键：

| 字段 | 说明 |
| --- | --- |
| `cid` | 章节 id，主键 |
| `paths` | 图片路径的 JSON 数组（不含域名） |
| `fetched_at` | 取得时间（Unix 秒） |
| `source` | 数据来源，目前为 `relay` |

作品 id 没有单独存：每条路径本身就以它开头（`<aid//1000>/<aid>/<cid>/<图片>.jpg`），
再存一列只是重复同一个值。响应里的 `aid` 因此优先回显调用方传入的值，没传时从路径解析。

查看缓存情况：

```bash
sqlite3 /opt/wk8illust/illust.db \
  "SELECT cid, source, json_array_length(paths) AS n FROM illustration ORDER BY fetched_at DESC LIMIT 20;"
```

## 中转凭据

中转要求每分的 `appver`，其算法与官方 Android 客户端一致：

```
appver = "1.30-digital-bento-" + HMAC-SHA256("digital-bento", "1.30|digital-bento|<当前分钟>")[12:20]
```

请求体为表单：

```
&appver=<appver>&request=<base64(action=book&do=text&aid=<aid>&cid=<cid>&t=0)>&timetoken=<毫秒时间戳>
```

## 并发

同一章节的并发请求只触发一次中转：先到的请求取锁并获取，其余等待后直接读库。
实测 20 个并发请求只产生 1 次中转调用。
