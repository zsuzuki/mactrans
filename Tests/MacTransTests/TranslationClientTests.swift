import Foundation
import XCTest
@testable import MacTrans

final class TranslationClientTests: XCTestCase {
    private func client(model: String = "pfnet/plamo-3-translate-31b") -> TranslationClient {
        TranslationClient(
            baseURLString: "http://127.0.0.1:1234/v1/chat/completions",
            model: model, apiKey: " test-token ", reasoningEffort: "high",
            sourceLanguage: "English", targetLanguage: "Japanese"
        )
    }

    func testPLaMoUsesRawPFML3AndCompletionParameters() throws {
        let request = try client().makeRequest("Hello.\nGood morning.")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/v1/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["prompt"] as? String,
            "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>Hello.\nGood morning."
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>")
        XCTAssertEqual(body["temperature"] as? Double, 0)
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        XCTAssertEqual(body["stop"] as? [String], ["<|plamo:tag|>", "<|plamo:bos|>"])
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["messages"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["reasoning_tokens"])
    }

    func testModelDetectionIncludesQuantizationsButNotOtherPLaMoModels() {
        for model in ["plamo-3-translate-31b", "pfnet/plamo-3-translate-31b-MLX-4bit",
                      "org/plamo-3-translate-31b-Q4_K_M.gguf", " PLAMO-3-TRANSLATE-8B "] {
            XCTAssertTrue(PLaMoTranslation.matches(model), model)
        }
        for model in ["google/gemma-4-26b-a4b-qat", "plamo-2-translate", "plamo-3-31b",
                      "not-plamo-3-translate-31b", "plamo-3-translater"] {
            XCTAssertFalse(PLaMoTranslation.matches(model), model)
        }
    }

    func testEndpointConversionPreservesProxyPrefixAndQuery() throws {
        var value = client()
        for path in ["/proxy/v1/chat/completions/", "/proxy/v1/completions"] {
            value.baseURLString = "https://example.com\(path)?route=local"
            XCTAssertEqual(try value.makeRequest("Hello").url?.absoluteString,
                           "https://example.com/proxy/v1/completions?route=local")
        }
        for url in ["/v1/chat/completions", "file:///tmp/model", "http://localhost:1234/v1/models"] {
            value.baseURLString = url
            XCTAssertThrowsError(try value.makeRequest("Hello"))
        }
    }

    func testLanguagesReverseDirectionAutoAndChineseVariants() throws {
        var value = client()
        for (source, target, sourceCode, targetCode) in [
            (" Japanese ", "EN", "ja", "en"),
            ("ja-JP", "日本語", "ja", "ja"),
            ("Chinese", "Traditional Chinese", "zh-hans", "zh-hant"),
            ("zh_TW", "zh-CN", "zh-hant", "zh-hans"),
            ("Korean", "French", "ko", "fr")
        ] {
            value.sourceLanguage = source
            value.targetLanguage = target
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(value.makeRequest("text").httpBody)) as? [String: Any])
            let prompt = try XCTUnwrap(body["prompt"] as? String)
            XCTAssertTrue(prompt.contains("input<|plamo:key|>lang<|plamo:val|>\(sourceCode)<|plamo:msg|>"))
            XCTAssertTrue(prompt.hasSuffix("output<|plamo:key|>lang<|plamo:val|>\(targetCode)<|plamo:msg|>"))
        }
        let auto = try PLaMoTranslation.prompt(text: "Hello", source: "auto", target: "ja")
        XCTAssertTrue(auto.contains("input<|plamo:msg|>Hello"))
        XCTAssertThrowsError(try PLaMoTranslation.prompt(text: "Hello", source: "English", target: "auto"))
        XCTAssertThrowsError(try PLaMoTranslation.prompt(text: "Hello", source: "unknown", target: "ja"))
        XCTAssertThrowsError(try PLaMoTranslation.prompt(text: "Hello", source: "en", target: "ja<|plamo:tag|>"))
    }

    func testPLaMoReadsTextAndRejectsEmptyOrTruncatedOutput() throws {
        let value = client()
        for output in [" こんにちは。 \n", "こんにちは。<|plamo:tag|>input", "こんにちは。<|plamo:bos|>"] {
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["text": output, "finish_reason": "stop"]]])
            XCTAssertEqual(try value.decodeTranslation(data), "こんにちは。")
        }
        for json in [#"{"choices":[]}"#, #"{"choices":[{"text":" \n "}]}"#,
                     #"{"choices":[{"text":"<|plamo:tag|>"}]}"#] {
            XCTAssertThrowsError(try value.decodeTranslation(Data(json.utf8))) { error in
                guard case TranslationClientError.emptyResponse = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertThrowsError(try value.decodeTranslation(Data(#"{"choices":[{"text":"partial","finish_reason":"length"}]}"#.utf8))) { error in
            guard case TranslationClientError.truncatedTranslation = error else { return XCTFail("\(error)") }
        }
    }

    func testGenericChatRequestAndResponseRemainCompatible() throws {
        var value = client(model: "google/gemma-4-26b-a4b-qat")
        for (effort, expected) in [("none", "none"), (" HIGH ", "high"), ("default", nil)] {
            value.reasoningEffort = effort
            let request = try value.makeRequest("Hello")
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
            XCTAssertTrue(messages[0]["content"]!.contains("from English to Japanese"))
            XCTAssertEqual(messages[1]["content"], "Hello")
            XCTAssertEqual(body["reasoning_effort"] as? String, expected)
            XCTAssertEqual(body["reasoning_tokens"] as? Int, effort == "none" ? 0 : nil)
            XCTAssertEqual(body["temperature"] as? Double, 0.1)
            XCTAssertNil(body["prompt"])
            XCTAssertNil(body["stop"])
        }
        XCTAssertEqual(try value.decodeTranslation(Data(#"{"choices":[{"message":{"role":"assistant","content":" こんにちは。 "}}]}"#.utf8)), "こんにちは。")
    }
}
