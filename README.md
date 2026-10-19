# Manko

A native reader for manga, comics, light novels, and books on iPhone, iPad, and Mac Catalyst.

Supports DRM-free EPUB, PDF, and CBZ/ZIP files, personal library servers, optional extensions, and private iCloud reading-state sync.

## Build

Open `Manko.xcodeproj` in Xcode with a Swift 6.3 or newer toolchain and an iOS Simulator runtime. The minimum deployment target is iOS 18.

Select the **Manko** scheme and a Simulator, then build and run. For device builds, configure your own signing team, bundle identifier, and matching iCloud capabilities and container identifiers.

The app source is in `Manko/`; the six production library modules are in `Packages/MankoKit/Sources/`. Dependencies are pinned in the package manifest and lockfiles. The Xcode project is generated from `project.yml`; use `xcodegen generate --spec project.yml` after changing its configuration.

## Optional tracker sign-in

Set `MANKO_ANILIST_OAUTH_CLIENT_ID` and `MANKO_MYANIMELIST_OAUTH_CLIENT_ID` in Xcode Build Settings or pass them to `xcodebuild`. These are public client identifiers, not client secrets. The registered callback URLs are `manko://oauth/anilist` and `manko://oauth/myanimelist`.

Local Debug and ordinary Release builds work with empty values. Distribution archives require both identifiers; sign-in to those services requires valid provider configuration.

Third-party license notices are included in `Manko/Resources/Licenses/` and available within the app. Bundled artwork retains its own attribution and terms.

## License and contributions

Manko is **source-available, not open source**, under the [Manko Source-Available License](LICENSE).

You may view, study, build, modify, and run the code privately. **Publishing or distributing the app, modified or rebranded versions, or copies of its source outside the stated GitHub/contribution allowances requires prior written permission.** This includes free or paid app-store uploads, TestFlight distribution, and downloadable binaries.

Public GitHub source forks remain permitted as provided by GitHub's terms, and source changes may be proposed through pull requests. Those allowances do not authorize publishing app builds. Contact the project owner, **k800k**, through the official **Manko-iOS/manko** repository to request distribution permission.

Contributions require acceptance of [CLA.md version 2.0](CLA.md). Contributors keep copyright while permitting the project owner to publish their source under these terms, distribute official Manko releases, and grant specific distribution permissions. Acceptance is reviewed manually before merge; the CLA grants no general right to relicense contributions under a different public license.

Third-party dependencies and the bundled onboarding comic retain their own licenses and notices. The project license does not replace or restrict those independent permissions. The comic is *Give My Regards to Black Jack* by **SHUHO SATO**, supplied by [densho810.com](https://densho810.com/free/). Its title and author credit are also shown in the app.
