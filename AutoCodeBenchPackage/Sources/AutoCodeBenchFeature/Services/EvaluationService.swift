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
        var text = output
        if let range = text.range(of: "</think>") {
            text = String(text[range.upperBound...])
        }
        let pattern = #"```\S*\s*(.*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
            return fallbackExtract(from: text)
        }
        let range = NSRange(text.startIndex..., in: text)
        var extracted: String?
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            guard let match, match.numberOfRanges > 1 else { return }
            let groupRange = match.range(at: 1)
            guard groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: text) else { return }
            let code = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                extracted = code
                stop.pointee = true
            }
        }
        guard var extracted = extracted else {
            return fallbackExtract(from: text)
        }
        if language.lowercased() == "elixir", let solution = canonicalSolution?.trimmingCharacters(in: .whitespacesAndNewlines), !solution.isEmpty {
            let codeLines = extracted.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let solutionLines = solution.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard solutionLines.first?.hasPrefix("defmodule") == true,
                  solutionLines.last?.hasPrefix("end") == true else {
                return extracted
            }
            let firstCanon = solutionLines[0]
            let lastCanon = solutionLines[solutionLines.count - 1]
            if codeLines.first?.hasPrefix("defmodule") == true, codeLines.last?.hasPrefix("end") == true {
                extracted = ([firstCanon] + codeLines.dropFirst().dropLast() + [lastCanon]).joined(separator: "\n")
            } else {
                extracted = ([firstCanon] + codeLines.map { "  " + $0 } + [lastCanon]).joined(separator: "\n")
            }
        }
        return extracted
    }

    /// Fallback when no non-empty fenced code block found: strip backticks, optionally drop first line.
    private static func fallbackExtract(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        let lines = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1 {
            return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Evaluate demo then full test for one row; returns (passed, duration in seconds). Passed only if both pass.
    /// Runs demo first and skips the full test when demo fails to avoid an extra sandbox call.
    public func evaluateRow(_ row: BenchmarkRow) async throws -> (passed: Bool, duration: TimeInterval) {
        let start = Date()
        let code = Self.extractCode(
            from: row.output ?? "",
            language: row.language,
            canonicalSolution: row.canonicalSolution
        )
        if code.isEmpty { return (false, Date().timeIntervalSince(start)) }
        let demoPassed = try await submit(funcCode: code, mainCode: row.demoTestFunc ?? "", lang: row.language).execOutcome == "PASSED"
        if !demoPassed {
            return (false, Date().timeIntervalSince(start))
        }
        let fullPassed = try await submit(funcCode: code, mainCode: row.fullTestFunc ?? "", lang: row.language).execOutcome == "PASSED"
        let duration = Date().timeIntervalSince(start)
        return (fullPassed, duration)
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
