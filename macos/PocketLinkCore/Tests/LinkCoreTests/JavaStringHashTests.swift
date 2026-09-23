import XCTest

@testable import LinkProtocol

final class JavaStringHashTests: XCTestCase {
    func testReferenceValues() {
        XCTAssertEqual(JavaStringHash.hash(""), 0)
        XCTAssertEqual(JavaStringHash.hash("a"), 97)
        XCTAssertEqual(JavaStringHash.hash("abc"), 96_354)
        XCTAssertEqual(JavaStringHash.hash("hello"), 991_623_22)
        XCTAssertEqual(JavaStringHash.hash("abcdef"), -1_424_385_949)
    }

    func testSurrogatePairUsesTwoUTF16CodeUnits() {
        XCTAssertEqual(JavaStringHash.hash("😀"), 1_772_899)
    }

    func testFileIdStyleValues() {
        XCTAssertEqual(JavaStringHash.hash("ab12cd34"), -218_023_036)
        XCTAssertEqual(JavaStringHash.hash("f3a9c1d2"), -1_771_256_895)
    }
}
