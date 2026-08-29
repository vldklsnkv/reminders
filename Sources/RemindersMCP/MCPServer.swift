import Foundation

final class MCPServer {
    private let service = RemindersService()
    private let protocolVersion = "2025-06-18"

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            do {
                let data = Data(line.utf8)
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw MCPError.invalidRequest("Expected a JSON object")
                }
                if let response = try handle(request) {
                    write(response)
                }
            } catch {
                write(errorResponse(id: nil, code: -32700, message: error.localizedDescription))
            }
        }
    }

    private func handle(_ request: [String: Any]) throws -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return errorResponse(id: id, code: -32600, message: "Missing method")
        }

        if id == nil {
            return nil
        }

        switch method {
        case "initialize":
            return success(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "apple-reminders", "version": "0.1.0"]
            ])
        case "ping":
            return success(id: id, result: [:])
        case "tools/list":
            return success(id: id, result: ["tools": ToolCatalog.definitions])
        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let payload = try service.call(name: name, arguments: arguments)
                let textData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                let text = String(decoding: textData, as: UTF8.self)
                return success(id: id, result: [
                    "content": [["type": "text", "text": text]],
                    "structuredContent": payload,
                    "isError": false
                ])
            } catch {
                let payload: [String: Any] = [
                    "error": error.localizedDescription,
                    "error_type": String(describing: type(of: error))
                ]
                let textData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                return success(id: id, result: [
                    "content": [["type": "text", "text": String(decoding: textData, as: UTF8.self)]],
                    "structuredContent": payload,
                    "isError": true
                ])
            }
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func success(id: Any?, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

enum MCPError: LocalizedError {
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        }
    }
}
