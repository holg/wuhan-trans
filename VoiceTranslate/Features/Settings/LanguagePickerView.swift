import SwiftUI

struct LanguagePickerView: View {
    @Binding var activeLanguages: [SupportedLanguage]

    var body: some View {
        ForEach(0..<3, id: \.self) { slot in
            Picker("Slot \(slot + 1)", selection: slotBinding(slot)) {
                ForEach(availableLanguages(for: slot)) { lang in
                    Text("\(lang.flag) \(lang.displayName)").tag(lang)
                }
            }
        }
    }

    private func slotBinding(_ index: Int) -> Binding<SupportedLanguage> {
        Binding(
            get: { activeLanguages[index] },
            set: { newValue in
                activeLanguages[index] = newValue
            }
        )
    }

    /// All languages, but exclude ones already picked in other slots
    private func availableLanguages(for slot: Int) -> [SupportedLanguage] {
        let otherSlots = activeLanguages.enumerated()
            .filter { $0.offset != slot }
            .map(\.element)
        return SupportedLanguage.allCases
            .filter { !otherSlots.contains($0) }
            .sorted()
    }
}
