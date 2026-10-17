//
//  OmniHUDProvider.swift
//  OmnipodKit
//
//  Based on OmniBLE/PumpManagerUI/OmniBLEHUDProvider.swift
//  Created by Joe Moran 1/7/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import UIKit
import SwiftUI
import LoopKit
import LoopKitUI

enum ReservoirAlertState {
    case ok
    case lowReservoir
    case empty
}

internal class OmniHUDProvider: NSObject, HUDProvider {
    var managerIdentifier: String {
        return pumpManager.pluginIdentifier
    }

    private let pumpManager: OmniPumpManager

    private var reservoirView: OmniReservoirView?
    
    private let bluetoothProvider: BluetoothProvider

    private let colorPalette: LoopUIColorPalette

    private let allowedInsulinTypes: [InsulinType]

    var visible: Bool = false {
        didSet {
            if oldValue != visible && visible {
                hudDidAppear()
            }
        }
    }

    init(pumpManager: OmniPumpManager, bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowedInsulinTypes: [InsulinType]) {
        self.pumpManager = pumpManager
        self.bluetoothProvider = bluetoothProvider
        self.colorPalette = colorPalette
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init()
        self.pumpManager.addPodStateObserver(self, queue: .main)
    }

    func createHUDView() -> BaseHUDView? {
        reservoirView = OmniReservoirView.instantiate()
        updateReservoirView()

        return reservoirView
    }

    func didTapOnHUDView(_ view: BaseHUDView, allowDebugFeatures: Bool) -> HUDTapAction? {
        let vc = pumpManager.settingsViewController(bluetoothProvider: bluetoothProvider, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes)
        return HUDTapAction.presentViewController(vc)
    }

    func hudDidAppear() {
        updateReservoirView()
        refresh()
    }
    
    var hudViewRawState: HUDProvider.HUDViewRawState {
        var rawValue: HUDProvider.HUDViewRawState = [:]

        rawValue["lastStatusDate"] = pumpManager.lastStatusDate

        if let reservoirLevel = pumpManager.reservoirLevel {
            rawValue["reservoirLevel"] = reservoirLevel.rawValue
        }

        if let reservoirLevelHighlightState = pumpManager.reservoirLevelHighlightState {
            rawValue["reservoirLevelHighlightState"] = reservoirLevelHighlightState.rawValue
        }

        rawValue["isO5"] = pumpManager.state.podType.isO5
        rawValue["isInsuletAID"] = pumpManager.isO5AidActive

        return rawValue
    }

    static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? {
        guard let rawReservoirLevel = rawValue["reservoirLevel"] as? ReservoirLevel.RawValue,
              let rawReservoirLevelHighlightState = rawValue["reservoirLevelHighlightState"] as? ReservoirLevelHighlightState.RawValue,
              let reservoirLevelHighlightState = ReservoirLevelHighlightState(rawValue: rawReservoirLevelHighlightState)
        else {
            return nil
        }

        let reservoirView: OmniReservoirView?

        let reservoirLevel = ReservoirLevel(rawValue: rawReservoirLevel)

        if let lastStatusDate = rawValue["lastStatusDate"] as? Date {
            reservoirView = OmniReservoirView.instantiate()
            reservoirView!.update(level: reservoirLevel, at: lastStatusDate, reservoirLevelHighlightState: reservoirLevelHighlightState)
            let isO5 = rawValue["isO5"] as? Bool ?? false
            let isInsuletAID = rawValue["isInsuletAID"] as? Bool ?? false
            reservoirView!.updateAlgorithmMode(isO5: isO5, isInsuletAID: isInsuletAID)
        } else {
            reservoirView = nil
        }

        return reservoirView
    }
    
    private func refresh() {
        pumpManager.getPodStatus() { _ in
            DispatchQueue.main.async {
                self.updateReservoirView()
            }
        }
    }

    private func updateReservoirView() {
        guard let reservoirView = reservoirView,
              let lastStatusDate = pumpManager.lastStatusDate,
            let reservoirLevelHighlightState = pumpManager.reservoirLevelHighlightState else
        {
            return
        }

        reservoirView.update(level: pumpManager.reservoirLevel, at: lastStatusDate, reservoirLevelHighlightState: reservoirLevelHighlightState)
        reservoirView.updateAlgorithmMode(
            isO5: pumpManager.state.podType.isO5,
            isInsuletAID: pumpManager.isO5AidActive
        )
    }
}

extension OmniHUDProvider: PodStateObserver {
    func podConnectionStateDidChange(isConnected: Bool) {
        // ignore for now
    }

    func podStateDidUpdate(_ state: PodState?) {
        updateReservoirView()
    }
}
