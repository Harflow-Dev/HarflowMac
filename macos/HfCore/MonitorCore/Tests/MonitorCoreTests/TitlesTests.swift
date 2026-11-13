import Foundation
@testable import MonitorCore
import Testing

@Suite
struct TitlesTests {
    @Test
    func givenLoginShellOutput_whenParsedForThePath_thenOnlyAWellFormedPathIsReturned() {
        // given / when / then
        #expect(LaunchEnvironment.parseLoginPath(Data("/opt/homebrew/bin:/usr/bin".utf8)) == "/opt/homebrew/bin:/usr/bin")
        #expect(LaunchEnvironment.parseLoginPath(Data("welcome!\n/a:/b".utf8)) == "/a:/b")
        #expect(LaunchEnvironment.parseLoginPath(Data("oops".utf8)) == nil)
        #expect(LaunchEnvironment.parseLoginPath(Data()) == nil)
    }
}
