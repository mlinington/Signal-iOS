//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import XCTest
@testable import SignalServiceKit

class OWSUTTypeTest: SSKBaseTestSwift {

    private static let knownConformanceMap: [OWSUTType: [OWSUTType]] = {
        // UTTypes live in trees with conformances chaining up to one or more
        // parents. To validate conformance correctness in tests, we build a
        // map of known correct conformances to check against.
        var conformanceMap: [OWSUTType: [OWSUTType]] = [:]

        // Here are the base types we support that only conform to themselves.
        conformanceMap[.item] = [.item]
        conformanceMap[.content] = [.content]
        conformanceMap[.contact] = [.contact]

        // And here's everything else that's a child of one or more other types.
        conformanceMap[.package] = conformanceMap[.item]! + [.package]
        conformanceMap[.data] = conformanceMap[.item]! + [.data]
        conformanceMap[.url] = conformanceMap[.data]! + [.url]
        conformanceMap[.fileUrl] = conformanceMap[.url]! + [.fileUrl]
        conformanceMap[.text] = conformanceMap[.data]! + conformanceMap[.content]! + [.text]
        conformanceMap[.image] = conformanceMap[.data]! + conformanceMap[.content]! + [.image]
        conformanceMap[.movie] = conformanceMap[.data]! + conformanceMap[.content]! + [.movie]

        return conformanceMap
    }()

    private static let allStandard: Set<OWSUTType> = Set([
        .item, .content, .contact, .package, .data, .url, .fileUrl, .text, .image, .movie
    ])


    func testStandardIdentifiers() {
        XCTAssertEqual(OWSUTType.movie.identifier, "public.movie")
        XCTAssertEqual(OWSUTType.image.identifier, "public.image")
        XCTAssertEqual(OWSUTType.contact.identifier, "public.contact")
        XCTAssertEqual(OWSUTType.text.identifier, "public.text")
        XCTAssertEqual(OWSUTType.url.identifier, "public.url")
        XCTAssertEqual(OWSUTType.fileUrl.identifier, "public.file-url")
        XCTAssertEqual(OWSUTType.data.identifier, "public.data")
        XCTAssertEqual(OWSUTType.content.identifier, "public.content")
        XCTAssertEqual(OWSUTType.package.identifier, "com.apple.package")
        XCTAssertEqual(OWSUTType.item.identifier, "public.item")
    }

    func testStandardIdentifiers_Legacy() {
        OWSUTType._test_forceLegacyBehavior {
            testStandardIdentifiers()
        }
    }

    func testCustomIdentifiers() {
        XCTAssertEqual(OWSUTType.other("public.movie").identifier, "public.movie")
        XCTAssertEqual(OWSUTType.other("org.whispersystems.message").identifier, "org.whispersystems.message")
    }

    func testCustomIdentifiers_Legacy() {
        OWSUTType._test_forceLegacyBehavior {
            testCustomIdentifiers()
        }
    }

    func testStandardConformances() {
        for typeUnderTest in Self.allStandard {
            let conformanceSet = Set(Self.knownConformanceMap[typeUnderTest]!)

            for candidateConformance in Self.allStandard {
                let expectConformance = conformanceSet.contains(candidateConformance)
                XCTAssertEqual(typeUnderTest.conforms(to: candidateConformance), expectConformance)
            }
        }
    }

    func testStandardConformances_Legacy() {
        OWSUTType._test_forceLegacyBehavior {
            testStandardConformances()
        }
    }

    func testCustomConformances() {
        let otherItem = OWSUTType.other("public.item")
        let otherContent = OWSUTType.other("public.content")
        let otherData = OWSUTType.other("public.data")
        let otherAVContent = OWSUTType.other("public.audiovisual-content")
        let otherMovie = OWSUTType.other("public.movie")
        let otherVideo = OWSUTType.other("public.video")
        let otherNotReal = OWSUTType.other("public.not-a-real-type-only-used-for-this-test")

        // Here, we use a mixture of well known types with a defined OWSUTType case, custom
        // types, and well-known types shoved into the "other" case
        //
        // This verifies that if a well known type ends up in an "other" case that conformance
        // checks continue to work as expected.
        let testSet: Set<OWSUTType> = Set([
            .item, otherItem,
            .content, otherContent,
            .data, otherData,
            .movie, otherMovie,
            otherAVContent, otherVideo, otherNotReal
        ])

        // First we build up our conformance tree for only the .other() types
        var conformanceMap: [OWSUTType: [OWSUTType]] = [:]
        conformanceMap[otherItem] = [.item, otherItem]
        conformanceMap[otherContent] = [.content, otherContent]
        conformanceMap[otherData] = conformanceMap[otherItem]! + [.data, otherData]
        conformanceMap[otherAVContent] = conformanceMap[otherData]! + conformanceMap[otherContent]! + [otherAVContent]
        conformanceMap[otherMovie] = conformanceMap[otherAVContent]! + [.movie, otherMovie]
        conformanceMap[otherVideo] = conformanceMap[otherMovie]! + [otherVideo]
        conformanceMap[otherNotReal] = [otherNotReal]

        // For any of the non-.other() types that live in our testSet, we just copy over
        // the expected conformances from the non-other variant.
        conformanceMap[.item] = conformanceMap[otherItem]!
        conformanceMap[.content] = conformanceMap[otherContent]!
        conformanceMap[.data] = conformanceMap[otherData]!
        conformanceMap[.movie] = conformanceMap[otherMovie]!

        for typeUnderTest in testSet {
            let conformanceSet = Set(conformanceMap[typeUnderTest]!)
            for candidateConformance in testSet {
                let expectConformance = conformanceSet.contains(candidateConformance)
                XCTAssertEqual(typeUnderTest.conforms(to: candidateConformance), expectConformance)
            }
        }
    }

    func testCustomConformances_Legacy() {
        OWSUTType._test_forceLegacyBehavior {
            testCustomConformances()
        }
    }
}
