//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import UIKit

import SignalMessaging
import PureLayout
import SignalServiceKit
import Intents
import CoreServices
import SignalUI

@objc
public class ShareViewController: UIViewController, ShareViewDelegate, SAEFailedViewDelegate {

    enum ShareViewControllerError: Error, Equatable {
        case assertionError(description: String)
        case unsupportedMedia
        case notRegistered
        case obsoleteShare
        case tooManyAttachments
    }

    private var hasInitialRootViewController = false
    private var isReadyForAppExtensions = false
    private var areVersionMigrationsComplete = false

    private var progressPoller: ProgressPoller?
    lazy var loadViewController = SAELoadViewController(delegate: self)

    public var shareViewNavigationController: OWSNavigationController?

    override open func loadView() {
        super.loadView()

        // This should be the first thing we do.
        let appContext = ShareAppExtensionContext(rootViewController: self)
        SetCurrentAppContext(appContext)

        DebugLogger.shared().enableTTYLogging()
        if OWSPreferences.isLoggingEnabled() || _isDebugAssertConfiguration() {
            DebugLogger.shared().enableFileLogging()
        }

        Logger.info("")

        _ = AppVersion.shared()

        Cryptography.seedRandom()

        // We don't need to use DeviceSleepManager in the SAE.

        // We don't need to use applySignalAppearence in the SAE.

        if CurrentAppContext().isRunningTests {
            // TODO: Do we need to implement isRunningTests in the SAE context?
            return
        }

        // We shouldn't set up our environment until after we've consulted isReadyForAppExtensions.
        AppSetup.setupEnvironment(
            paymentsEvents: PaymentsEventsAppExtension(),
            mobileCoinHelper: MobileCoinHelperMinimal(),
            webSocketFactory: WebSocketFactoryNative(),
            appSpecificSingletonBlock: {
            // Create SUIEnvironment.
            SUIEnvironment.shared.setup()
            SSKEnvironment.shared.callMessageHandlerRef = NoopCallMessageHandler()
            SSKEnvironment.shared.notificationsManagerRef = NoopNotificationsManager()
            Environment.shared.lightweightCallManagerRef = LightweightCallManager()
        },
        migrationCompletion: { [weak self] error in
            AssertIsOnMainThread()

            guard let strongSelf = self else { return }

            if let error = error {
                owsFailDebug("Error \(error)")
                strongSelf.showNotReadyView()
                return
            }

            // performUpdateCheck must be invoked after Environment has been initialized because
            // upgrade process may depend on Environment.
            strongSelf.versionMigrationsDidComplete()
        })

        let shareViewNavigationController = OWSNavigationController()
        shareViewNavigationController.presentationController?.delegate = self
        shareViewNavigationController.delegate = self
        self.shareViewNavigationController = shareViewNavigationController

        // Don't display load screen immediately, in hopes that we can avoid it altogether.
        Guarantee.after(seconds: 0.8).done { [weak self] in
            AssertIsOnMainThread()

            guard let strongSelf = self else { return }
            guard strongSelf.presentedViewController == nil else {
                Logger.debug("setup completed quickly, no need to present load view controller.")
                return
            }

            Logger.debug("setup is slow - showing loading screen")
            strongSelf.showPrimaryViewController(strongSelf.loadViewController)
        }

        // We don't need to use "screen protection" in the SAE.

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(storageIsReady),
                                               name: .StorageIsReady,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(registrationStateDidChange),
                                               name: .registrationStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(owsApplicationWillEnterForeground),
                                               name: .OWSApplicationWillEnterForeground,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: .OWSApplicationDidEnterBackground,
                                               object: nil)

        Logger.info("completed.")

        OWSAnalytics.appLaunchDidBegin()
    }

    deinit {
        Logger.info("deinit")

        // Share extensions reside in a process that may be reused between usages.
        // That isn't safe; the codebase is full of statics (e.g. singletons) which
        // we can't easily clean up.
        ExitShareExtension()
    }

    @objc
    public func applicationDidEnterBackground() {
        AssertIsOnMainThread()

        Logger.info("")

        if OWSScreenLock.shared.isScreenLockEnabled() {

            Logger.info("dismissing.")

            self.dismiss(animated: false) { [weak self] in
                AssertIsOnMainThread()
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }

    private func activate() {
        AssertIsOnMainThread()

        Logger.debug("")

        // We don't need to use "screen protection" in the SAE.

        ensureRootViewController()

        // Always check prekeys after app launches, and sometimes check on app activation.
        TSPreKeyManager.checkPreKeysIfNecessary()

        // We don't need to use RTCInitializeSSL() in the SAE.

        if tsAccountManager.isRegistered {
            Logger.info("running post launch block for registered user: \(String(describing: TSAccountManager.localAddress))")
        } else {
            Logger.info("running post launch block for unregistered user.")

            // We don't need to update the app icon badge number in the SAE.

            // We don't need to prod the SocketManager in the SAE.
        }

        if tsAccountManager.isRegistered {
            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }
                Logger.info("running post launch block for registered user: \(String(describing: TSAccountManager.localAddress))")

                // We don't need to use the SocketManager in the SAE.

                // TODO: Re-enable when system contact fetching uses less memory.
                // Environment.shared.contactsManager.fetchSystemContactsOnceIfAlreadyAuthorized()

                // We don't need to fetch messages in the SAE.

                // We don't need to use OWSSyncPushTokensJob in the SAE.
            }
        }
    }

    @objc
    func versionMigrationsDidComplete() {
        AssertIsOnMainThread()

        Logger.debug("")

        areVersionMigrationsComplete = true

        checkIsAppReady()
    }

    @objc
    func storageIsReady() {
        AssertIsOnMainThread()

        Logger.debug("")

        checkIsAppReady()
    }

    @objc
    func checkIsAppReady() {
        AssertIsOnMainThread()

        // App isn't ready until storage is ready AND all version migrations are complete.
        guard areVersionMigrationsComplete else {
            return
        }
        guard storageCoordinator.isStorageReady else {
            return
        }
        guard !AppReadiness.isAppReady else {
            // Only mark the app as ready once.
            return
        }

        // We don't need to use LaunchJobs in the SAE.

        Logger.debug("")

        // Note that this does much more than set a flag;
        // it will also run all deferred blocks.
        AppReadiness.setAppIsReady()

        if tsAccountManager.isRegistered {
            Logger.info("localAddress: \(String(describing: TSAccountManager.localAddress))")

            // We don't need to use messageFetcherJob in the SAE.

            // We don't need to use SyncPushTokensJob in the SAE.
        }

        // We don't need to use DeviceSleepManager in the SAE.

        AppVersion.shared().saeLaunchDidComplete()

        ensureRootViewController()

        // We don't need to use OWSOrphanDataCleaner in the SAE.

        // We don't need to fetch the local profile in the SAE
    }

    @objc
    func registrationStateDidChange() {
        AssertIsOnMainThread()

        Logger.debug("")

        if tsAccountManager.isRegistered {
            Logger.info("localAddress: \(String(describing: TSAccountManager.localAddress))")

            // We don't need to use ExperienceUpgradeFinder in the SAE.

            // We don't need to use OWSDisappearingMessagesJob in the SAE.
        }
    }

    private func ensureRootViewController() {
        AssertIsOnMainThread()

        Logger.debug("")

        guard AppReadiness.isAppReady else {
            return
        }
        guard !hasInitialRootViewController else {
            return
        }
        hasInitialRootViewController = true

        Logger.info("Presenting initial root view controller")

        if OWSScreenLock.shared.isScreenLockEnabled() {
            presentScreenLock()
        } else {
            presentContentView()
        }
    }

    private func presentContentView() {
        AssertIsOnMainThread()

        Logger.debug("")

        Logger.info("Presenting content view")

        guard tsAccountManager.isRegistered else {
            showNotRegisteredView()
            return
        }

        let localProfileExists = databaseStorage.read { transaction in
            return self.profileManager.localProfileExists(with: transaction)
        }
        guard localProfileExists else {
            // This is a rare edge case, but we want to ensure that the user
            // has already saved their local profile key in the main app.
            showNotReadyView()
            return
        }

        guard tsAccountManager.isOnboarded() else {
            showNotReadyView()
            return
        }

        buildAttachmentsAndPresentConversationPicker()
        // We don't use the AppUpdateNag in the SAE.
    }

    // MARK: Error Views

    private func showNotReadyView() {
        AssertIsOnMainThread()

        let failureTitle = OWSLocalizedString("SHARE_EXTENSION_NOT_YET_MIGRATED_TITLE",
                                             comment: "Title indicating that the share extension cannot be used until the main app has been launched at least once.")
        let failureMessage = OWSLocalizedString("SHARE_EXTENSION_NOT_YET_MIGRATED_MESSAGE",
                                               comment: "Message indicating that the share extension cannot be used until the main app has been launched at least once.")
        showErrorView(title: failureTitle, message: failureMessage)
    }

    private func showNotRegisteredView() {
        AssertIsOnMainThread()

        let failureTitle = OWSLocalizedString("SHARE_EXTENSION_NOT_REGISTERED_TITLE",
                                             comment: "Title indicating that the share extension cannot be used until the user has registered in the main app.")
        let failureMessage = OWSLocalizedString("SHARE_EXTENSION_NOT_REGISTERED_MESSAGE",
                                               comment: "Message indicating that the share extension cannot be used until the user has registered in the main app.")
        showErrorView(title: failureTitle, message: failureMessage)
    }

    private func showErrorView(title: String, message: String) {
        AssertIsOnMainThread()

        let viewController = SAEFailedViewController(delegate: self, title: title, message: message)

        let navigationController = UINavigationController()
        navigationController.presentationController?.delegate = self
        navigationController.setViewControllers([viewController], animated: false)
        if self.presentedViewController == nil {
            Logger.debug("presenting modally: \(viewController)")
            self.present(navigationController, animated: true)
        } else {
            owsFailDebug("modal already presented. swapping modal content for: \(viewController)")
            assert(self.presentedViewController == navigationController)
        }
    }

    // MARK: View Lifecycle

    override open func viewDidLoad() {
        super.viewDidLoad()

        Logger.debug("")

        if isReadyForAppExtensions {
            AppReadiness.runNowOrWhenAppDidBecomeReadySync { [weak self] in
                AssertIsOnMainThread()
                self?.activate()
            }
        }
    }

    override open func viewWillAppear(_ animated: Bool) {
        Logger.debug("")

        super.viewWillAppear(animated)
    }

    override open func viewDidAppear(_ animated: Bool) {
        Logger.debug("")

        super.viewDidAppear(animated)
    }

    override open func viewWillDisappear(_ animated: Bool) {
        Logger.debug("")

        super.viewWillDisappear(animated)

        Logger.flush()

        // Share extensions reside in a process that may be reused between usages.
        // That isn't safe; the codebase is full of statics (e.g. singletons) which
        // we can't easily clean up.
        //
        // We do this here, because since iOS 13 `viewDidDisappear` is never called.
        DispatchQueue.main.async { ExitShareExtension() }
    }

    @objc
    func owsApplicationWillEnterForeground() throws {
        AssertIsOnMainThread()

        Logger.debug("")

        // If a user unregisters in the main app, the SAE should shut down
        // immediately.
        guard !tsAccountManager.isRegistered else {
            // If user is registered, do nothing.
            return
        }
        guard let shareViewNavigationController = shareViewNavigationController else {
            owsFailDebug("Missing shareViewNavigationController")
            return
        }
        guard let firstViewController = shareViewNavigationController.viewControllers.first else {
            // If no view has been presented yet, do nothing.
            return
        }
        if firstViewController is SAEFailedViewController {
            // If root view is an error view, do nothing.
            return
        }
        throw ShareViewControllerError.notRegistered
    }

    // MARK: ShareViewDelegate, SAEFailedViewDelegate

    public func shareViewWasUnlocked() {
        Logger.info("")

        presentContentView()
    }

    public func shareViewWasCompleted() {
        Logger.info("")

        self.dismiss(animated: true) { [weak self] in
            AssertIsOnMainThread()
            guard let strongSelf = self else { return }
            strongSelf.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    public func shareViewWasCancelled() {
        Logger.info("")

        self.dismiss(animated: true) { [weak self] in
            AssertIsOnMainThread()
            guard let strongSelf = self else { return }
            strongSelf.extensionContext?.cancelRequest(withError: ShareViewControllerError.obsoleteShare)
        }
    }

    public func shareViewFailed(error: Error) {
        owsFailDebug("Error: \(error)")

        self.dismiss(animated: true) { [weak self] in
            AssertIsOnMainThread()
            guard let strongSelf = self else { return }
            strongSelf.extensionContext?.cancelRequest(withError: error)
        }
    }

    // MARK: Helpers

    // This view controller is not visible to the user. It exists to intercept touches, set up the
    // extensions dependencies, and eventually present a visible view to the user.
    // For speed of presentation, we only present a single modal, and if it's already been presented
    // we swap out the contents.
    // e.g. if loading is taking a while, the user will see the load screen presented with a modal
    // animation. Next, when loading completes, the load view will be switched out for the contact
    // picker view.
    private func showPrimaryViewController(_ viewController: UIViewController) {
        AssertIsOnMainThread()

        guard let shareViewNavigationController = shareViewNavigationController else {
            owsFailDebug("Missing shareViewNavigationController")
            return
        }
        shareViewNavigationController.setViewControllers([viewController], animated: true)
        if self.presentedViewController == nil {
            Logger.debug("presenting modally: \(viewController)")
            self.present(shareViewNavigationController, animated: true)
        } else {
            Logger.debug("modal already presented. swapping modal content for: \(viewController)")
            assert(self.presentedViewController == shareViewNavigationController)
        }
    }

    private lazy var conversationPicker = SharingThreadPickerViewController(shareViewDelegate: self)
    private func buildAttachmentsAndPresentConversationPicker() {
        let selectedThread: TSThread?
        if #available(iOS 13, *),
           let intent = extensionContext?.intent as? INSendMessageIntent,
           let threadUniqueId = intent.conversationIdentifier {
            selectedThread = databaseStorage.read { TSThread.anyFetch(uniqueId: threadUniqueId, transaction: $0) }
        } else {
            selectedThread = nil
        }

        // If we have a pre-selected thread, we wait to show the approval view
        // until the attachments have been built. Otherwise, we'll present it
        // immediately and tell it what attachments we're sharing once we've
        // finished building them.
        if selectedThread == nil { showPrimaryViewController(conversationPicker) }

        firstly(on: .sharedUserInitiated) { () -> Promise<[NSItemProvider.AttachmentPayload]> in
            // The NSExtensionActivationRule predicate informs iOS that we expect exactly one NSExtensionItem
            if let item = self.extensionContext?.inputItems.first as? NSExtensionItem {
                return self.attachmentPayloads(for: item)
            } else {
                throw OWSAssertionError("no input item")
            }
        }.then(on: .sharedUserInitiated) { (loadedItems: [NSItemProvider.AttachmentPayload]) -> Promise<[SignalAttachment]> in
            let attachmentPromiseTuples = loadedItems.map { $0.loadAsSignalAttachment() }
            let progressReporters = attachmentPromiseTuples.compactMap { $0.1 }
            self.configureProgressPolling(progressReporters)
            return Promise.when(fulfilled: attachmentPromiseTuples.map { $0.0 })

        }.done { [weak self] (attachments: [SignalAttachment]) in
            guard let self = self else { throw PromiseError.cancelled }

            // Make sure the user is not trying to share more than our attachment limit.
            guard attachments.filter({ !$0.isConvertibleToTextMessage }).count <= SignalAttachment.maxAttachmentsAllowed else {
                throw ShareViewControllerError.tooManyAttachments
            }

            self.progressPoller = nil

            Logger.info("Setting picker attachments: \(attachments)")
            self.conversationPicker.attachments = attachments

            if let selectedThread = selectedThread {
                let approvalVC = try self.conversationPicker.buildApprovalViewController(for: selectedThread)
                self.showPrimaryViewController(approvalVC)
            }
        }.catch { [weak self] error in
            guard let self = self else { return }

            let alertTitle: String
            let alertMessage: String?

            if let error = error as? ShareViewControllerError, error == .tooManyAttachments {
                let format = OWSLocalizedString("IMAGE_PICKER_CAN_SELECT_NO_MORE_TOAST_FORMAT",
                                               comment: "Momentarily shown to the user when attempting to select more images than is allowed. Embeds {{max number of items}} that can be shared.")

                alertTitle = String(format: format, OWSFormat.formatInt(SignalAttachment.maxAttachmentsAllowed))
                alertMessage = nil
            } else {
                alertTitle = OWSLocalizedString("SHARE_EXTENSION_UNABLE_TO_BUILD_ATTACHMENT_ALERT_TITLE",
                                               comment: "Shown when trying to share content to a Signal user for the share extension. Followed by failure details.")
                alertMessage = error.userErrorDescription
            }

            OWSActionSheets.showActionSheet(
                title: alertTitle,
                message: alertMessage,
                buttonTitle: CommonStrings.cancelButton
            ) { _ in
                self.shareViewWasCancelled()
            }
            owsFailDebug("building attachment failed with error: \(error)")
        }
    }

    private func presentScreenLock() {
        AssertIsOnMainThread()

        let screenLockUI = SAEScreenLockViewController(shareViewDelegate: self)
        Logger.debug("presentScreenLock: \(screenLockUI)")
        showPrimaryViewController(screenLockUI)
        Logger.info("showing screen lock")
    }

    private func attachmentPayloads(for inputItem: NSExtensionItem) -> Promise<[NSItemProvider.AttachmentPayload]> {
        let availableAttachments = inputItem.attachments ?? []

        // Prefer a URL if available. If there's an image item and a URL item,
        // the URL is generally more useful. e.g. when sharing an app from the
        // App Store the image would be the app icon and the URL is the link
        // to the application.
        if let urlItem = availableAttachments.first(where: { $0.isExclusivelyUrlItem }) {
            return urlItem.attachmentPayload(for: .webUrl).map { [$0] }
        }

        // We only allow sharing 1 item, unless they are visual media items. And if they are
        // visualMediaItems we share *only* the visual media items - a mix of visual and non
        // visual items is not supported.
        let visualAttachments = availableAttachments.filter { $0.isVisualMediaItem }
        let attachmentsToSend = visualAttachments.count > 0 ? visualAttachments : availableAttachments

        if attachmentsToSend.count > 0 {
            return Promise.when(fulfilled: attachmentsToSend.map {
                $0.getPreferredSharingAttachmentPayload()
            })
        } else {
            return Promise(error: OWSAssertionError("No supported attachments"))
        }
    }

    private func configureProgressPolling(_ reporters: [OWSProgressReporting]) {
        guard reporters.count > 0 else { return }

        DispatchQueue.main.async {
            let progressPoller = ProgressPoller(timeInterval: 0.1) {
                let fractionalSum: Float = reporters.reduce(0) { $0 + $1.progress }
                return fractionalSum / Float(reporters.count)
            }

            self.progressPoller = progressPoller
            progressPoller.startPolling()
            self.loadViewController.progress = progressPoller.progress
        }
    }
}

extension NSItemProvider {

    // A single inputItem can have multiple attachments, e.g. sharing from Firefox gives
    // one url attachment and another text attachment, where the url would be https://some-news.com/articles/123-cat-stuck-in-tree
    // and the text attachment would be something like "Breaking news - cat stuck in tree"
    //
    // FIXME: For now, we prefer the URL provider and discard the text provider, since it's more useful to share the URL than the caption
    // but we *should* include both. This will be a bigger change though since our share extension is currently heavily predicated
    // on one itemProvider per share.
    var isExclusivelyUrlItem: Bool {
        if registeredTypeIdentifiers.count == 1 {
            return registeredTypeIdentifiers.first == (kUTTypeURL as String)
        } else {
            return false
        }
    }

    var isVisualMediaItem: Bool {
        let availableTypes = availableItemTypes
        return availableTypes.contains(.movie) || availableTypes.contains(.image)
    }

    func getPreferredSharingAttachmentPayload() -> Promise<NSItemProvider.AttachmentPayload> {
        // The share extension has always had an ordered preference for attachment variants.
        // More correct behavior might involve the extension sharing multiple representations of the same attachment
        // but for now, whatever turns up first in this ordered preference is the payload that gets sent.
        let availableTypes = availableItemTypes
        if availableItemTypes.contains(.movie) {
            return attachmentPayload(for: .movie)
        } else if availableTypes.contains(.image) {
            return attachmentPayload(for: .image)
        } else if availableTypes.contains(.fileUrl) {
            return attachmentPayload(for: .fileUrl)
        } else if availableTypes.contains(.contact) {
            return attachmentPayload(for: .contact)
        } else if availableTypes.contains(.text) {
            return attachmentPayload(for: .text)
        } else if availableTypes.contains(.pdf) {
            return attachmentPayload(for: .pdf)
        } else if availableTypes.contains(.pkPass) {
            return attachmentPayload(for: .pkPass)
        } else if availableTypes.contains(.webUrl) {
            return attachmentPayload(for: .webUrl)
        } else {
            return Promise(error: OWSAssertionError("No matching types"))
        }
    }
}

extension ShareViewController: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        shareViewWasCancelled()
    }
}

// MARK: -

extension ShareViewController: UINavigationControllerDelegate {

    public func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        updateNavigationBarVisibility(for: viewController, in: navigationController, animated: animated)
    }

    public func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        updateNavigationBarVisibility(for: viewController, in: navigationController, animated: animated)
    }

    private func updateNavigationBarVisibility(for viewController: UIViewController,
                                               in navigationController: UINavigationController,
                                               animated: Bool) {
        switch viewController {
        case is AttachmentApprovalViewController:
            navigationController.setNavigationBarHidden(true, animated: animated)
        default:
            navigationController.setNavigationBarHidden(false, animated: animated)
        }
    }
}

// Exposes a Progress object, whose progress is updated by polling the return of a given block
private class ProgressPoller: NSObject {

    let progress: Progress
    private(set) var timer: Timer?

    // Higher number offers higher ganularity
    let progressTotalUnitCount: Int64 = 10000
    private let timeInterval: Double
    private let ratioCompleteBlock: () -> Float

    init(timeInterval: TimeInterval, ratioCompleteBlock: @escaping () -> Float) {
        self.timeInterval = timeInterval
        self.ratioCompleteBlock = ratioCompleteBlock

        self.progress = Progress()

        progress.totalUnitCount = progressTotalUnitCount
        progress.completedUnitCount = Int64(ratioCompleteBlock() * Float(progressTotalUnitCount))
    }

    func startPolling() {
        guard self.timer == nil else {
            owsFailDebug("already started timer")
            return
        }

        self.timer = WeakTimer.scheduledTimer(timeInterval: timeInterval, target: self, userInfo: nil, repeats: true) { [weak self] (timer) in
            guard let strongSelf = self else {
                return
            }

            let completedUnitCount = Int64(strongSelf.ratioCompleteBlock() * Float(strongSelf.progressTotalUnitCount))
            strongSelf.progress.completedUnitCount = completedUnitCount

            if completedUnitCount == strongSelf.progressTotalUnitCount {
                Logger.debug("progress complete")
                timer.invalidate()
            }
        }
    }
}
