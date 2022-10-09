//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation
import UniformTypeIdentifiers
import CoreServices

public enum OWSUTType: Hashable {
    /// public.contact
    /// base type
    case contact

    /// public.item
    /// base type
    case item

    /// public.content
    /// base type
    case content

    /// public.data
    /// conforms to: public.item
    case data

    /// public.text
    /// conforms to: public.data, public.content
    case text

    /// public.url
    /// conforms to public.data
    case url

    /// public.file-url
    /// conforms to public.url
    case fileUrl

    /// com.apple.package
    /// conforms to: public.directory
    case package

    /// public.image
    /// conforms to: public.data, public.content
    case image

    /// public.movie
    /// conforms to: public.audiovisual-content
    case movie

    /// Anything else not explicitly defined here
    case other(String)

    public var identifier: String {
        if #available(iOS 14, *), !Self.forceLegacyBehavior {
            switch self {
            case .movie:    return UTType.movie.identifier
            case .image:    return UTType.image.identifier
            case .url:      return UTType.url.identifier
            case .fileUrl:  return UTType.fileURL.identifier
            case .text:     return UTType.text.identifier
            case .contact:  return UTType.contact.identifier
            case .data:     return UTType.data.identifier
            case .content:  return UTType.content.identifier
            case .package:  return UTType.package.identifier
            case .item:     return UTType.item.identifier
            case .other(let identifier): return identifier
            }
        } else {
            switch self {
            case .movie:    return kUTTypeMovie as String
            case .image:    return kUTTypeImage as String
            case .url:      return kUTTypeURL as String
            case .fileUrl:  return kUTTypeFileURL as String
            case .text:     return kUTTypeText as String
            case .contact:  return kUTTypeContact as String
            case .data:     return kUTTypeData as String
            case .content:  return kUTTypeContent as String
            case .package:  return kUTTypePackage as String
            case .item:     return kUTTypeItem as String
            case .other(let identifier): return identifier
            }
        }
    }

    public func conforms(to rhs: OWSUTType) -> Bool {
        conforms(to: rhs.identifier)
    }

    public func conforms(to rhsIdentifier: String) -> Bool {
        if #available(iOS 14, *),
           !Self.forceLegacyBehavior,
           let nativeLHS = UTType(identifier),
           let nativeRHS = UTType(rhsIdentifier) {
            return nativeLHS.conforms(to: nativeRHS)
        } else {
            return UTTypeConformsTo(identifier as CFString, rhsIdentifier as CFString)
        }
    }
}

// MARK: Testing Helpers

extension OWSUTType {
    private static let test_forceLegacyKey = "TestFlag_OWSUTType_ForceLegacyBehavior"
    private static var test_forceLegacyFlagTLS: Bool {
        get {
            (Thread.current.threadDictionary[Self.test_forceLegacyKey] as? Bool) == true
        } set {
            let nilIfFalse: Bool? = newValue ? true : nil
            Thread.current.threadDictionary[Self.test_forceLegacyKey] = nilIfFalse
        }
    }

    /// Returns true if currently in a testable enviornment with the thread-local forceLegacyBehavior set.
    fileprivate static var forceLegacyBehavior: Bool {
        OWSIsTestableBuild() && test_forceLegacyFlagTLS
    }

    /// Runs the provided closure while forcing all enclosed OWSUTType behavior to behave as if running
    /// on pre-iOS 14. This only affects the contents of the closure. This will not affect any dispatched code
    /// running in a separate execution context.
    static func _test_forceLegacyBehavior(_ closure: () throws -> Void) rethrows {
        owsAssertDebug(OWSIsTestableBuild())

        let initialValue = Self.test_forceLegacyFlagTLS
        Self.test_forceLegacyFlagTLS = true
        defer { Self.test_forceLegacyFlagTLS = initialValue }

        try closure()
    }
}


public extension URL {
    func fetchTypeIdentifier() throws -> OWSUTType {
        let key: URLResourceKey
        if #available(iOS 14, *) {
            key = .contentTypeKey
        } else {
            key = .typeIdentifierKey
        }

        let fetchedValues = try resourceValues(forKeys: [key])
        let fetchedIdentifier: String?
        if #available(iOS 14, *) {
            fetchedIdentifier = fetchedValues.contentType?.identifier
        } else {
            fetchedIdentifier = fetchedValues.typeIdentifier
        }

        if let fetchedIdentifier {
            return .other(fetchedIdentifier)
        } else {
            throw OWSAssertionError("Missing identifier from fetched resource values")
        }
    }
}
