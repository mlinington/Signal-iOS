//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import SignalUI

private enum OpenableUrl {
    case phoneNumberLink(URL)
    case usernameLink(Usernames.UsernameLink)
    case stickerPack(StickerPackInfo)
    case groupInvite(URL)
    case signalProxy(URL)
    case completeIDEALDonation(Stripe.IDEALCallbackType)
    case callLink(CallLink)
}

class UrlOpener {
    private let databaseStorage: SDSDatabaseStorage
    private let tsAccountManager: TSAccountManager

    init(
        databaseStorage: SDSDatabaseStorage,
        tsAccountManager: TSAccountManager
    ) {
        self.databaseStorage = databaseStorage
        self.tsAccountManager = tsAccountManager
    }

    // MARK: - Parsing URLs

    struct ParsedUrl {
        fileprivate let openableUrl: OpenableUrl
    }

    static func parseUrl(_ url: URL) -> ParsedUrl? {
        guard let openableUrl = parseOpenableUrl(url) else {
            return nil
        }
        return ParsedUrl(openableUrl: openableUrl)
    }

    private static func parseOpenableUrl(_ url: URL) -> OpenableUrl? {
        if SignalDotMePhoneNumberLink.isPossibleUrl(url) {
            return .phoneNumberLink(url)
        }
        if let usernameLink = Usernames.UsernameLink(usernameLinkUrl: url) {
            return .usernameLink(usernameLink)
        }
        if StickerPackInfo.isStickerPackShare(url), let stickerPackInfo = StickerPackInfo.parseStickerPackShare(url) {
            return .stickerPack(stickerPackInfo)
        }
        if GroupManager.isPossibleGroupInviteLink(url) {
            return .groupInvite(url)
        }
        if SignalProxy.isValidProxyLink(url) {
            return .signalProxy(url)
        }
        if let donationType = Stripe.parseStripeIDEALCallback(url) {
            return .completeIDEALDonation(donationType)
        }
        if let callLink = CallLink(url: url), FeatureFlags.callLinkJoin {
            return .callLink(callLink)
        }
        owsFailDebug("Couldn't parse URL")
        return nil
    }

    // MARK: - Opening URLs

    func openUrl(_ parsedUrl: ParsedUrl, in window: UIWindow) {
        guard tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
            return owsFailDebug("Ignoring URL; not registered.")
        }
        guard let rootViewController = window.rootViewController else {
            return owsFailDebug("Ignoring URL; no root view controller.")
        }
        if shouldDismiss(for: parsedUrl.openableUrl) && rootViewController.presentedViewController != nil {
            rootViewController.dismiss(animated: false, completion: {
                self.openUrlAfterDismissing(parsedUrl.openableUrl, rootViewController: rootViewController)
            })
        } else {
            openUrlAfterDismissing(parsedUrl.openableUrl, rootViewController: rootViewController)
        }
    }

    private func shouldDismiss(for url: OpenableUrl) -> Bool {
        switch url {
        case .completeIDEALDonation: return false
        case .groupInvite, .phoneNumberLink, .signalProxy, .stickerPack, .usernameLink, .callLink: return true
        }
    }

    private func openUrlAfterDismissing(_ openableUrl: OpenableUrl, rootViewController: UIViewController) {
        switch openableUrl {
        case .phoneNumberLink(let url):
            SignalDotMePhoneNumberLink.openChat(url: url, fromViewController: rootViewController)

        case .usernameLink(let link):
            databaseStorage.read { tx in
                UsernameQuerier().queryForUsernameLink(
                    link: link,
                    fromViewController: rootViewController,
                    tx: tx
                ) { _, aci in
                    SignalApp.shared.presentConversationForAddress(
                        SignalServiceAddress(aci),
                        animated: true
                    )
                }
            }

        case .stickerPack(let stickerPackInfo):
            let stickerPackViewController = StickerPackViewController(stickerPackInfo: stickerPackInfo)
            stickerPackViewController.present(from: rootViewController, animated: false)

        case .groupInvite(let url):
            GroupInviteLinksUI.openGroupInviteLink(url, fromViewController: rootViewController)

        case .signalProxy(let url):
            rootViewController.present(ProxyLinkSheetViewController(url: url)!, animated: true)

        case .completeIDEALDonation(let donationType):
            DonationViewsUtil.attemptToContinueActiveIDEALDonation(
                type: donationType,
                databaseStorage: self.databaseStorage
            )
            .then(on: DispatchQueue.main) { [weak self] handled -> Promise<Void> in
                guard let self else { return .value(()) }
                if handled {
                    return Promise.value(())
                }
                return DonationViewsUtil.restartAndCompleteInterruptedIDEALDonation(
                    type: donationType,
                    rootViewController: rootViewController,
                    databaseStorage: self.databaseStorage
                )
            }.done {
                Logger.info("[Donations] Completed iDEAL donation")
            } .catch { error in
                switch error {
                case Signal.DonationJobError.timeout:
                    // This is an expected error case for pending donations
                    break
                default:
                    // Unexpected.  Log an warning
                    OWSLogger.warn("[Donations] Unexpected error encountered with iDEAL donation")
                }
            }

        case .callLink(let callLink):
            // CallLink TODO: Join the call.
            Logger.debug("Trying to open \(callLink)")
        }
    }
}
