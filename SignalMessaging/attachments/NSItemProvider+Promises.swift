//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

extension NSItemProvider {

    func loadFile(forTypeIdentifier typeIdentifier: String) -> Promise<URL> {
        Promise { future in
            loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                switch (url, error) {
                case (let url?, nil):
                    // The fileURL that Foundation provides is only supposed to live as long
                    // as this completion handler.
                    do {
                        let ownedPath = try SignalAttachment.copyToImportTempDir(url: url)
                        future.resolve(ownedPath)
                    } catch {
                        future.reject(error)
                    }

                case (_, let error?):
                    future.reject(error)

                case (nil, nil):
                    future.reject(OWSAssertionError("Unknown error"))
                }
            }
        }
    }

    func loadData(forTypeIdentifier typeIdentifier: String) -> Promise<Data> {
        Promise { future in
            loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                switch (data, error) {
                case (let data?, nil):
                    future.resolve(data)

                case (_, let error?):
                    future.reject(error)

                case (nil, nil):
                    future.reject(OWSAssertionError("Unknown error"))
                }
            }
        }
    }

    func loadText(forTypeIdentifier typeIdentifier: String) -> Promise<String> {
        loadData(forTypeIdentifier: typeIdentifier).map { String(decoding: $0, as: UTF8.self) }
    }

    func loadUrl(forTypeIdentifier typeIdentifier: String) -> Promise<URL> {
        loadText(forTypeIdentifier: typeIdentifier).map {
            try URL(string: $0) ?? {
                throw OWSAssertionError("Failed conversion from String to URL")
            }()
        }
    }

    func loadImage(forTypeIdentifier typeIdentifier: String) -> Promise<UIImage> {
        loadData(forTypeIdentifier: typeIdentifier).map {
            try UIImage(data: $0) ?? {
                throw OWSAssertionError("Failed conversion from Data to UIImage")
            }()
        }
    }
}
