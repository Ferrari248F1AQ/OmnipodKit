//
//  O5RegressionReportView.swift
//  OmnipodKit
//
//  Displays the 15-day Smart Regression analysis results.
//  Shows basal, ISF, and ICR suggestions as expandable cards
//  with per-time-block details and "Apply" actions.
//

import SwiftUI

struct O5RegressionReportView: View {

    var report: RegressionReport
    var onApplyBasal: (BasalSuggestion) -> Void
    var onApplyISF: (ISFSuggestion) -> Void
    var onApplyICR: (ICRSuggestion) -> Void
    var onApplyAll: () -> Void

    @State private var expandedSection: ReportSection?

    enum ReportSection: String, CaseIterable {
        case basal, isf, icr
    }

    var body: some View {
        List {
            // Header
            summarySection

            // Basal suggestions
            if !report.basalSuggestions.isEmpty {
                suggestionSection(
                    section: .basal,
                    title: LocalizedString("Basal Rates", comment: "Basal section title"),
                    icon: "waveform.path",
                    color: .orange,
                    count: report.basalSuggestions.count
                ) {
                    ForEach(report.basalSuggestions, id: \.timeBlock) { suggestion in
                        basalRow(suggestion)
                    }
                }
            }

            // ISF suggestions
            if !report.isfSuggestions.isEmpty {
                suggestionSection(
                    section: .isf,
                    title: LocalizedString("Insulin Sensitivity", comment: "ISF section title"),
                    icon: "drop.triangle",
                    color: .purple,
                    count: report.isfSuggestions.count
                ) {
                    ForEach(report.isfSuggestions, id: \.timeBlock) { suggestion in
                        isfRow(suggestion)
                    }
                }
            }

            // ICR suggestions
            if !report.icrSuggestions.isEmpty {
                suggestionSection(
                    section: .icr,
                    title: LocalizedString("Carb Ratios", comment: "ICR section title"),
                    icon: "fork.knife",
                    color: .green,
                    count: report.icrSuggestions.count
                ) {
                    ForEach(report.icrSuggestions, id: \.timeBlock) { suggestion in
                        icrRow(suggestion)
                    }
                }
            }

            // Apply all
            if totalSuggestions > 0 {
                Section {
                    Button(action: onApplyAll) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                            Text(LocalizedString("Apply All Suggestions", comment: "Apply all button"))
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(totalSuggestions)")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(LocalizedString("Therapy Insights", comment: "Regression report navigation title"))
    }

    private var totalSuggestions: Int {
        report.basalSuggestions.count + report.isfSuggestions.count + report.icrSuggestions.count
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(LocalizedString("15-day analysis", comment: "Analysis window label"))
                        .font(.headline)
                    Spacer()
                    qualityBadge(report.dataQuality)
                }

                HStack(spacing: 16) {
                    metricTile(
                        label: LocalizedString("CGM Readings", comment: "CGM count label"),
                        value: "\(report.glucoseSampleCount)"
                    )
                    metricTile(
                        label: LocalizedString("Doses", comment: "Dose count label"),
                        value: "\(report.doseSampleCount)"
                    )
                    metricTile(
                        label: LocalizedString("Meals", comment: "Meal count label"),
                        value: "\(report.carbEntrySampleCount)"
                    )
                    metricTile(
                        label: LocalizedString("Changes", comment: "Total changes label"),
                        value: "\(totalSuggestions)"
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func qualityBadge(_ quality: DataQuality) -> some View {
        Text(quality.displayName)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(qualityColor(quality).opacity(0.15))
            .foregroundColor(qualityColor(quality))
            .cornerRadius(6)
    }

    private func qualityColor(_ quality: DataQuality) -> Color {
        switch quality {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .orange
        case .insufficient: return .red
        }
    }

    private func metricTile(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Suggestion Section

    private func suggestionSection<Content: View>(
        section: ReportSection,
        title: String,
        icon: String,
        color: Color,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section(header:
            Button(action: {
                withAnimation {
                    expandedSection = expandedSection == section ? nil : section
                }
            }) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.footnote)
                    Text(title)
                    Spacer()
                    Text("\(count)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.15))
                        .foregroundColor(color)
                        .cornerRadius(10)
                    Image(systemName: expandedSection == section ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
        ) {
            if expandedSection == section {
                content()
            }
        }
    }

    // MARK: - Basal Row

    private func basalRow(_ suggestion: BasalSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(suggestion.timeBlock.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                changeArrow(
                    from: String(format: "%.2f", suggestion.currentRate),
                    to: String(format: "%.2f", suggestion.suggestedRate),
                    unit: "U/hr",
                    increase: suggestion.suggestedRate > suggestion.currentRate
                )
            }
            HStack(spacing: 4) {
                Text(LocalizedString("BG drift:", comment: "BG drift label"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "%+.1f mg/dL/hr", suggestion.driftRate))
                    .font(.caption)
                    .foregroundColor(suggestion.driftRate > 0 ? .orange : .green)
                Spacer()
                Text(String(format: "%+.0f%%", suggestion.changePercent * 100))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(suggestion.changePercent > 0 ? .orange : .green)
            }

            Button(action: { onApplyBasal(suggestion) }) {
                Text(LocalizedString("Apply", comment: "Apply single suggestion"))
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 4)
    }

    // MARK: - ISF Row

    private func isfRow(_ suggestion: ISFSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(suggestion.timeBlock.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                changeArrow(
                    from: String(format: "%.0f", suggestion.currentISF),
                    to: String(format: "%.0f", suggestion.suggestedISF),
                    unit: "mg/dL/U",
                    increase: suggestion.suggestedISF > suggestion.currentISF
                )
            }
            HStack(spacing: 4) {
                Text(LocalizedString("Observed median:", comment: "Observed ISF label"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "%.0f mg/dL/U", suggestion.observedMedianISF))
                    .font(.caption)
                Spacer()
                Text(String(format: "%+.0f%%", suggestion.changePercent * 100))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.purple)
            }

            Button(action: { onApplyISF(suggestion) }) {
                Text(LocalizedString("Apply", comment: "Apply single suggestion"))
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 4)
    }

    // MARK: - ICR Row

    private func icrRow(_ suggestion: ICRSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(suggestion.timeBlock.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                changeArrow(
                    from: String(format: "%.0f", suggestion.currentICR),
                    to: String(format: "%.0f", suggestion.suggestedICR),
                    unit: "g/U",
                    increase: suggestion.suggestedICR > suggestion.currentICR
                )
            }
            HStack(spacing: 4) {
                Text(LocalizedString("Observed median:", comment: "Observed ICR label"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "%.0f g/U", suggestion.observedMedianICR))
                    .font(.caption)
                Spacer()
                Text(String(format: "%+.0f%%", suggestion.changePercent * 100))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.green)
            }

            Button(action: { onApplyICR(suggestion) }) {
                Text(LocalizedString("Apply", comment: "Apply single suggestion"))
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func changeArrow(from: String, to: String, unit: String, increase: Bool) -> some View {
        HStack(spacing: 4) {
            Text(from)
                .font(.caption)
                .foregroundColor(.secondary)
                .strikethrough()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("\(to) \(unit)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(increase ? .orange : .blue)
        }
    }
}
