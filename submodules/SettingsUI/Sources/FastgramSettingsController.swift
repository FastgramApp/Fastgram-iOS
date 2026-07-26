import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import AccountContext

private final class FastgramSettingsControllerArguments {
    let updateRoundVideoMode: (Int32) -> Void
    
    init(updateRoundVideoMode: @escaping (Int32) -> Void) {
        self.updateRoundVideoMode = updateRoundVideoMode
    }
}

private enum FastgramSettingsSection: Int32 {
    case videoMessages
}

private enum FastgramSettingsEntry: ItemListNodeEntry {
    case videoMessagesHeader(PresentationTheme, String)
    case optimized(PresentationTheme, String, Bool)
    case original(PresentationTheme, String, Bool)
    case videoMessagesInfo(PresentationTheme, String)
    
    var section: ItemListSectionId {
        return FastgramSettingsSection.videoMessages.rawValue
    }
    
    var stableId: Int32 {
        switch self {
        case .videoMessagesHeader:
            return 0
        case .optimized:
            return 1
        case .original:
            return 2
        case .videoMessagesInfo:
            return 3
        }
    }
    
    static func ==(lhs: FastgramSettingsEntry, rhs: FastgramSettingsEntry) -> Bool {
        switch lhs {
        case let .videoMessagesHeader(lhsTheme, lhsText):
            if case let .videoMessagesHeader(rhsTheme, rhsText) = rhs {
                return lhsTheme === rhsTheme && lhsText == rhsText
            }
        case let .optimized(lhsTheme, lhsText, lhsValue):
            if case let .optimized(rhsTheme, rhsText, rhsValue) = rhs {
                return lhsTheme === rhsTheme && lhsText == rhsText && lhsValue == rhsValue
            }
        case let .original(lhsTheme, lhsText, lhsValue):
            if case let .original(rhsTheme, rhsText, rhsValue) = rhs {
                return lhsTheme === rhsTheme && lhsText == rhsText && lhsValue == rhsValue
            }
        case let .videoMessagesInfo(lhsTheme, lhsText):
            if case let .videoMessagesInfo(rhsTheme, rhsText) = rhs {
                return lhsTheme === rhsTheme && lhsText == rhsText
            }
        }
        return false
    }
    
    static func <(lhs: FastgramSettingsEntry, rhs: FastgramSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
    
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! FastgramSettingsControllerArguments
        switch self {
        case let .videoMessagesHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .optimized(_, text, isSelected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: text, style: .right, checked: isSelected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.updateRoundVideoMode(1)
            })
        case let .original(_, text, isSelected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: text, style: .right, checked: isSelected, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.updateRoundVideoMode(0)
            })
        case let .videoMessagesInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func fastgramSettingsEntries(presentationData: PresentationData, roundVideoMode: Int32) -> [FastgramSettingsEntry] {
    return [
        .videoMessagesHeader(presentationData.theme, presentationData.strings.FastgramSettings_VideoMessagesHeader),
        .optimized(presentationData.theme, presentationData.strings.FastgramSettings_VideoMessagesOptimized, roundVideoMode != 0),
        .original(presentationData.theme, presentationData.strings.FastgramSettings_VideoMessagesOriginal, roundVideoMode == 0),
        .videoMessagesInfo(presentationData.theme, presentationData.strings.FastgramSettings_VideoMessagesInfo)
    ]
}

public func fastgramSettingsController(context: AccountContext) -> ViewController {
    let arguments = FastgramSettingsControllerArguments(updateRoundVideoMode: { value in
        let _ = context.sharedContext.accountManager.transaction { transaction in
            transaction.updateSharedData(ApplicationSpecificSharedDataKeys.experimentalUISettings, { entry in
                var settings = entry?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
                settings.roundVideoBenchmarkMode = value
                return EnginePreferencesEntry(settings)
            })
        }.start()
    })
    
    let signal = combineLatest(
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: Set([
            ApplicationSpecificSharedDataKeys.experimentalUISettings
        ]))
    )
    |> deliverOnMainQueue
    |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
        
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text(presentationData.strings.FastgramSettings_Title),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: fastgramSettingsEntries(presentationData: presentationData, roundVideoMode: settings.roundVideoBenchmarkMode),
            style: .blocks,
            animateChanges: false
        )
        return (controllerState, (listState, arguments))
    }
    
    return ItemListController(context: context, state: signal)
}
