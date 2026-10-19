import Foundation

struct AppAcknowledgement: Decodable, Identifiable {
    let name: String
    let version: String
    let licenseName: String
    let purpose: String
    let licenseFile: String

    var id: String { licenseFile }

    static func load(bundle: Bundle = .main) throws -> [Self] {
        let url = try resourceURL("ThirdPartyLicenses.json", bundle: bundle)
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func licenseText(bundle: Bundle = .main) throws -> String {
        try String(contentsOf: Self.resourceURL(licenseFile, bundle: bundle), encoding: .utf8)
    }

    private static func resourceURL(_ filename: String, bundle: Bundle) throws -> URL {
        let filename = filename as NSString
        guard let url = bundle.url(
            forResource: filename.deletingPathExtension,
            withExtension: filename.pathExtension
        ) ?? bundle.url(
            forResource: filename.deletingPathExtension,
            withExtension: filename.pathExtension,
            subdirectory: "Licenses"
        ) else { throw CocoaError(.fileReadNoSuchFile) }
        return url
    }
}

