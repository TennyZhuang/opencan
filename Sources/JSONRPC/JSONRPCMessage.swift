import Foundation

/// A JSON-RPC 2.0 message — request, notification, or response.
enum JSONRPCMessage: Codable, Sendable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONRPCID, result: JSONValue)
    case error(id: JSONRPCID?, code: Int, message: String, data: JSONValue?)

    // MARK: - ID type

    enum JSONRPCID: Codable, Hashable, Sendable {
        case int(Int)
        case string(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i) }
            else { self = .string(try c.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .int(let i): try c.encode(i)
            case .string(let s): try c.encode(s)
            }
        }
    }

    // MARK: - Wire format

    private struct Wire: Codable {
        let jsonrpc: String
        var id: JSONRPCID?
        var method: String?
        var params: JSONValue?
        var result: JSONValue?
        var error: ErrorObject?

        enum CodingKeys: String, CodingKey {
            case jsonrpc, id, method, params, result, error
        }

        struct ErrorObject: Codable {
            let code: Int
            let message: String
            var data: JSONValue?
        }

        init(
            jsonrpc: String = "2.0",
            id: JSONRPCID? = nil,
            method: String? = nil,
            params: JSONValue? = nil,
            result: JSONValue? = nil,
            error: ErrorObject? = nil
        ) {
            self.jsonrpc = jsonrpc
            self.id = id
            self.method = method
            self.params = params
            self.result = result
            self.error = error
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
            id = try c.decodeIfPresent(JSONRPCID.self, forKey: .id)
            method = try c.decodeIfPresent(String.self, forKey: .method)
            params = try c.decodeIfPresent(JSONValue.self, forKey: .params)
            error = try c.decodeIfPresent(ErrorObject.self, forKey: .error)
            // Preserve explicit `result: null` as `.null` instead of dropping it.
            if c.contains(.result) {
                result = try c.decode(JSONValue.self, forKey: .result)
            } else {
                result = nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let w = try Wire(from: decoder)
        if let err = w.error {
            self = .error(id: w.id, code: err.code, message: err.message, data: err.data)
        } else if let id = w.id, let result = w.result {
            self = .response(id: id, result: result)
        } else if let id = w.id, let method = w.method {
            self = .request(id: id, method: method, params: w.params)
        } else if let method = w.method {
            self = .notification(method: method, params: w.params)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JSON-RPC message"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var w = Wire(jsonrpc: "2.0")
        switch self {
        case .request(let id, let method, let params):
            w.id = id; w.method = method; w.params = params
        case .notification(let method, let params):
            w.method = method; w.params = params
        case .response(let id, let result):
            w.id = id; w.result = result
        case .error(let id, let code, let message, let data):
            w.id = id; w.error = .init(code: code, message: message, data: data)
        }
        try w.encode(to: encoder)
    }

    // MARK: - Serialization helpers

    func serialized() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func deserialize(from data: Data) throws -> JSONRPCMessage {
        try JSONDecoder().decode(JSONRPCMessage.self, from: data)
    }
}
