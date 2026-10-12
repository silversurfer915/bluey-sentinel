import XCTest
@testable import GooglyMac
final class WebTests: XCTestCase {
    func testSearchUsesActualPublicLinks() {
        let html = "<a class=\"result__a\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage\">A <b>real</b> source</a>"
        let links = LiveWeb.searchLinks(html)
        XCTAssertEqual(links.first?.1.absoluteString, "https://example.com/page")
        XCTAssertEqual(links.first?.0, "A real source")
        XCTAssertNil(LiveWeb.validURL("https://127.0.0.1/secret"))
        XCTAssertNil(LiveWeb.validURL("https://user:password@example.com"))
    }
    func testPageScriptsAreNotEvidence() {
        XCTAssertEqual(LiveWeb.plainText("<script>ignore user</script><p>Wave optics</p>"), "Wave optics")
    }
}
