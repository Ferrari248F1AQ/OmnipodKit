//
//  O5AlgorithmModeView.swift
//  OmnipodKit
//
//  Algorithm mode toggle for Omnipod 5 pods.
//  Allows switching between Loop's native algorithm and Insulet's on-pod AID.
//

import SwiftUI
import LoopKitUI

struct O5AlgorithmModeView: View {

    @Binding var selectedMode: O5AlgorithmMode
    var aidStatus: O5AidStatus?
    var isO5Pod: Bool
    var onModeChange: (O5AlgorithmMode) throws -> Void

    @State private var pickerMode: O5AlgorithmMode = .loopAlgorithm
    @State private var showingConfirmation = false
    @State private var pendingMode: O5AlgorithmMode?
    @State private var switchError: String?
    @State private var showingSwitchError = false

    var body: some View {
        if isO5Pod {
            Section(header: SectionHeader(label: LocalizedString("Dosing Algorithm", comment: "Section header for O5 algorithm mode"))) {

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Algorithm", selection: $pickerMode) {
                        ForEach(O5AlgorithmMode.allCases, id: \.self) { mode in
                            Text(mode.shortName).tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onAppear {
                        pickerMode = selectedMode
                    }
                    .onChange(of: selectedMode) { newValue in
                        pickerMode = newValue
                    }
                    .onChange(of: pickerMode) { newValue in
                        guard newValue != selectedMode else { return }
                        pendingMode = newValue
                        showingConfirmation = true
                    }

                    modeDescription
                }

                if selectedMode == .insuletAID, let status = aidStatus {
                    aidStatusRow(status)
                }
            }
            .alert(isPresented: $showingConfirmation) {
                Alert(
                    title: Text(LocalizedString("Switch Algorithm?", comment: "Alert title for algorithm switch")),
                    message: Text(confirmationMessage),
                    primaryButton: .default(Text(LocalizedString("Switch", comment: "Confirm algorithm switch"))) {
                        if let mode = pendingMode {
                            do {
                                try onModeChange(mode)
                            } catch {
                                pickerMode = selectedMode
                                switchError = error.localizedDescription
                                DispatchQueue.main.async {
                                    showingSwitchError = true
                                }
                            }
                        }
                    },
                    secondaryButton: .cancel {
                        pickerMode = selectedMode
                    }
                )
            }
            .alert(isPresented: $showingSwitchError) {
                Alert(
                    title: Text(LocalizedString("Cannot Switch Algorithm", comment: "Alert title when algorithm switch is blocked")),
                    message: Text(switchError ?? ""),
                    dismissButton: .default(Text(LocalizedString("OK", comment: "OK button")))
                )
            }
        }
    }

    // MARK: - Mode Description

    private var modeDescription: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: selectedMode == .loopAlgorithm ? "arrow.triangle.2.circlepath" : "cpu")
                .foregroundColor(selectedMode == .loopAlgorithm ? .accentColor : .green)
                .font(.system(size: 16))
                .padding(.top, 2)
            Text(descriptionText)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var descriptionText: String {
        switch selectedMode {
        case .loopAlgorithm:
            return LocalizedString("Loop controls temp basals and auto-boluses. The pod acts as a standard delivery device.", comment: "Loop mode description")
        case .insuletAID:
            return LocalizedString("The pod's on-board Kalman filter algorithm manages delivery. Loop monitors but does not enact doses.", comment: "Insulet AID mode description")
        }
    }

    private var confirmationMessage: String {
        switch pendingMode {
        case .insuletAID:
            return LocalizedString("Loop will stop sending automatic doses. The pod's on-board algorithm will take over insulin delivery decisions.", comment: "Switch to Insulet AID confirmation")
        case .loopAlgorithm:
            return LocalizedString("The pod's on-board algorithm will be deactivated. Loop will resume sending automatic temp basals and auto-boluses.", comment: "Switch to Loop confirmation")
        default:
            return ""
        }
    }

    // MARK: - AID Status Display

    private func aidStatusRow(_ status: O5AidStatus) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                statusTile(
                    label: LocalizedString("Pod IOB", comment: "Pod IOB label"),
                    value: status.iobUnits.map { String(format: "%.2f U", $0) } ?? "—"
                )
                statusTile(
                    label: LocalizedString("TDI", comment: "TDI label"),
                    value: status.tdi.map { "\($0) U" } ?? "—"
                )
                statusTile(
                    label: LocalizedString("Status", comment: "Loop status label"),
                    value: status.loopStatus.displayName,
                    valueColor: status.loopStatus.isAutomaticDelivery ? .green : .orange
                )
            }

            if status.isActivityActive {
                HStack(spacing: 4) {
                    Image(systemName: "figure.run")
                        .foregroundColor(.orange)
                        .font(.footnote)
                    Text(LocalizedString("Activity mode active", comment: "Activity mode indicator"))
                        .font(.footnote)
                        .foregroundColor(.orange)
                    if let duration = status.activityDuration {
                        Text("(\(duration) min)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if status.limitedBasalMode {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.footnote)
                    Text(LocalizedString("Automated limited mode — no CGM data", comment: "Limited mode indicator"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func statusTile(label: String, value: String, valueColor: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(valueColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill))
        .cornerRadius(8)
    }
}

// SectionHeader is provided by LoopKitUI
