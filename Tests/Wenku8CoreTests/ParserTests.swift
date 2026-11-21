import XCTest
@testable import Wenku8Core

final class ParserTests: XCTestCase {
    private func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    private func fixture(_ name: String) throws -> String {
        TextDecoding.decode(try data(name))
    }

    func testGBKDecodingMatchesDeclaredCharset() throws {
        let raw = try data("desktop-book.html")
        XCTAssertTrue(TextDecoding.declaresGBK(raw))
        let text = TextDecoding.decode(raw)
        XCTAssertTrue(text.contains("你们赶紧给我结婚吧"), "title should decode from GBK")
        XCTAssertTrue(text.contains("优汰"))
        XCTAssertFalse(text.contains("\u{FFFD}"))
    }

    func testUTF8WAPPayloadSurvives() throws {
        let text = try fixture("home.wml")
        XCTAssertTrue(text.contains("轻小说文库"))
        XCTAssertFalse(text.contains("\u{FFFD}"))
    }

    func testHomeSections() throws {
        let rows = WAPParser.homeSections(try fixture("home.wml"))
        XCTAssertEqual(Set(rows.map(\.section)), Set([.hot, .latest, .newcomer, .weekly]))
        for row in rows {
            XCTAssertEqual(row.items.count, 6, "\(row.section) should list six books")
            XCTAssertTrue(row.items.allSatisfy { $0.id > 0 && !$0.title.isEmpty })
        }
        XCTAssertEqual(rows.first(where: { $0.section == .hot })?.items.first?.id, 3519)
    }

    func testLoginGateDetected() throws {
        XCTAssertTrue(WAPParser.requiresLogin(try fixture("toplist-login.wml")))
        XCTAssertFalse(WAPParser.requiresLogin(try fixture("home.wml")))
    }

    func testSearchResults() throws {
        let items = WAPParser.linksIn(try fixture("search.wml"))
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(items.first?.id, 4086)
        XCTAssertEqual(items.first?.title, "《你们赶紧给我结婚吧！》优汰")
        XCTAssertEqual(items.last?.id, 1315)
    }

    func testArticleInfoDetail() throws {
        let detail = WAPParser.novelDetail(try fixture("articleinfo.wml"), aid: 4086)
        XCTAssertEqual(detail.title, "你们赶紧给我结婚吧！")
        XCTAssertEqual(detail.author, "优汰")
        XCTAssertEqual(detail.category, "MF文库J")
        XCTAssertEqual(detail.status, "连载中")
        XCTAssertEqual(detail.wordCount, "126476字")
        XCTAssertEqual(detail.updatedAt, "26-01-01")
        XCTAssertEqual(detail.latestChapter?.id, 171212)
        XCTAssertTrue(detail.intro.contains("误会"), "intro: \(detail.intro)")
        XCTAssertEqual(detail.coverURL?.absoluteString, "https://img.wenku8.com/image/4/4086/4086s.jpg")
    }

    func testDesktopDetail() throws {
        let detail = DesktopParser.novelDetail(try fixture("desktop-book.html"), aid: 4086)
        XCTAssertEqual(detail.title, "你们赶紧给我结婚吧！")
        XCTAssertEqual(detail.author, "优汰")
        XCTAssertEqual(detail.category, "MF文库J")
        XCTAssertEqual(detail.status, "连载中")
        XCTAssertEqual(detail.coverURL?.absoluteString, "https://img.wenku8.com/image/4/4086/4086s.jpg")
        XCTAssertTrue(detail.intro.contains("误会"), "intro: \(detail.intro)")
    }

    func testReadbookVolumes() throws {
        let volumes = WAPParser.volumes(try fixture("readbook.wml"))
        XCTAssertFalse(volumes.isEmpty)
        XCTAssertEqual(volumes.first?.title, "第一卷 被这么说的女生居然有三个？")
        let chapters = volumes.flatMap(\.chapters)
        XCTAssertEqual(chapters.first?.id, 169589)
        XCTAssertEqual(chapters.first?.title, "序章 “我已经开始写恋爱喜剧了喔。”")
        XCTAssertGreaterThanOrEqual(chapters.count, 17)
    }

    func testPagination() throws {
        XCTAssertEqual(WAPParser.pagination(try fixture("readbook.wml")).current, 1)
        let page2 = WAPParser.pagination(try fixture("readchapter-page2.wml"))
        XCTAssertEqual(page2.current, 2)
        XCTAssertEqual(page2.total, 3)
        XCTAssertEqual(WAPParser.pagination("<p>no marker</p>").total, 1)
    }

    func testChapterParagraphs() throws {
        let content = WAPParser.chapterContent(try fixture("readchapter.wml"), aid: 4086, cid: 169589)
        XCTAssertEqual(content.title, "序章 “我已经开始写恋爱喜剧了喔。”")
        XCTAssertFalse(content.blocks.isEmpty)
        let paragraphs = content.blocks.compactMap { block -> String? in
            if case .paragraph(let text) = block { return text }
            return nil
        }
        XCTAssertTrue(paragraphs.contains { $0.contains("网译版") })
        XCTAssertFalse(paragraphs.contains { $0.contains("加入书签") })
        XCTAssertFalse(paragraphs.contains { $0.contains("报时") })
        XCTAssertFalse(paragraphs.contains { $0.contains("&nbsp;") })
        XCTAssertFalse(paragraphs.contains { $0.contains("轻小说文库") })
    }

    func testIllustrationChapter() throws {
        let content = WAPParser.chapterContent(try fixture("readchapter-illus.wml"), aid: 4086, cid: 169606)
        XCTAssertEqual(content.title, "插图")
        XCTAssertFalse(content.blocks.isEmpty)
    }

    func testReviewList() throws {
        let reviews = WAPParser.reviews(try fixture("reviews.wml"))
        XCTAssertEqual(reviews.count, 10)
        XCTAssertEqual(reviews.first?.id, 320729)
        XCTAssertEqual(reviews.first?.topic, "还没有更新啊")
        XCTAssertEqual(reviews.first?.author, "oiu9956")
        XCTAssertEqual(reviews.first?.date, "2026-10-14")
        XCTAssertEqual(reviews.first?.replyCount, 0)
    }

    func testReviewDetail() throws {
        let result = WAPParser.reviewPosts(try fixture("reviewshow.wml"))
        XCTAssertEqual(result.topic, "还没有更新啊")
        XCTAssertEqual(result.posts.count, 1)
        XCTAssertEqual(result.posts.first?.author, "oiu9956")
        XCTAssertEqual(result.posts.first?.date, "2026-10-14")
    }

    func testLibraryCategories() throws {
        let categories = WAPParser.libraryCategories(try fixture("sort.wml"))
        XCTAssertGreaterThanOrEqual(categories.count, 14)
        XCTAssertEqual(categories.first?.id, 0)
        XCTAssertEqual(categories.first?.name, "全部轻小说")
        XCTAssertTrue(categories.contains { $0.name == "MF文库J" })
    }

    func testDesktopListCards() throws {
        let items = DesktopParser.novelCards(try fixture("desktop-book.html"))
        XCTAssertEqual(items.first?.id, 4086)
        XCTAssertGreaterThanOrEqual(items.count, 5)
    }

    func testMarkupParagraphExtraction() {
        let html = """
        <div>&nbsp;&nbsp;&nbsp;&nbsp;第一段<br /><br />\
        &nbsp;&nbsp;&nbsp;&nbsp;第二段<br/>&nbsp;&nbsp;续行</div>
        """
        XCTAssertEqual(Markup.lines(from: html), ["第一段", "第二段", "续行"])
    }

    func testEntitiesDecode() {
        XCTAssertEqual(Markup.decodeEntities("a&amp;b&#9834;&#x3001;"), "a&b\u{266A}\u{3001}")
        XCTAssertEqual(Markup.decodeEntities("100% & more"), "100% & more")
    }

    func testCoverURLPatterns() {
        XCTAssertEqual(
            CoverURL.image(for: 4086)?.absoluteString,
            "https://img.wenku8.com/image/4/4086/4086s.jpg"
        )
        XCTAssertEqual(
            CoverURL.normalize("http://img.wenku8.com/image/1/1305/1305s.jpg")?.absoluteString,
            "https://img.wenku8.com/image/1/1305/1305s.jpg"
        )
        XCTAssertNil(CoverURL.normalize("   "))
    }

    func testVolumeMerging() {
        let a = Volume(id: "0", title: "第一卷", chapters: [ChapterLink(id: 1, title: "一")])
        let b = Volume(id: "1", title: "第一卷", chapters: [ChapterLink(id: 2, title: "二")])
        let c = Volume(id: "2", title: "第二卷", chapters: [ChapterLink(id: 3, title: "三")])
        let merged = NovelService.mergeVolumes([a, b, c])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].chapters.map(\.id), [1, 2])
        XCTAssertEqual(merged[1].id, "1")
    }
}


final class TagPageTests: XCTestCase {
    func testTagPageReadsCardsTheirTagsAndPageCount() {
        let html = """
        <table class="grid" width="100%"><caption>Tags含有 校园 的轻小说</caption>
        <tr><td><div style="width:373px;height:136px;float:left;">
          <a href="/book/4535.htm" title="绝不选择你"><img src="x"/></a>
          <p>Tags:<span style="font-weight:bold;">穿越 校园 音乐</span></p>
        </div></td></tr>
        <tr><td><div style="width:373px;height:136px;float:left;">
          <a href="/book/4358.htm" title="魔法使之夜"><img src="y"/></a>
          <p>Tags:<span style="font-weight:bold;">校园 奇幻</span></p>
        </div></td></tr>
        </table>
        <div class="pagelink"><em id="pagestats">1/60</em></div>
        """
        let parsed = DesktopParser.tagPage(html)
        XCTAssertEqual(parsed.novels.count, 2)
        XCTAssertEqual(parsed.totalPages, 60)
        XCTAssertEqual(parsed.novels[0].id, 4535)
        XCTAssertEqual(parsed.novels[0].title, "绝不选择你")
        XCTAssertEqual(parsed.novels[0].tags?.map(\.name), ["穿越", "校园", "音乐"])
        XCTAssertEqual(parsed.novels[1].tags?.map(\.name), ["校园", "奇幻"])
    }

    func testBookPageTagsReadFromTheHotTextLine() {
        let html = """
        <td><span class="hottext"><b>作品Tags：校园 斗智 青春 恋爱 后宫</b></span><br />
        <span class="hottext"><b>作品热度：S级</b></span>
        """
        XCTAssertEqual(DesktopParser.tags(html)?.map(\.name), ["校园", "斗智", "青春", "恋爱", "后宫"])
        XCTAssertNil(DesktopParser.tags("<html><body>没有标签</body></html>"))
    }

    func testTagCloudReadsUnquotedLinks() {
        let html = "<li><a href=tags.php?t=校园>校园</a> <a href=tags.php?t=青春>青春</a></li>"
        XCTAssertEqual(DesktopParser.tagCloud(html), ["校园", "青春"])
    }

    func testTagNamesEncodeAsGBK() {
        // The tag pages take GBK; the same tag as UTF-8 comes back empty.
        XCTAssertEqual(TextDecoding.formEncodeGBK("校园"), "%D0%A3%D4%B0")
        XCTAssertEqual(TextDecoding.formEncodeGBK("JK"), "JK")
    }
}
