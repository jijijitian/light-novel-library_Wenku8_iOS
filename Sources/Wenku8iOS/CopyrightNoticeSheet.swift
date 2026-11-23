import SwiftUI

/// The books the site stopped serving at rights holders' request.
///
/// Kept in the app so a reader who cannot find a book learns why before assuming a fault,
/// presented the way the tag guide is: the text itself rather than a link out. The list is
/// the site's own notice, and it is presented as that notice's content — not as a live feed
/// of what is currently unavailable, which is why the screen says it may be incomplete.
struct CopyrightNoticeSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Grouped by the publisher the notice named.
    private static let groups: [(publisher: String, books: [String])] = [
        ("ASCII MEDIA WORKS", [
            "刀剑神域", "仰望半月的夜空", "灼眼的夏娜", "无头骑士异闻录",
            "我的妹妹哪有这么可爱！", "电波女与青春男", "离别的钢琴奏鸣曲", "神的记事本",
            "MAMA", "雪螳螂", "龙与虎", "樱花庄的宠物女孩",
            "遗产尖兵9S", "加速世界", "打工吧！魔王大人", "奋斗吧！系统工程师",
            "金色时光", "毒吐姬与星之石", "奇诺之旅", "魔法的禁书目录",
            "魔法科高校的劣等生", "虚空之盒与零之麻理亚",
        ]),
        ("角川书店", [
            "东方妖游记", "不迷途的羔羊", "凉宫春日的惊愕（前/后）",
            "丹特丽安的书架", "机动战士敢达UC", "黄昏色的咏使",
        ]),
        ("ENTERBRAIN", [
            "笨蛋、测试、召唤兽", "光在地球之时…", "狗与剪刀的正确用法", "心灵链环",
        ]),
        ("MEDIA FACTORY", [
            "绯弹的亚里亚", "我与亲爱哥哥的日常", "迷茫管家与懦弱的我",
            "变态王子与不笑猫", "圣剑锻造师",
        ]),
    ]

    private var totalCount: Int {
        Self.groups.reduce(0) { $0 + $1.books.count }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("应国内版权所有者要求，文库已停止下列小说的在线阅读与电子书下载服务。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("这些作品在 App 内同样无法搜索或打开，与网络、账号无关。共 \(totalCount) 部。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 22)

                    ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.publisher)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                            ForEach(Array(group.books.enumerated()), id: \.offset) { index, book in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(index + 1).")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 22, alignment: .trailing)
                                    Text(book)
                                        .font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 22)
                    }

                    Text("此列表不一定完整：文库可能在其他时间、以其他方式下架过作品，未在此列出的书也可能打不开。若遇到，可在 Issues 反馈。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(18)
            }
            .background { AppBackground() }
            .navigationTitle("版权下架书目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
