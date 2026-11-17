import Foundation
import Wenku8Core

// Broader live sweep: every archived ranking year, all book pages used by the
// UI, and the image hosts that covers and illustrations are served from.
@main
struct Coverage {
    static func main() async {
        let service = NovelService()
        let client = Wenku8Client()
        var failures = 0

        func fail(_ label: String, _ message: String) {
            failures += 1
            print("FAIL  \(label): \(message)")
        }

        for year in SugoiParser.availableYears {
            do {
                let parsed = try await service.sugoi(year: year)
                print("PASS  sugoi \(year): \(parsed.sections.count) sections, \(parsed.allBooks.count) books")
            } catch {
                fail("sugoi \(year)", (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }

        for aid in [4086, 2580, 3057, 1973, 3519] {
            do {
                let detail = try await service.detail(aid: aid)
                guard !detail.title.isEmpty else {
                    fail("detail \(aid)", "empty title")
                    continue
                }
                let volumes = try await service.volumes(aid: aid)
                let chapters = volumes.flatMap(\.chapters)
                guard let first = chapters.first else {
                    fail("volumes \(aid)", "no chapters")
                    continue
                }
                let content = try await service.chapter(aid: aid, cid: first.id)
                print("PASS  novel \(aid): \(detail.title.prefix(18)) / \(chapters.count) ch / \(content.blocks.count) blocks")
            } catch {
                fail("novel \(aid)", (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }

        do {
            let detail = try await service.detail(aid: 4086)
            if let cover = detail.coverURL {
                let response = try await client.get(cover)
                let head = response.data.prefix(3)
                let isJPEG = head == Data([0xFF, 0xD8, 0xFF])
                print("\(isJPEG ? "PASS" : "FAIL")  cover \(cover.lastPathComponent): \(response.data.count) bytes jpeg=\(isJPEG)")
                if !isJPEG { failures += 1 }
            }
        } catch {
            fail("cover", (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        // An illustration chapter contains only images on the desktop site.
        do {
            let volumes = try await service.volumes(aid: 4086)
            if let illustration = volumes.flatMap(\.chapters).first(where: { $0.title.contains("插图") }) {
                let content = try await service.chapter(aid: 4086, cid: illustration.id)
                print("PASS  illustration \(illustration.title): \(content.blocks.count) blocks, first=\(content.blocks.first.map { "\($0)" } ?? "-")")
            } else {
                print("SKIP  illustration: none in this novel")
            }
        } catch {
            fail("illustration", (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        for keyword in ["结婚", "史莱姆", "青春"] {
            do {
                let items = try await service.search(SearchQuery(keyword: keyword, field: .title))
                print("PASS  search \(keyword): \(items.count) results")
            } catch {
                fail("search \(keyword)", (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }

        do {
            let byAuthor = try await service.search(SearchQuery(keyword: "优汰", field: .author))
            print("PASS  author search: \(byAuthor.count) results")
        } catch {
            fail("author search", (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        if failures > 0 {
            print("\n\(failures) check(s) failed")
            exit(1)
        }
        print("\nall coverage checks passed")
    }
}
