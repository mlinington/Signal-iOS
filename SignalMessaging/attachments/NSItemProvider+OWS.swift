//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import SignalServiceKit
import CoreServices
import UniformTypeIdentifiers

// MARK: - NSItemProvider -> AttachmentPayload

public extension NSItemProvider {
    enum ItemType: CaseIterable {
        case movie
        case image
        case webUrl
        case contact
        case text
        case anyItem

        fileprivate var typeIdentifier: String {
            switch self {
            // These identifiers are checked directly
            case .movie:    return OWSUTType.movie.identifier
            case .image:    return OWSUTType.image.identifier
            case .contact:  return OWSUTType.contact.identifier
            case .text:     return OWSUTType.text.identifier

            // These identifiers are also checked directly, but there's some additional
            // conformance checks made in hasItem(of:) as well
            case .webUrl:   return OWSUTType.url.identifier
            case .anyItem:  return OWSUTType.content.identifier
            }
        }
    }

    func hasItem(of type: ItemType) -> Bool {
        switch type {
        case .movie, .image, .contact, .text:
            return hasItemConformingToTypeIdentifier(type.typeIdentifier)

        case .webUrl:
            // The fileURL type identifier (public.file-url) itself conforms to
            // the URL type identifier (public.url). There's no identifier specifying
            // *just* a webUrl. A best effort fix is to consider there to be a webUrl
            // item if there's an item matching public.url, but no item matching
            // public.file-url
            let hasUrl = hasItemConformingToTypeIdentifier(OWSUTType.url.identifier)
            let hasFileUrl = hasItemConformingToTypeIdentifier(OWSUTType.fileUrl.identifier)
            return hasUrl && !hasFileUrl

        case .anyItem:
            // From UTCoreTypes.h...
            // [UTType.content is] for anything containing user-viewable document content
            // (documents, pasteboard data, and document packages.)
            // Types describing files or packages must also conform to `UTType.data` or
            // `UTType.package` in order for the system to bind documents to them.

            let isContent = hasItemConformingToTypeIdentifier(OWSUTType.content.identifier)
            let isData = hasItemConformingToTypeIdentifier(OWSUTType.data.identifier)
            let isPackage = hasItemConformingToTypeIdentifier(OWSUTType.package.identifier)
            return isContent && (isData || isPackage)
        }
    }

    private func loadAttachmentDataSource(for type: ItemType) -> (progress: Progress, Promise<DataSource>) {
        switch type {
        case .text:
            let (loadProgress, stringPromise) = loadString(forTypeIdentifier: type.typeIdentifier)
            let dataSourcePromise = stringPromise.map {
                DataSourceValue.dataSource(withOversizeText: $0)
            }
            return (loadProgress, dataSourcePromise)

        case .webUrl:
            let (loadProgress, urlPromise) = loadURL(forTypeIdentifier: type.typeIdentifier)
            let dataSourcePromise = urlPromise.map {
                DataSourceValue.dataSource(withOversizeText: $0.absoluteString)
            }
            return (loadProgress, dataSourcePromise)

        case .image, .movie, .contact, .anyItem:
            let (loadProgress, filePromise) = loadFile(forTypeIdentifier: type.typeIdentifier)
            let dataSourcePromise = filePromise.map { fileURL in
                let dataSource = try DataSourcePath.dataSource(with: fileURL, shouldDeleteOnDeallocation: false)
                dataSource.sourceFilename = fileURL.lastPathComponent
                return dataSource
            }
            return (loadProgress, dataSourcePromise)
        }
    }

    private func buildAttachment(for type: ItemType, using dataSource: DataSource) -> (progress: Progress, Promise<SignalAttachment>) {
        // This replicates existing behavior, but there are a couple things that give me pause here:
        // It seems weird that we're getting the UTI for a file-backed data source from the path extension and not from
        // the URL resources.
        //
        // Here's an example of how I believe this will break:
        // Say I try and share some binary, maybe a zipped folder or something, with the name "data.png". The ItemProvider
        // tells us there's some binary file conforming to public.item and we proceed to import it into our container.
        //
        // Foundation understands this isn't an image and up until this point we understand it's not an image as well.
        // In this case, the ItemType above should be `.anyItem`.
        //
        // Here, now all of a sudden we're going to use the pathExtension to infer a UTType that we already know. And we're
        // going to infer this should be a PNG. The PNG type identifier will be passed into the SignalAttachment initializer and
        // SignalAttachment will do a whole bunch of image validation on a file that we already know isn't an image.
        //
        // TODO: Reconsider how SignalAttachment treats the relationship between type-identifier, file extension, and URLResource
        // reported by Foundation for file-backed data sources.
        let outputUTI = {
            if let dataSourcePath = dataSource as? DataSourcePath,
               let dataUrl = dataSourcePath.dataUrl {
                return MIMETypeUtil.utiType(forFileExtension: dataUrl.pathExtension) ?? OWSUTType.data.identifier
            } else {
                return type.typeIdentifier
            }
        }()

        switch type {
        case .webUrl, .text:
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: outputUTI)
            attachment.isConvertibleToTextMessage = true
            return (Progress.createCompletedChild(), .value(attachment))

        case .contact:
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: outputUTI)
            attachment.isConvertibleToContactShare = true
            return (Progress.createCompletedChild(), .value(attachment))

        case .movie:
            let attachmentPromise: Promise<SignalAttachment>
            let attachmentProgress: Progress
            if SignalAttachment.isVideoThatNeedsCompression(dataSource: dataSource, dataUTI: outputUTI) {
                let (result, session) = SignalAttachment.compressVideoAsMp4(
                    dataSource: dataSource,
                    dataUTI: OWSUTType.movie.identifier)

                attachmentPromise = result
                attachmentProgress = session?.createProgressPoller() ?? Progress.createCompletedChild()
            } else {
                attachmentPromise = Promise.value(SignalAttachment.attachment(dataSource: dataSource, dataUTI: outputUTI))
                attachmentProgress = Progress.createCompletedChild()
            }
            return (attachmentProgress, attachmentPromise)

        case .image, .anyItem:
            let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: outputUTI)
            return (Progress.createCompletedChild(), .value(attachment))
        }
    }

    func attachmentPayload(for type: ItemType) -> (progress: Progress, Promise<SignalAttachment>) {
        guard hasItem(of: type) else { return (Progress.init(), Promise(error: OWSAssertionError(""))) }

        // 75 progress units are allocated to loading of the file/data
        // 25 progress units are allocated to any conversion necessary to get it into a SignalAttachment
        // There's probably a better way to balance this, but this is a fine approximation.
        let totalProgress = Progress.discreteProgress(totalUnitCount: 100)

        let (loadProgress, dataSourcePromise) = loadAttachmentDataSource(for: type)
        totalProgress.addChild(loadProgress, withPendingUnitCount: 75)

        let attachmentPromise = dataSourcePromise.then { dataSource in
            let (attachmentProgress, attachmentPromise) = self.buildAttachment(for: type, using: dataSource)
            totalProgress.addChild(attachmentProgress, withPendingUnitCount: 25)
            return attachmentPromise
        }

        return (totalProgress, attachmentPromise)
    }
}
