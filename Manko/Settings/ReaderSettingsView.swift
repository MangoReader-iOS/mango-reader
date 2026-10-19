import SwiftUI

struct ReaderSettingsView: View {
    var body: some View {
        Form {
            ReaderCommonSettingsSections()
            ImageReaderSettingsSections()
            EPUBTypographySettingsSections()
            PDFReaderSettingsSections()
        }
        .navigationTitle("Reader Controls")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
    }
}
