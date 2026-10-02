import XCTest
@testable import NotchyCore

final class UpdateTests: XCTestCase {
    func testVersionsCompareByNumber() {
        XCTAssertLessThan(AppVersion("1.0.9")!, AppVersion("v1.0.10")!)
        XCTAssertEqual(AppVersion("1.1")!, AppVersion("1.1.0")!)
        XCTAssertLessThan(AppVersion("1.0.42")!, AppVersion("2")!)
        XCTAssertEqual(AppVersion("v1.2.0-beta")!.description, "1.2.0")
        XCTAssertEqual(Set([AppVersion("1.1")!, AppVersion("1.1.0")!]).count, 1)
        for bad in ["", "v", "1..2", "latest", "1.x"] { XCTAssertNil(AppVersion(bad), bad) }
    }

    private func release(tag: String = "v1.0.12", zip: String = "https://github.com/samidun26/dynamic-island-mac/releases/download/v1.0.12/ponyhub.zip",
                         size: Int = 4_000_000, prerelease: Bool = false) -> Data {
        """
        {"tag_name": "\(tag)", "html_url": "https://github.com/samidun26/dynamic-island-mac/releases/tag/\(tag)",
         "body": "- Keep clear of the menu bar", "draft": false, "prerelease": \(prerelease),
         "assets": [
           {"name": "ponyhub.zip", "browser_download_url": "\(zip)", "size": \(size)},
           {"name": "ponyhub.zip.sha256", "browser_download_url": "https://github.com/samidun26/dynamic-island-mac/releases/download/\(tag)/ponyhub.zip.sha256", "size": 77}
         ]}
        """.data(using: .utf8)!
    }

    func testParsesGitHubsLatestRelease() throws {
        let r = try XCTUnwrap(UpdateFeed.parse(release()))
        XCTAssertEqual(r.version, AppVersion("1.0.12"))
        XCTAssertEqual(r.zipURL.lastPathComponent, "ponyhub.zip")
        XCTAssertEqual(r.checksumURL?.lastPathComponent, "ponyhub.zip.sha256")
        XCTAssertEqual(r.zipSize, 4_000_000)
        XCTAssertTrue(r.notes.contains("menu bar"))
    }

    func testRefusesUntrustedOrOddReleases() {
        // Downloads only from GitHub over HTTPS.
        XCTAssertNil(UpdateFeed.parse(release(zip: "http://github.com/x/ponyhub.zip")))
        XCTAssertNil(UpdateFeed.parse(release(zip: "https://evil.example/ponyhub.zip")))
        XCTAssertNil(UpdateFeed.parse(release(zip: "https://github.com.evil.example/ponyhub.zip")))
        XCTAssertNil(UpdateFeed.parse(release(zip: "file:///tmp/ponyhub.zip")))
        // Not a version, too big, or not meant for everyone yet.
        XCTAssertNil(UpdateFeed.parse(release(tag: "nightly")))
        XCTAssertNil(UpdateFeed.parse(release(size: 500 << 20)))
        XCTAssertNil(UpdateFeed.parse(release(prerelease: true)))
        XCTAssertNil(UpdateFeed.parse("not json".data(using: .utf8)!))
        // A local test feed is accepted only when asked for.
        XCTAssertNil(UpdateFeed.parse(release(zip: "http://127.0.0.1:8765/ponyhub.zip")))
        XCTAssertNotNil(UpdateFeed.parse(release(zip: "http://127.0.0.1:8765/ponyhub.zip"), localFeed: true))
    }

    func testTrustedSources() {
        for ok in ["https://github.com/a/b/releases/download/v1/ponyhub.zip",
                   "https://objects.githubusercontent.com/github-production-release-asset/1",
                   "https://release-assets.githubusercontent.com/x", "https://api.github.com/repos/a/b/releases/latest"] {
            XCTAssertTrue(UpdateFeed.isTrustedSource(URL(string: ok)!, localFeed: false), ok)
        }
        for bad in ["http://github.com/x", "https://githubusercontent.com.evil.example/x", "https://gist.example/x",
                    "http://127.0.0.1:8765/x"] {
            XCTAssertFalse(UpdateFeed.isTrustedSource(URL(string: bad)!, localFeed: false), bad)
        }
    }

    func testChecksumLine() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(UpdateFeed.checksum(in: "\(hex)  ponyhub.zip\n"), hex)
        XCTAssertEqual(UpdateFeed.checksum(in: hex.uppercased()), hex)
        XCTAssertNil(UpdateFeed.checksum(in: "abc  ponyhub.zip"))
        XCTAssertNil(UpdateFeed.checksum(in: ""))
    }
}
