import SwiftUI

struct ReaderFailureView: View {
    let title: String
    let systemImage: String
    let message: String
    let retry: () -> Void
    var returnToTitle: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)

            if let returnToTitle {
                Button("Return to Title", action: returnToTitle)
                    .buttonStyle(.bordered)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("reader-return-to-title")
            }
        }
    }
}

struct ReaderErrorBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let message: String
    var retry: (() -> Void)? = nil
    let dismiss: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let retry {
                    Button("Retry", action: retry)
                        .buttonStyle(.bordered)
                        .frame(minWidth: 44, minHeight: 44)
                }

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .readerControlHitTarget()
                }
                .accessibilityLabel("Dismiss reader error")
            }
            .frame(
                maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                alignment: .trailing
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
