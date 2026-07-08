import Testing
@testable import FirmamentKit

@Suite("Smoke")
struct SmokeTests {
    @Test("package imports and reports a version")
    func versionExists() {
        #expect(!FirmamentKit.version.isEmpty)
    }
}
