import Foundation

struct MankoWasmServiceRequest: Decodable, Sendable {
    let id: String
    let service: String
    let arguments: JSONValue
}
