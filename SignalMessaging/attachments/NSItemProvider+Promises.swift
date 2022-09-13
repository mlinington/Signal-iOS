//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

extension NSItemProvider {

    public func loadObject<T>(
        _ type: T.Type,
        forTypeIdentifier typeIdentifier: String,
        options: [AnyHashable: Any]?
    ) -> Promise<T> {

        Promise { future in
            loadItem(forTypeIdentifier: typeIdentifier, options: options) { codable, error in
                switch (codable, error) {
                case (let matchingType as T, nil):
                    future.resolve(matchingType)
                case (_, let error?):
                    future.reject(error)
                case (_, nil):
                    future.reject(OWSAssertionError("Mismatched type"))
                }
            }
        }
    }
}
