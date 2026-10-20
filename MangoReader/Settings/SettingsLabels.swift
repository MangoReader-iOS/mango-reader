import SwiftUI

struct SettingsEmptyCardContent<Description: View, Action: View>: View {
    @ViewBuilder let description: Description
    @ViewBuilder let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            description
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            action
                .buttonStyle(.borderless)
                .tint(AppColors.action)
                .foregroundStyle(AppColors.action)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsNavigationLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsSemanticLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var usesSecondaryText = false
    var font: Font? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            styledText
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
    }

    @ViewBuilder
    private var styledText: some View {
        if usesSecondaryText {
            Text(title).foregroundStyle(.secondary)
        } else {
            Text(title).foregroundStyle(.primary)
        }
    }
}
