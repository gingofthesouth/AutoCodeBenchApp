import Foundation

/// A single problem from the AutoCodeBench dataset (one line of the JSONL).
public struct BenchmarkProblem: Codable, Sendable {
    public let question: String
    public let canonicalSolution: String?
    public let demoTestFunc: String?
    public let fullTestFunc: String?
    public let language: String
    public let difficulty: String?

    enum CodingKeys: String, CodingKey {
        case question
        case canonicalSolution = "canonical_solution"
        case demoTestFunc = "demo_test_func"
        case fullTestFunc = "full_test_func"
        case language
        case difficulty
    }

    public init(
        question: String,
        canonicalSolution: String?,
        demoTestFunc: String?,
        fullTestFunc: String?,
        language: String,
        difficulty: String?
    ) {
        self.question = question
        self.canonicalSolution = canonicalSolution
        self.demoTestFunc = demoTestFunc
        self.fullTestFunc = fullTestFunc
        self.language = language
        self.difficulty = difficulty
    }
}

/// Row for inference/evaluation: problem plus optional model output.
public struct BenchmarkRow: Codable, Sendable {
    public var question: String
    public var canonicalSolution: String?
    public var demoTestFunc: String?
    public var fullTestFunc: String?
    public var language: String
    public var difficulty: String?
    public var output: String?

    enum CodingKeys: String, CodingKey {
        case question
        case canonicalSolution = "canonical_solution"
        case demoTestFunc = "demo_test_func"
        case fullTestFunc = "full_test_func"
        case language
        case difficulty
        case output
    }

    public init(from problem: BenchmarkProblem, output: String? = nil) {
        self.question = problem.question
        self.canonicalSolution = problem.canonicalSolution
        self.demoTestFunc = problem.demoTestFunc
        self.fullTestFunc = problem.fullTestFunc
        self.language = problem.language
        self.difficulty = problem.difficulty
        self.output = output
    }
}
