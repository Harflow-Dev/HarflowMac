@testable import PbUI
import Testing

@Suite struct AccessLabelTests {

    @Test(arguments: [
        ("read_only", "Read-only"),
        ("write_in_repo", "Can edit this repo"),
        ("publish", "Can publish"),
        ("unrestricted", "Full access")
    ])
    func givenAKnownFreedom_whenLabelled_thenReturnsPlainLanguage(freedom: String, expected: String) {
        // given / when
        let text = AccessLabel.text(freedom: freedom)

        // then
        #expect(text == expected)
    }

    @Test func givenAnUnknownFreedom_whenLabelled_thenReturnsTheRawString() {
        // given / when / then
        #expect(AccessLabel.text(freedom: "sandboxed") == "sandboxed")
    }
}
