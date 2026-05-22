import Foundation
import Testing
@testable import Alas

@Suite("LSPMessages")
struct LSPMessagesTests {
    @Test("encodes a request envelope with id, method, params")
    func encodeRequest() throws {
        let req = LSPRequest(
            id: .int(1),
            method: "initialize",
            params: AnyEncodable(["processId": 42 as Int])
        )
        let data = try JSONEncoder().encode(req)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"jsonrpc\":\"2.0\""))
        #expect(json.contains("\"id\":1"))
        #expect(json.contains("\"method\":\"initialize\""))
    }

    @Test("decodes a response with a result and the result Data round-trips into a structured type")
    func decodeResponseResult() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"hoverProvider":true}}}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(LSPResponse.self, from: json)
        #expect(resp.id == .int(1))
        #expect(resp.error == nil)
        let result = try #require(resp.result)
        struct InitResult: Decodable { struct Caps: Decodable { let hoverProvider: Bool? }
        let capabilities: Caps }
        let decoded = try JSONDecoder().decode(InitResult.self, from: result)
        #expect(decoded.capabilities.hoverProvider == true)
    }

    @Test("decodes a response with an error")
    func decodeResponseError() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#.data(using: .utf8)!
        let resp = try JSONDecoder().decode(LSPResponse.self, from: json)
        #expect(resp.error?.code == -32601)
        #expect(resp.error?.message == "Method not found")
    }

    @Test("Position translates to/from line/column")
    func position() throws {
        let p = LSPPosition(line: 3, character: 7)
        let data = try JSONEncoder().encode(p)
        let p2 = try JSONDecoder().decode(LSPPosition.self, from: data)
        #expect(p == p2)
    }

    @Test("decodes completion result from an item array")
    func decodeCompletionItemArray() throws {
        let data = """
        [
          {
            "label": "openEditor",
            "kind": 2,
            "detail": "(relativePath: String)",
            "documentation": {"kind": "markdown", "value": "Opens a file."},
            "sortText": "001",
            "filterText": "openEditor",
            "insertText": "openEditor(relativePath:)",
            "insertTextFormat": 1,
            "textEdit": {
              "range": {
                "start": {"line": 3, "character": 8},
                "end": {"line": 3, "character": 10}
              },
              "newText": "openEditor"
            },
            "additionalTextEdits": [
              {
                "range": {
                  "start": {"line": 0, "character": 0},
                  "end": {"line": 0, "character": 0}
                },
                "newText": "import Foundation\\n"
              }
            ]
          }
        ]
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(LSPCompletionResult.self, from: data)

        #expect(result.isIncomplete == false)
        #expect(result.items.count == 1)
        let item = try #require(result.items.first)
        #expect(item.label == "openEditor")
        #expect(item.kind == 2)
        #expect(item.detail == "(relativePath: String)")
        #expect(item.sortText == "001")
        #expect(item.filterText == "openEditor")
        #expect(item.insertText == "openEditor(relativePath:)")
        #expect(item.insertTextFormat == .plainText)
        #expect(item.textEdit?.newText == "openEditor")
        #expect(item.textEdit?.range.start == LSPPosition(line: 3, character: 8))
        #expect(item.additionalTextEdits?.first?.newText == "import Foundation\n")
        if case .markupContent(let kind, let value) = item.documentation {
            #expect(kind == "markdown")
            #expect(value == "Opens a file.")
        } else {
            Issue.record("expected markdown documentation")
        }
    }

    @Test("decodes completion insert replace text edit")
    func decodeCompletionInsertReplaceTextEdit() throws {
        let data = """
        [
          {
            "label": "append",
            "textEdit": {
              "newText": "append",
              "insert": {
                "start": {"line": 1, "character": 4},
                "end": {"line": 1, "character": 7}
              },
              "replace": {
                "start": {"line": 1, "character": 4},
                "end": {"line": 1, "character": 10}
              }
            }
          }
        ]
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(LSPCompletionResult.self, from: data)

        let edit = try #require(result.items.first?.textEdit)
        #expect(edit.newText == "append")
        #expect(edit.range == LSPRange(
            start: LSPPosition(line: 1, character: 4),
            end: LSPPosition(line: 1, character: 10)
        ))
    }

    @Test("decodes completion result from CompletionList")
    func decodeCompletionList() throws {
        let data = """
        {
          "isIncomplete": true,
          "items": [
            {"label": "openExternalEditor", "kind": 2, "detail": "(absoluteURL: URL)"}
          ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(LSPCompletionResult.self, from: data)

        #expect(result.isIncomplete == true)
        #expect(result.items.map(\.label) == ["openExternalEditor"])
        #expect(result.items.first?.detail == "(absoluteURL: URL)")
    }
}
