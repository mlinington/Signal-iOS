//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import SignalServiceKit
import CoreServices

public enum OWSItemProvider {
    public struct UnloadedItem {
        enum ItemType {
            case movie
            case image
            case webUrl
            case fileUrl
            case contact
            case text
            case pdf
            case pkPass
            case other
        }

        let itemProvider: NSItemProvider
        let itemType: ItemType
    }

    private struct LoadedItem {
        enum LoadedItemPayload {
            case fileUrl(_ fileUrl: URL)
            case inMemoryImage(_ image: UIImage)
            case webUrl(_ webUrl: URL)
            case contact(_ contactData: Data)
            case text(_ text: String)
            case pdf(_ data: Data)
            case pkPass(_ data: Data)

            var debugDescription: String {
                switch self {
                case .fileUrl:
                    return "fileUrl"
                case .inMemoryImage:
                    return "inMemoryImage"
                case .webUrl:
                    return "webUrl"
                case .contact:
                    return "contact"
                case .text:
                    return "text"
                case .pdf:
                    return "pdf"
                case .pkPass:
                    return "pkPass"
                }
            }
        }

        let itemProvider: NSItemProvider
        let payload: LoadedItemPayload

        var customFileName: String? {
            isContactShare ? "Contact.vcf" : nil
        }

        private var isContactShare: Bool {
            if case .contact = payload {
                return true
            } else {
                return false
            }
        }

        var debugDescription: String {
            payload.debugDescription
        }

        fileprivate func asAttachmentPayload() throws -> NSItemProvider.AttachmentPayload {
            switch payload {
            case .fileUrl(let fileUrl):
                do {
                    if OWSItemProvider.isVideoNeedingRelocation(itemProvider: itemProvider, itemUrl: fileUrl) {
                        return .fileUrl(try SignalAttachment.copyToVideoTempDir(url: fileUrl))
                    } else {
                        return .fileUrl(fileUrl)
                    }
                } catch {
                    throw OWSAssertionError("Could not copy video")
                }
            case .inMemoryImage(let image): return .inMemoryImage(image)
            case .webUrl(let webUrl): return .webUrl(webUrl)
            case .contact(let contactData): return .contact(contactData)
            case .text(let text): return .text(text)
            case .pdf(let data): return .pdf(data)
            case .pkPass(let data): return .pkPass(data)
            }
        }
    }


    public static func itemsToLoad(inputItems: [NSExtensionItem]) throws -> [UnloadedItem] {
        for inputItem in inputItems {
            guard let itemProviders = inputItem.attachments else {
                throw OWSAssertionError("attachments was empty")
            }

            let itemsToLoad: [UnloadedItem] = itemProviders.map { itemProvider in
                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeMovie as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .movie)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeImage as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .image)
                }

                // A single inputItem can have multiple attachments, e.g. sharing from Firefox gives
                // one url attachment and another text attachment, where the url would be https://some-news.com/articles/123-cat-stuck-in-tree
                // and the text attachment would be something like "Breaking news - cat stuck in tree"
                //
                // FIXME: For now, we prefer the URL provider and discard the text provider, since it's more useful to share the URL than the caption
                // but we *should* include both. This will be a bigger change though since our share extension is currently heavily predicated
                // on one itemProvider per share.
                if isUrlItem(itemProvider: itemProvider) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .webUrl)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeFileURL as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .fileUrl)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeVCard as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .contact)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypeText as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .text)
                }

                if itemProvider.hasItemConformingToTypeIdentifier(kUTTypePDF as String) {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .pdf)
                }

                if itemProvider.hasItemConformingToTypeIdentifier("com.apple.pkpass") {
                    return UnloadedItem(itemProvider: itemProvider, itemType: .pkPass)
                }

                owsFailDebug("unexpected share item: \(itemProvider)")
                return UnloadedItem(itemProvider: itemProvider, itemType: .other)
            }

            // Prefer a URL if available. If there's an image item and a URL item,
            // the URL is generally more useful. e.g. when sharing an app from the
            // App Store the image would be the app icon and the URL is the link
            // to the application.
            if let urlItem = itemsToLoad.first(where: { $0.itemType == .webUrl }) {
                return [urlItem]
            }

            let visualMediaItems = itemsToLoad.filter { isVisualMediaItem(itemProvider: $0.itemProvider) }

            // We only allow sharing 1 item, unless they are visual media items. And if they are
            // visualMediaItems we share *only* the visual media items - a mix of visual and non
            // visual items is not supported.
            if visualMediaItems.count > 0 {
                return visualMediaItems
            } else if itemsToLoad.count > 0 {
                return Array(itemsToLoad.prefix(1))
            }
        }
        throw OWSAssertionError("no input item")
    }

    public static func loadItems(unloadedItems: [UnloadedItem]) -> Promise<[NSItemProvider.AttachmentPayload]> {
        let loadPromises: [Promise<NSItemProvider.AttachmentPayload>] = unloadedItems.map { unloadedItem in
            loadItem(unloadedItem: unloadedItem).map { try $0.asAttachmentPayload() }
        }

        return Promise.when(fulfilled: loadPromises)
    }

    public static func buildAttachments(loadedItems: [NSItemProvider.AttachmentPayload]) -> Promise<[SignalAttachment]> {
        var attachmentPromises = [Promise<SignalAttachment>]()
        for loadedItem in loadedItems {
            attachmentPromises.append(firstly(on: .sharedUserInitiated) { () -> Promise<SignalAttachment> in
                loadedItem.loadAsSignalAttachment().0
            })
        }
        return Promise.when(fulfilled: attachmentPromises)
    }

    private static func itemMatchesSpecificUtiType(itemProvider: NSItemProvider, utiType: String) -> Bool {
        // URLs, contacts and other special items have to be detected separately.
        // Many shares (e.g. pdfs) will register many UTI types and/or conform to kUTTypeData.
        guard itemProvider.registeredTypeIdentifiers.count == 1 else {
            return false
        }
        guard let firstUtiType = itemProvider.registeredTypeIdentifiers.first else {
            return false
        }
        return firstUtiType == utiType
    }

    private static func isVisualMediaItem(itemProvider: NSItemProvider) -> Bool {
        return (itemProvider.hasItemConformingToTypeIdentifier(kUTTypeImage as String) ||
            itemProvider.hasItemConformingToTypeIdentifier(kUTTypeMovie as String))
    }

    private static func isUrlItem(itemProvider: NSItemProvider) -> Bool {
        return itemMatchesSpecificUtiType(itemProvider: itemProvider,
                                          utiType: kUTTypeURL as String)
    }

    private static func isContactItem(itemProvider: NSItemProvider) -> Bool {
        return itemMatchesSpecificUtiType(itemProvider: itemProvider,
                                          utiType: kUTTypeContact as String)
    }

    private static func loadItem(unloadedItem: UnloadedItem) -> Promise<LoadedItem> {
        Logger.info("unloadedItem: \(unloadedItem)")

        let itemProvider = unloadedItem.itemProvider

        switch unloadedItem.itemType {
        case .movie:
            return itemProvider.loadObject(URL.self, forTypeIdentifier: kUTTypeMovie as String, options: nil).map { fileUrl in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .fileUrl(fileUrl))

            }
        case .image:
            // When multiple image formats are available, kUTTypeImage will
            // defer to jpeg when possible. On iPhone 12 Pro, when 'heic'
            // and 'jpeg' are the available options, the 'jpeg' data breaks
            // UIImage (and underlying) in some unclear way such that trying
            // to perform any kind of transformation on the image (such as
            // resizing) causes memory to balloon uncontrolled. Luckily,
            // iOS 14 provides native UIImage support for heic and iPhone
            // 12s can only be running iOS 14+, so we can request the heic
            // format directly, which behaves correctly for all our needs.
            // A radar has been opened with apple reporting this issue.
            let desiredTypeIdentifier: String
            if #available(iOS 14, *), itemProvider.registeredTypeIdentifiers.contains("public.heic") {
                desiredTypeIdentifier = "public.heic"
            } else {
                desiredTypeIdentifier = kUTTypeImage as String
            }

            return itemProvider.loadObject(URL.self, forTypeIdentifier: desiredTypeIdentifier, options: nil).map { fileUrl in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .fileUrl(fileUrl))
            }.recover(on: .global()) { error -> Promise<LoadedItem> in
                let nsError = error as NSError
                assert(nsError.domain == NSItemProvider.errorDomain)
                assert(nsError.code == NSItemProvider.ErrorCode.unexpectedValueClassError.rawValue)

                // If a URL wasn't available, fall back to an in-memory image.
                // One place this happens is when sharing from the screenshot app on iOS13.
                return itemProvider.loadObject(UIImage.self, forTypeIdentifier: kUTTypeImage as String, options: nil).map { image in
                    LoadedItem(itemProvider: unloadedItem.itemProvider,
                               payload: .inMemoryImage(image))
                }
            }
        case .webUrl:
            return itemProvider.loadObject(URL.self, forTypeIdentifier: kUTTypeURL as String, options: nil).map { url in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .webUrl(url))
            }
        case .fileUrl:
            return itemProvider.loadObject(URL.self, forTypeIdentifier: kUTTypeFileURL as String, options: nil).map { fileUrl in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .fileUrl(fileUrl))
            }
        case .contact:
            return itemProvider.loadObject(Data.self, forTypeIdentifier: kUTTypeContact as String, options: nil).map { contactData in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .contact(contactData))
            }
        case .text:
            return itemProvider.loadObject(String.self, forTypeIdentifier: kUTTypeText as String, options: nil).map { text in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .text(text))
            }
        case .pdf:
            return itemProvider.loadObject(Data.self, forTypeIdentifier: kUTTypePDF as String, options: nil).map { data in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .pdf(data))
            }
        case .pkPass:
            return itemProvider.loadObject(Data.self, forTypeIdentifier: "com.apple.pkpass", options: nil).map { data in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .pkPass(data))
            }
        case .other:
            return itemProvider.loadObject(URL.self, forTypeIdentifier: kUTTypeFileURL as String, options: nil).map { fileUrl in
                LoadedItem(itemProvider: unloadedItem.itemProvider,
                           payload: .fileUrl(fileUrl))
            }
        }
    }

    // Some host apps (e.g. iOS Photos.app) sometimes auto-converts some video formats (e.g. com.apple.quicktime-movie)
    // into mp4s as part of the NSItemProvider `loadItem` API. (Some files the Photo's app doesn't auto-convert)
    //
    // However, when using this url to the converted item, AVFoundation operations such as generating a
    // preview image and playing the url in the AVMoviePlayer fails with an unhelpful error: "The operation could not be completed"
    //
    // We can work around this by first copying the media into our container.
    //
    // I don't understand why this is, and I haven't found any relevant documentation in the NSItemProvider
    // or AVFoundation docs.
    //
    // Notes:
    //
    // These operations succeed when sending a video which initially existed on disk as an mp4.
    // (e.g. Alice sends a video to Bob through the main app, which ensures it's an mp4. Bob saves it, then re-shares it)
    //
    // I *did* verify that the size and SHA256 sum of the original url matches that of the copied url. So there
    // is no difference between the contents of the file, yet one works one doesn't.
    // Perhaps the AVFoundation APIs require some extra file system permssion we don't have in the
    // passed through URL.
    private static func isVideoNeedingRelocation(itemProvider: NSItemProvider, itemUrl: URL) -> Bool {
        let pathExtension = itemUrl.pathExtension
        guard pathExtension.count > 0 else {
            Logger.verbose("item URL has no file extension: \(itemUrl).")
            return false
        }
        guard let utiTypeForURL = MIMETypeUtil.utiType(forFileExtension: pathExtension) else {
            Logger.verbose("item has unknown UTI type: \(itemUrl).")
            return false
        }
        Logger.verbose("utiTypeForURL: \(utiTypeForURL)")
        guard utiTypeForURL == kUTTypeMPEG4 as String else {
            // Either it's not a video or it was a video which was not auto-converted to mp4.
            // Not affected by the issue.
            return false
        }

        // If video file already existed on disk as an mp4, then the host app didn't need to
        // apply any conversion, so no need to relocate the file.
        return !itemProvider.registeredTypeIdentifiers.contains(kUTTypeMPEG4 as String)
    }
}

extension NSItemProvider {
    public enum AttachmentPayload {
        case fileUrl(_ fileUrl: URL)
        case inMemoryImage(_ image: UIImage)
        case webUrl(_ webUrl: URL)
        case contact(_ contactData: Data)
        case text(_ text: String)
        case pdf(_ data: Data)
        case pkPass(_ data: Data)

        var debugDescription: String {
            switch self {
            case .fileUrl:
                return "fileUrl"
            case .inMemoryImage:
                return "inMemoryImage"
            case .webUrl:
                return "webUrl"
            case .contact:
                return "contact"
            case .text:
                return "text"
            case .pdf:
                return "pdf"
            case .pkPass:
                return "pkPass"
            }
        }

        private func createDataSource() throws -> DataSource? {
            switch self {
            case .webUrl(let webUrl):
                return DataSourceValue.dataSource(withOversizeText: webUrl.absoluteString)
            case .contact(let contactData):
                return DataSourceValue.dataSource(with: contactData, utiType: kUTTypeContact as String)
            case .text(let text):
                return DataSourceValue.dataSource(withOversizeText: text)
            case .inMemoryImage(let image):
                if let pngData = image.pngData() {
                    return DataSourceValue.dataSource(with: pngData, fileExtension: "png")
                } else {
                    throw OWSAssertionError("pngData was unexpectedly nil")
                }
            case .pdf(let pdf):
                return DataSourceValue.dataSource(with: pdf, fileExtension: "pdf")
            case .pkPass(let pkPass):
                return DataSourceValue.dataSource(with: pkPass, fileExtension: "pkpass")
            case .fileUrl(let itemUrl):
                do {
                    let dataSource = try DataSourcePath.dataSource(with: itemUrl, shouldDeleteOnDeallocation: false)
                    dataSource.sourceFilename = itemUrl.lastPathComponent
                    return dataSource
                } catch {
                    throw OWSAssertionError("Attachment URL was not a file URL")
                }
            }
        }

        /// Creates an attachment with from a generic "loaded item". The data source
        /// backing the returned attachment must "own" the data it provides - i.e.,
        /// it must not refer to data/files that other components refer to.

        /// Returns a Promise for the attachment and an optional progress value. If the progress
        /// is non-nil, this can be used to estimate how close the SignalAttachment promise is
        /// to completion
        // Would it be useful to build progress reporting in to Promises? Maybe! For now, they're
        // passed around separately.
        func loadAsSignalAttachment() -> (Promise<SignalAttachment>, Float?) {
            let dataSource: DataSource?
            do {
                dataSource = try createDataSource()
            } catch {
                return (Promise(error: error), nil)
            }

            switch self {
            case .webUrl:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypeText as String)
                attachment.isConvertibleToTextMessage = true
                return (.value(attachment), nil)

            case .contact:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypeContact as String)
                attachment.isConvertibleToContactShare = true
                return (.value(attachment), nil)

            case .text:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypeText as String)
                attachment.isConvertibleToTextMessage = true
                return (.value(attachment), nil)

            case .inMemoryImage:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypePNG as String)
                return (.value(attachment), nil)

            case .pdf:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: kUTTypePDF as String)
                return (.value(attachment), nil)

            case .pkPass:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: "com.apple.pkpass")
                return (.value(attachment), nil)

            case .fileUrl(let itemUrl):
                let utiType = MIMETypeUtil.utiType(forFileExtension: itemUrl.pathExtension) ?? kUTTypeData as String
                guard let dataSource = dataSource else {
                    return (Promise(error: OWSAssertionError("Attachment URL was not a file URL")), nil)
                }

                if SignalAttachment.isVideoThatNeedsCompression(dataSource: dataSource, dataUTI: utiType) {
                    // This can happen, e.g. when sharing a quicktime-video from iCloud drive.
                    let (promise, exportSession) = SignalAttachment.compressVideoAsMp4(dataSource: dataSource, dataUTI: utiType)
                    // MICHLIN FIX: PROGRESS REPORTING
                    return (promise, exportSession?.progress)

                } else {
                    let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: utiType)

                    // If we already own the attachment's data - i.e. we have copied it
                    // from the URL originally passed in, and therefore no one else can
                    // be referencing it - we can return the attachment as-is...
                    if attachment.dataUrl != itemUrl {
                        return (Promise.value(attachment), nil)
                    } else {
                        // ...otherwise, we should clone the attachment to ensure we aren't
                        // touching data someone else might be referencing.
                        return (attachment.clonePromise(), nil)
                    }
                }
            }
        }
    }
}

fileprivate extension SignalAttachment {
    func clonePromise() -> Promise<SignalAttachment> {
        do {
            return .value(try cloneAttachment())
        } catch {
            return Promise(error: error)
        }
    }
}


