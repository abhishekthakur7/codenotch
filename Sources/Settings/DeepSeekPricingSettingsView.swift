import SwiftUI

/// Settings for the locally maintained DeepSeek billing schedule.
///
/// DeepSeek publishes the rule in UTC, so the editor intentionally says UTC
/// rather than silently converting the stored values to the Mac's timezone.
struct DeepSeekPricingSettingsView: View {
    @ObservedObject var preferences: Preferences

    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    private var schedule: DeepSeekPricing.Schedule {
        preferences.deepSeekPricingSchedule.normalized
    }

    var body: some View {
        Form {
            Section(L10n.t("Peak/off-peak pricing")) {
                Toggle(L10n.t("Show DeepSeek pricing"),
                       isOn: $preferences.deepSeekPricingEnabled)

                Text(L10n.t("Shows the current billing phase and the next peak/off-peak change on the DeepSeek usage card."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t("Peak rule")) {
                Text(L10n.t("The schedule is maintained locally because it cannot be read reliably from an official API. Times below are UTC; the card converts the next change to your local time."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("Peak days"))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                              alignment: .leading, spacing: 6) {
                        ForEach(Self.weekdayOrder, id: \.self) { weekday in
                            Toggle(weekdayTitle(weekday), isOn: weekdayBinding(weekday))
                                .toggleStyle(.checkbox)
                        }
                    }
                }

                PeakWindowRow(title: L10n.t("Window 1"),
                              start: timeBinding(window: 0, start: true),
                              end: timeBinding(window: 0, start: false))
                PeakWindowRow(title: L10n.t("Window 2"),
                              start: timeBinding(window: 1, start: true),
                              end: timeBinding(window: 1, start: false))
            }
            .disabled(!preferences.deepSeekPricingEnabled)

            Section {
                Button(L10n.t("Restore current default rule")) {
                    preferences.resetDeepSeekPricingSchedule()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func weekdayTitle(_ weekday: Int) -> String {
        switch weekday {
        case 1: return L10n.t("Sun")
        case 2: return L10n.t("Mon")
        case 3: return L10n.t("Tue")
        case 4: return L10n.t("Wed")
        case 5: return L10n.t("Thu")
        case 6: return L10n.t("Fri")
        default: return L10n.t("Sat")
        }
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { schedule.peakWeekdays.contains(weekday) },
            set: { enabled in
                var next = schedule
                if enabled {
                    next.peakWeekdays.insert(weekday)
                } else {
                    next.peakWeekdays.remove(weekday)
                }
                preferences.deepSeekPricingSchedule = next
            }
        )
    }

    private func timeBinding(window index: Int, start: Bool) -> Binding<Int> {
        Binding(
            get: {
                let window = schedule.windows.indices.contains(index)
                    ? schedule.windows[index]
                    : DeepSeekPricing.Schedule.current.windows[index]
                return start ? window.startMinute : window.endMinute
            },
            set: { value in
                var next = schedule
                guard next.windows.indices.contains(index) else { return }
                var window = next.windows[index]
                if start {
                    window.startMinute = min(value, max(0, window.endMinute - 30))
                } else {
                    window.endMinute = max(value, min(1_440, window.startMinute + 30))
                }
                next.windows[index] = window
                preferences.deepSeekPricingSchedule = next
            }
        )
    }
}

private struct PeakWindowRow: View {
    let title: String
    @Binding var start: Int
    @Binding var end: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker(L10n.t("Start"), selection: $start) {
                ForEach(Array(stride(from: 0, through: 1_440, by: 30)), id: \.self) { minute in
                    Text(timeText(minute)).tag(minute)
                }
            }
            .labelsHidden()
            Text(L10n.t("to"))
                .foregroundStyle(.secondary)
            Picker(L10n.t("End"), selection: $end) {
                ForEach(Array(stride(from: 0, through: 1_440, by: 30)), id: \.self) { minute in
                    Text(timeText(minute)).tag(minute)
                }
            }
            .labelsHidden()
        }
    }

    private func timeText(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
