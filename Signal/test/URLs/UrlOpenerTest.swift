//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

class UrlOpenerTest: XCTestCase {
    func testCanOpenWhenNotRegistered() {
        // We need to be able to parse URLs before global state has been
        // initialized. There's no perfect way to test for this, but we can
        // enumerate all the different parsers we may execute & ensure that they
        // can all return a result before we've created any global state.
        let urlsToTest: [String] = [
            "https://signal.me/#p/+16505550100",
            "https://signal.art/addstickers/#pack_id=00000000000000000000000000000000&pack_key=0000000000000000000000000000000000000000000000000000000000000000",
            "https://signal.group",
            "https://signal.tube/#example.com",
        ]
        for urlToTest in urlsToTest {
            XCTAssertNotNil(UrlOpener.parseUrl(URL(string: urlToTest)!), "\(urlToTest)")
        }
    }
}
