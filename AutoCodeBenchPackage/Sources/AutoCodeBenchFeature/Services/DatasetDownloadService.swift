import Foundation

/// Downloads and parses the AutoCodeBench JSONL dataset.
public struct DatasetDownloadService: Sendable {

    public static let systemPrompt = "You are an expert programmer. Your task is to provide a code solution within a single Markdown code block for the given programming problem. Do not include any direct execution commands, test cases, or usage examples within the code block."

    private let decoder = JSONDecoder()

    public init() {}

    /// Application Support directory for the app (dataset cache, runs, DB).
    public var appSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AutoCodeBench", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Path to the cached JSONL file.
    public var cachedDatasetPath: URL {
        appSupportDirectory.appending(path: "autocodebench.jsonl")
    }

    private static let datasetURL = URL(string: "https://huggingface.co/datasets/tencent/AutoCodeBenchmark/resolve/main/autocodebench.jsonl")!

    /// Download the dataset via HTTP (no Python required).
    public func downloadDataset() async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: Self.datasetURL)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.downloadFailed(exitCode: -1) }
        guard http.statusCode == 200 else { throw DownloadError.httpError(statusCode: http.statusCode) }
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try data.write(to: cachedDatasetPath)
        return cachedDatasetPath
    }

    /// Parse the JSONL file and return all problems, optionally filtered by language.
    public func loadProblems(from path: URL, languages: [String]? = nil) throws -> [BenchmarkProblem] {
        let content = try Data(contentsOf: path)
        let lines = content.split(separator: UInt8(ascii: "\n"))
        var problems: [BenchmarkProblem] = []
        for line in lines {
            guard let problem = try? decoder.decode(BenchmarkProblem.self, from: Data(line)) else { continue }
            if let langs = languages, !langs.isEmpty, !langs.contains(problem.language.lowercased()) { continue }
            problems.append(problem)
        }
        return problems
    }

    /// Discover unique languages in the dataset (from cached file or first N lines).
    public func availableLanguages(at path: URL) throws -> [String] {
        let content = try Data(contentsOf: path)
        let lines = content.split(separator: UInt8(ascii: "\n"))
        var seen = Set<String>()
        for line in lines.prefix(5000) {
            guard let problem = try? decoder.decode(BenchmarkProblem.self, from: Data(line)) else { continue }
            seen.insert(problem.language.lowercased())
        }
        return seen.sorted()
    }
}

public enum DownloadError: Error, Sendable {
    case scriptNotFound
    case downloadFailed(exitCode: Int)
    case httpError(statusCode: Int)
}

extension DownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .scriptNotFound: return "Dataset download script not found."
        case .downloadFailed(let code): return "Download failed (exit code \(code))."
        case .httpError(let code): return "Download failed (HTTP \(code))."
        }
    }
}
