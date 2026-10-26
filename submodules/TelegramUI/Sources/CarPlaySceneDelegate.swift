import AccountContext
import CarPlay
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// The car owns templates only; it never attaches to or drives the phone's window.
@objc(CarPlaySceneDelegate) final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var chatListTemplate: CPListTemplate?
    private let contextDisposable = MetaDisposable()
    private let chatListDisposable = MetaDisposable()
    private let accountInUse = MetaDisposable()
    private var isInForeground = false

    private var appDelegate: AppDelegate? {
        return UIApplication.shared.delegate as? AppDelegate
    }

    deinit {
        self.contextDisposable.dispose()
        self.chatListDisposable.dispose()
        self.accountInUse.dispose()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let template = CPListTemplate(title: "Fastgram", sections: [])
        template.emptyViewTitleVariants = ["Loading chats…"]
        self.chatListTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
        self.setInForeground(true)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.setInForeground(false)
        self.chatListTemplate = nil
        self.interfaceController = nil
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        self.setInForeground(true)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        self.setInForeground(false)
    }

    private func setInForeground(_ value: Bool) {
        guard self.isInForeground != value, self.interfaceController != nil else {
            return
        }
        self.isInForeground = value
        self.appDelegate?.setCarPlayInForeground(value)
        self.contextDisposable.set(nil)
        self.chatListDisposable.set(nil)
        self.accountInUse.set(nil)

        guard value, let appDelegate = self.appDelegate else {
            // Do not leave names visible in the car's background snapshot.
            self.showStatus("Fastgram")
            return
        }

        self.contextDisposable.set((appDelegate.carPlaySharedContext
        |> mapToSignal { sharedContext in
            return combineLatest(sharedContext.activeAccountContexts, sharedContext.appLockContext.isPasscodeLocked, sharedContext.presentationData)
            |> map { accounts, isLocked, presentationData in
                return (sharedContext, accounts.primary, isLocked, presentationData)
            }
        }
        |> deliverOnMainQueue).start(next: { [weak self] sharedContext, accountContext, isLocked, presentationData in
            guard let self else {
                return
            }
            self.chatListDisposable.set(nil)
            self.accountInUse.set(nil)

            guard !isLocked else {
                self.showStatus(presentationData.strings.Intents_ErrorLockedTitle)
                return
            }
            guard let accountContext else {
                self.showStatus("Sign in to Fastgram when parked")
                return
            }

            self.accountInUse.set(sharedContext.setAccountUserInterfaceInUse(accountContext.account.id))
            self.showStatus("Loading chats…")
            // This is the same hole-filling source used by the phone chat list, so a
            // cold CarPlay launch can fetch chats rather than showing an empty cache.
            self.chatListDisposable.set((sharedContext.subscribeChatListData(context: accountContext, location: .chatList(groupId: .root))
            |> deliverOnMainQueue).start(next: { [weak self] list in
                self?.updateChats(list, accountContext: accountContext, presentationData: presentationData)
            }))
        }))
    }

    private func showStatus(_ title: String) {
        self.chatListTemplate?.emptyViewTitleVariants = [title]
        self.chatListTemplate?.emptyViewSubtitleVariants = []
        self.chatListTemplate?.updateSections([])
    }

    private func updateChats(_ list: EngineChatList, accountContext: AccountContext, presentationData: PresentationData) {
        guard let template = self.chatListTemplate else {
            return
        }
        var items: [CPListTemplateItem] = []
        for chat in list.items.sorted(by: { $0.index > $1.index }) {
            guard let peer = chat.renderedPeer.peer else {
                continue
            }
            // Secret-chat contents and identities stay off the extension-backed surface.
            if case .secretChat = peer {
                continue
            }
            let title = peer.id == accountContext.account.peerId
                ? presentationData.strings.DialogList_SavedMessages
                : peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
            let leading = CPMessageListItemLeadingConfiguration(leadingItem: .none, leadingImage: nil, unread: chat.readCounters?.isUnread ?? false)
            let trailing = CPMessageListItemTrailingConfiguration(trailingItem: chat.isMuted ? .mute : .none, trailingImage: nil)
            let item = CPMessageListItem(
                conversationIdentifier: String(peer.id.toInt64()),
                text: title,
                leadingConfiguration: leading,
                trailingConfiguration: trailing,
                detailText: nil,
                trailingText: chat.readCounters.flatMap { $0.count > 0 ? String($0.count) : nil }
            )
            items.append(item)
            if items.count >= CPListTemplate.maximumItemCount {
                break
            }
        }
        template.emptyViewTitleVariants = [list.isLoading ? "Loading chats…" : "No chats yet"]
        template.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }
}
