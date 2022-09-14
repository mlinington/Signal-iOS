//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import SignalServiceKit
import CoreServices
import UniformTypeIdentifiers

// MARK: - NSItemProvider -> AttachmentPayload

public extension NSItemProvider {
    enum ItemType {
        case movie
        case image
        case webUrl
        case fileUrl
        case contact
        case text
        case pdf
        case pkPass

        /// The type identifier used when checking item conformance on NSItemProvider
        fileprivate var lookupTypeIdentifier: String {
            switch self {
            case .movie:    return OWSUTType.movie.identifier
            case .image:    return OWSUTType.image.identifier
            case .webUrl:   return OWSUTType.url.identifier
            case .fileUrl:  return OWSUTType.fileUrl.identifier
            case .contact:  return OWSUTType.contact.identifier
            case .text:     return OWSUTType.text.identifier
            case .pdf:      return OWSUTType.pdf.identifier
            case .pkPass:   return OWSUTType.passkit.identifier
            }
        }

        /// The type identifier used when loading an item from NSItemProvider
        /// (Why is this different from `lookupTypeIdentifier`? I'm not entirely sure but I'm leaving
        /// this as-is to maintain existing behavior. It's very likely these could be consolidated in the future.
        fileprivate var loadTypeIdentifier: String {
            switch self {
            case .contact:
                return OWSUTType.contact.identifier
            default:
                return lookupTypeIdentifier
            }
        }
    }

    func hasItem(of type: ItemType) -> Bool {
        // The fileURL type identifier (public.file-url) itself conforms to
        // the URL type identifier (public.url). There's no identifier specifying
        // *just* a webUrl. A best effort fix is to consider there to be a webUrl
        // item if there's an item matching public.url, but no item matching
        // public.file-url
        if type == .webUrl, hasItemConformingToTypeIdentifier(ItemType.fileUrl.lookupTypeIdentifier) {
            return false
        } else {
            return hasItemConformingToTypeIdentifier(type.lookupTypeIdentifier)
        }
    }

    func attachmentPayload(for type: ItemType) -> Promise<AttachmentPayload> {
        guard hasItem(of: type) else { return Promise(error: OWSAssertionError("")) }

        switch type {
        case .movie:
            return firstly {
                loadObject(URL.self, forTypeIdentifier: type.loadTypeIdentifier, options: nil)
            }.map { itemUrl in
                if self.isVideoNeedingRelocation(itemUrl: itemUrl) {
                    return .fileUrl(try SignalAttachment.copyToVideoTempDir(url: itemUrl))
                } else {
                    return .fileUrl(itemUrl)
                }
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
            if #available(iOS 14, *), registeredTypeIdentifiers.contains(OWSUTType.heic.identifier) {
                desiredTypeIdentifier = OWSUTType.heic.identifier
            } else {
                desiredTypeIdentifier = type.loadTypeIdentifier
            }

            return firstly {
                loadObject(URL.self, forTypeIdentifier: desiredTypeIdentifier, options: nil).map { .fileUrl($0) }
            }.recover(on: .global()) { error -> Promise<AttachmentPayload> in
                // If a URL wasn't available, fall back to an in-memory image
                // One place this happens is when sharing from the screenshot app on iOS13
                if (error as NSError).isMismatchedClassError {
                    // Should the type identifier used here be the desiredTypeIdentifier from above? Leaving as-is for now.
                    return self.loadObject(UIImage.self, forTypeIdentifier: type.loadTypeIdentifier, options: nil).map { .inMemoryImage($0) }
                } else {
                    throw error
                }
            }
        case .webUrl:
            return loadObject(URL.self, forTypeIdentifier: type.loadTypeIdentifier, options: nil).map { .webUrl($0) }
        case .fileUrl:
            return loadObject(URL.self, forTypeIdentifier: type.loadTypeIdentifier, options: nil).map { .fileUrl($0) }
        case .contact:
            return loadObject(Data.self, forTypeIdentifier: type.loadTypeIdentifier, options: nil).map { .contact($0) }
        case .text:
            return loadObject(String.self, forTypeIdentifier: type.loadTypeIdentifier, options: nil).map { .text($0) }
        case .pdf:
            return loadObject(Data.self, forTypeIdentifier: type.loadTypeIdentifier, options: nil).map { .pdf($0) }
        case .pkPass:
            return loadObject(Data.self, forTypeIdentifier: type.loadTypeIdentifier, options: nil).map { .pkPass($0) }
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
    fileprivate func isVideoNeedingRelocation(itemUrl: URL) -> Bool {
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
        guard utiTypeForURL == OWSUTType.mpeg4.identifier else {
            // Either it's not a video or it was a video which was not auto-converted to mp4.
            // Not affected by the issue.
            return false
        }

        // If video file already existed on disk as an mp4, then the host app didn't need to
        // apply any conversion, so no need to relocate the file.
        return !registeredTypeIdentifiers.contains(OWSUTType.mpeg4.identifier)
    }
}

extension NSItemProvider {

    /// A representation  of an attachment that we own that has been retrieved from an NSItemProvider
    /// If you have an AttachmentPayload, you either have the direct content, or a fileURL somewhere in
    /// out container.
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
                return DataSourceValue.dataSource(with: contactData, utiType: OWSUTType.contact.identifier)
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

        /// Returns a Promise for the attachment and an optional progress reporter. If the progress reporter
        /// is non-nil, this can be used to estimate how close the SignalAttachment promise is to completion
        // Would it be useful to build progress reporting in to Promises? Maybe! For now, they're
        // passed around separately.
        public func loadAsSignalAttachment() -> (promise: Promise<SignalAttachment>, progress: OWSProgressReporting?) {
            let dataSource: DataSource?
            do {
                dataSource = try createDataSource()
            } catch {
                return (Promise(error: error), nil)
            }

            switch self {
            case .webUrl:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: OWSUTType.text.identifier)
                attachment.isConvertibleToTextMessage = true
                return (.value(attachment), nil)

            case .contact:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: OWSUTType.contact.identifier)
                attachment.isConvertibleToContactShare = true
                return (.value(attachment), nil)

            case .text:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: OWSUTType.text.identifier)
                attachment.isConvertibleToTextMessage = true
                return (.value(attachment), nil)

            case .inMemoryImage:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: OWSUTType.png.identifier)
                return (.value(attachment), nil)

            case .pdf:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: OWSUTType.pdf.identifier)
                return (.value(attachment), nil)

            case .pkPass:
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: OWSUTType.passkit.identifier)
                return (.value(attachment), nil)

            case .fileUrl(let itemUrl):
                let utiType = MIMETypeUtil.utiType(forFileExtension: itemUrl.pathExtension) ?? OWSUTType.data.identifier
                guard let dataSource = dataSource else {
                    return (Promise(error: OWSAssertionError("Attachment URL was not a file URL")), nil)
                }

                if SignalAttachment.isVideoThatNeedsCompression(dataSource: dataSource, dataUTI: utiType) {
                    // This can happen, e.g. when sharing a quicktime-video from iCloud drive.
                    return SignalAttachment.compressVideoAsMp4(dataSource: dataSource, dataUTI: utiType)

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

// MARK: - Type Identifiers

// Some type identifiers are exported by Apple, some aren't. Some are, but only on some releases.
// For the identifiers used in this file, this bridges some of the gaps.
private enum OWSUTType {
    case movie
    case image
    case url
    case fileUrl
    case vcard
    case text
    case pdf
    case passkit
    case contact
    case mpeg4
    case png
    case data
    case heic

    var identifier: String {
        if #available(iOS 14, *) {
            switch self {
            case .movie:    return UTType.movie.identifier
            case .image:    return UTType.image.identifier
            case .url:      return UTType.url.identifier
            case .fileUrl:  return UTType.fileURL.identifier
            case .vcard:    return UTType.vCard.identifier
            case .text:     return UTType.text.identifier
            case .pdf:      return UTType.pdf.identifier
            case .passkit:  return "com.apple.pkpass"
            case .contact:  return UTType.contact.identifier
            case .mpeg4:    return UTType.mpeg4Movie.identifier
            case .png:      return UTType.png.identifier
            case .data:     return UTType.data.identifier
            case .heic:     return UTType.heic.identifier
            }
        } else {
            switch self {
            case .movie:    return kUTTypeMovie as String
            case .image:    return kUTTypeImage as String
            case .url:      return kUTTypeURL as String
            case .fileUrl:  return kUTTypeFileURL as String
            case .vcard:    return kUTTypeVCard as String
            case .text:     return kUTTypeText as String
            case .pdf:      return kUTTypePDF as String
            case .passkit:  return "com.apple.pkpass"
            case .contact:  return kUTTypeContact as String
            case .mpeg4:    return kUTTypeMPEG4 as String
            case .png:      return kUTTypePNG as String
            case .data:     return kUTTypeData as String
            case .heic:     return "public.heic"
            }
        }
    }
}

// MARK: - Private helpers

fileprivate extension NSError {
    var isMismatchedClassError: Bool {
        hasDomain(NSItemProvider.errorDomain, code: NSItemProvider.ErrorCode.unexpectedValueClassError.rawValue)
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
