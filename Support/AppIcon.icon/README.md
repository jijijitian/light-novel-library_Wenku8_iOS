# 应用图标

Icon Composer 文档（`.icon` 包）：一个矢量字形压在一块渐变底上，字形层带玻璃材质。
这是 Xcode 26 起图标的标准形式，`actool` 会从它同时产出 iOS 26 的玻璃图标、深色/着色
变体，以及旧系统读取的 PNG 回退图，因此**不再需要 Assets.xcassets 里的 appiconset**。

## 结构

| 文件 | 作用 |
| --- | --- |
| `icon.json` | `automatic-gradient` 蓝底 + `glass: true` 的字形层 |
| `Assets/軽.svg` | 字形轮廓（U+8EFD），由 `tools/make-glyph-svg.swift` 生成 |

## 参数是量出来的，不是估的

参照 Aidoku 的图标（同样是一个大字压在纯色底上），用两张 180px 图做像素比对：

| 指标 | Aidoku | 本图标 |
| --- | --- | --- |
| 字形占整块的比例 | 0.589 | 0.589 |
| 笔画中位宽度（千分之一） | 61.1 | 60.0 |

对应参数：**Hiragino Sans W6**，字形墨迹高度取画布的 **0.615**。

之所以是 0.615 而不是 0.589：`actool` 会裁掉 SVG 的空白再缩放，实测缩放系数约 0.958，
所以写进 SVG 的尺寸要除以它。

字重若换成 W7，笔画会到 83/1000，明显偏粗；W5 是 50/1000，偏细。W6 最接近。

## 重新生成

```bash
swiftc -O tools/make-glyph-svg.swift -o /tmp/make-glyph-svg
/tmp/make-glyph-svg HiraginoSans-W6 0.615 "Support/AppIcon.icon/Assets/軽.svg"
# 生成器输出的是黑色轮廓，需要白色——玻璃层会用这个颜色
sed -i '' 's|fill-rule="evenodd"|fill="#FFFFFF" fill-rule="evenodd"|' "Support/AppIcon.icon/Assets/軽.svg"
```

`icon.json` 里两个字段值得保留的：

- `"automatic-gradient"` —— 底色的深浅渐变由系统生成，深色模式下会自然带一层渐变
- `"translucency": { "enabled": false }` —— 关掉后字形是实心白；开着会透出底色，字发虚
