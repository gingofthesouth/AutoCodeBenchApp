import Foundation

/// Calls the MultiLanguageSandbox Docker API to evaluate model output. Matches call_sandbox.py behavior.
public struct EvaluationService: Sendable {
    private let baseURL: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(host: String = "localhost", port: Int = 8080) {
        self.baseURL = "http://\(host):\(port)"
    }

    /// Extract code from model output (markdown code block). Mirrors call_sandbox.py _extract_code_blocks.
    public static func extractCode(from output: String, language: String, canonicalSolution: String?) -> String {
        guard !output.isEmpty else { return "" }
        let pattern = #"```(\w+)\n(.*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) else {
            let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 1 {
                return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let codeRange = Range(match.range(at: 2), in: output)!
        return String(output[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Submit one solution + test to the sandbox.
    public func submit(funcCode: String, mainCode: String, lang: String) async throws -> SandboxResponse {
        let url = URL(string: "\(baseURL)/submit")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "src_uid": "autocodebench_\(UUID().uuidString)",
            "func_code": funcCode,
            "main_code": mainCode,
            "lang": lang,
            "show_log": "true",
            "request_extensions": ["timeout": 30, "debug": "false"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EvaluationError.invalidResponse }
        guard http.statusCode == 200 else {
            throw EvaluationError.apiError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        let decoded = try decoder.decode(SandboxResponse.self, from: data)
        return decoded
    }

    /// Evaluate full and demo test for one row; returns (passed, duration in seconds). Passed only if both pass.
    public func evaluateRow(_ row: BenchmarkRow) async throws -> (passed: Bool, duration: TimeInterval) {
        let start = Date()
        let code = Self.extractCode(
            from: row.output ?? "",
            language: row.language,
            canonicalSolution: row.canonicalSolution
        )
        if code.isEmpty { return (false, Date().timeIntervalSince(start)) }
        let fullPassed = try await submit(funcCode: code, mainCode: row.fullTestFunc ?? "", lang: row.language).execOutcome == "PASSED"
        let demoPassed = try await submit(funcCode: code, mainCode: row.demoTestFunc ?? "", lang: row.language).execOutcome == "PASSED"
        let duration = Date().timeIntervalSince(start)
        return (fullPassed && demoPassed, duration)
    }

    /// Run evaluation on all rows and return pass count.
    /// - Parameter progress: (completed, total) after each row.
    public func evaluateAll(rows: [BenchmarkRow], progress: @escaping @Sendable (Int, Int) -> Void) async throws -> (passed: Int, total: Int) {
        try await evaluateAll(rows: rows) { completed, total, passed in
            progress(completed, total)
        }
    }

    /// Run evaluation on all rows; progress reports (completed, total, passed) for live pass rate.
    /// If onRowResult is provided, it is called after each row with (index, passed, durationSeconds, language) for persistence.
    public func evaluateAll(rows: [BenchmarkRow], progress: @escaping @Sendable (Int, Int, Int) -> Void, onRowResult: (@Sendable (Int, Bool, TimeInterval, String) -> Void)? = nil) async throws -> (passed: Int, total: Int) {
        var passed = 0
        for (i, row) in rows.enumerated() {
            let (ok, duration) = (try? await evaluateRow(row)) ?? (false, 0)
            if ok { passed += 1 }
            progress(i + 1, rows.count, passed)
            onRowResult?(i, ok, duration, row.language)
        }
        return (passed, rows.count)
    }

    /// Check if the sandbox is reachable.
    public func healthCheck() async -> Bool {
        guard let url = URL(string: "\(baseURL)/submit") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "src_uid": "health",
            "lang": "python",
            "func_code": "x = 1",
            "main_code": "assert x == 1"
        ])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

public struct SandboxResponse: Decodable {
    public let execOutcome: String?
    enum CodingKeys: String, CodingKey { case execOutcome = "exec_outcome" }
}

public enum EvaluationError: Error, Sendable {
    case invalidResponse
    case apiError(statusCode: Int, body: String?)
}
