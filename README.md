# Mango Reader

A native reader for manga, comics, light novels, and books on iPhone, iPad, and Mac Catalyst.

Supports DRM-free EPUB, PDF, and CBZ/ZIP files, personal library servers, optional extensions, and private iCloud reading-state sync.

## Build

Open `MangoReader.xcodeproj` in Xcode with a Swift 6.3 or newer toolchain and an iOS Simulator runtime. The minimum deployment target is iOS 18.

Select the **MangoReader** scheme and a Simulator, then build and run. For device builds, configure your own signing team, bundle identifier, and matching iCloud capabilities and container identifiers.

The app source is in `MangoReader/`; the six production library modules are in `Packages/MangoReaderKit/Sources/`. Dependencies are pinned in the package manifest and lockfiles. The Xcode project is generated from `project.yml`; use `xcodegen generate --spec project.yml` after changing its configuration.

## Optional tracker sign-in

Set `MANGOREADER_ANILIST_OAUTH_CLIENT_ID` and `MANGOREADER_MYANIMELIST_OAUTH_CLIENT_ID` in Xcode Build Settings or pass them to `xcodebuild`. These are public client identifiers, not client secrets. The registered callback URLs are `manko://oauth/anilist` and `manko://oauth/myanimelist`.

Local Debug and ordinary Release builds work with empty values. Distribution archives require both identifiers; sign-in to those services requires valid provider configuration.

Third-party license notices are included in `MangoReader/Resources/Licenses/` and available within the app. Bundled artwork retains its own attribution and terms.

## License and contributions

Mango Reader's original project code is open source under the [GNU General Public License, version 3 only](LICENSE) (`GPL-3.0-only`). Copyright remains with the respective contributors.

You may use, modify, and redistribute the code, including commercially, subject to GPLv3. When distributing covered software, comply with its license and notice requirements and provide the corresponding source as GPLv3 requires. Private modifications do not have to be published merely because you make or run them.

Contributions are welcome through pull requests and require explicit acceptance of [CLA.md version 3.0](CLA.md) before merge. Contributors retain copyright while granting the project owner, **k800k**, broad rights to distribute and sublicense their contributions under GPLv3 or alternative terms, including proprietary and commercial terms. Acceptance is reviewed manually for each contributor and the latest contributed commit; there is no automated CLA check.

These additional rights support alternative licensing of official releases, including App Store and TestFlight distribution. If your intended distribution imposes terms incompatible with GPLv3, obtain a separate licensing exception before distributing. Contact **k800k** through the official **MangoReader-iOS/mango-reader** repository to request one. GPL-compliant distribution does not require additional permission, and a request alone does not grant an exception.

The CLA does not transfer contributors' copyright or grant alternative licensing rights over third-party material that the project owner does not control. Existing contributions accepted under earlier CLA versions require fresh agreement before the broader version 3.0 rights apply. Neither the GPL nor the CLA grants permission to present an unofficial release as an official Mango Reader release or implies a trademark license.

Third-party dependencies and the bundled onboarding comic retain their own licenses and notices. The project license does not replace or restrict those independent permissions. The comic is *Give My Regards to Black Jack* by **SHUHO SATO**, supplied by [densho810.com](https://densho810.com/free/). Its title and author credit are also shown in the app.

## Compatibility

The product and Swift modules are named Mango Reader and `MangoReader…`. Existing bundle and iCloud identifiers, keychain/storage namespaces, backup formats, `manko://` links and OAuth callbacks, and WebAssembly extension entry points retain their established identifiers so the rename does not disconnect existing data or extensions.
