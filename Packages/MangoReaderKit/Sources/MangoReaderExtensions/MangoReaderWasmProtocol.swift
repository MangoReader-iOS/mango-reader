import Foundation

struct MangoReaderWasmServiceRequest: Decodable, Sendable {
    let id: String
    let service: String
    let arguments: JSONValue
}
