//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

extension NSItemProvider {

    func loadFile(forTypeIdentifier typeIdentifier: String) -> (Progress, Promise<URL>) {
        let copyProgress = Progress(totalUnitCount: 1)

        let loadFuture = Future<URL>()
        let loadProgress = loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
            switch (url, error) {
            case (let url?, nil):
                // The fileURL that Foundation provides is only supposed to live as long
                // as this completion handler.
                do {
                    let ownedPath = try SignalAttachment.copyToImportTempDir(url: url)
                    loadFuture.resolve(ownedPath)
                } catch {
                    loadFuture.reject(error)
                }

            case (_, let error?):
                loadFuture.reject(error)

            case (nil, nil):
                loadFuture.reject(OWSAssertionError("Unknown error"))
            }

            copyProgress.completedUnitCount = 1
        }

        let totalProgress = Progress.discreteProgress(totalUnitCount: 10)
        totalProgress.addChild(loadProgress, withPendingUnitCount: 9)
        totalProgress.addChild(copyProgress, withPendingUnitCount: 1)
        return (totalProgress, Promise(future: loadFuture))
    }

    func loadData(forTypeIdentifier typeIdentifier: String) -> (Progress, Promise<Data>) {
        let loadFuture = Future<Data>()
        let loadProgress = loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            switch (data, error) {
            case (let data?, nil):
                loadFuture.resolve(data)

            case (_, let error?):
                loadFuture.reject(error)

            case (nil, nil):
                loadFuture.reject(OWSAssertionError("Unknown error"))
            }
        }
        return (loadProgress, Promise(future: loadFuture))

    }
}
