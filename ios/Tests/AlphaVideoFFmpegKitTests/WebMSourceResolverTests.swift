import XCTest
@testable import AlphaVideoFFmpegKit

final class WebMSourceResolverTests: XCTestCase {

    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("resolver test \(UUID().uuidString).webm")
        try Data([0x1a, 0x45, 0xdf, 0xa3]).write(to: file)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func resolve(_ uri: String, cacheKey: String? = nil) throws -> String {
        try WebMSourceResolver.localPath(for: uri, cacheKey: cacheKey, isCancelled: { false })
    }

    private func assertThrows(_ uri: String, cacheKey: String? = nil, containing text: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try resolve(uri, cacheKey: cacheKey), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(text), "\(error.localizedDescription)", file: file, line: line)
        }
    }

    func testIdentityUsesTheCacheKeyThenTheUrlWithoutItsQuery() {
        XCTAssertEqual(WebMSourceResolver.identity(for: "https://cdn.example.com/a.webm?sig=1", cacheKey: "glow"), "glow")
        XCTAssertEqual(WebMSourceResolver.identity(for: "https://cdn.example.com/a.webm?sig=1", cacheKey: nil),
                       "cdn.example.com/a.webm")
        XCTAssertEqual(WebMSourceResolver.identity(for: "https://cdn.example.com/a.webm?sig=2", cacheKey: ""),
                       "cdn.example.com/a.webm")
        XCTAssertEqual(WebMSourceResolver.identity(for: "asset://media/a.webm", cacheKey: nil), "asset://media/a.webm")
    }

    func testLocalFilesAreUsedInPlace() throws {
        XCTAssertEqual(try resolve(file.path), file.path)
        XCTAssertEqual(try resolve(file.absoluteString), file.path)
    }

    func testRejectsMissingFilesAndUnsupportedSchemes() {
        assertThrows(file.path + ".missing", containing: "File not found")
        assertThrows("content://media/1", containing: "Unsupported source")
        assertThrows("relative/a.webm", containing: "Unsupported source")
        assertThrows("asset://", containing: "Bad asset URI")
        assertThrows("asset://no-such-clip.webm", containing: "File not found")
    }

    func testCacheKeyMustStayInsideTheCacheDirectory() {
        // Checked before any download starts.
        assertThrows("https://example.invalid/a.webm", cacheKey: "../escape.webm", containing: "inside the cache directory")
        assertThrows("https://example.invalid/a.webm", cacheKey: "a/../../escape.webm", containing: "inside the cache directory")
    }
}
