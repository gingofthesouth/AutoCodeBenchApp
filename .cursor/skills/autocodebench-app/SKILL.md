---
name: autocodebench-app
description: Use Dimillian/Skills, Sosumi, and XcodeBuildMCP for the AutoCodeBench macOS app; how runs and resumability work; sandbox and dataset contracts.
---

# AutoCodeBench app

## When to use

- Implementing or refactoring SwiftUI UI: use **Dimillian/Skills** (especially **swiftui-liquid-glass**, **swiftui-ui-patterns**, **swiftui-view-refactor**, **swiftui-performance-audit**).
- Build and test: use **XcodeBuildMCP** (discover_projs, session-set-defaults, build_macos, test_macos). Do not run `xcodebuild` manually.
- Apple API or HIG details: use **Sosumi MCP** (searchAppleDocumentation, fetchAppleDocumentation).
- Concurrency changes: use **swift-concurrency-expert** to keep Sendable/actor isolation correct.

## Runs and resumability

- One run = one model + one or more languages. Run state is stored under Application Support/AutoCodeBench/runs as `{runId}_state.json` and `{runId}_output.jsonl`.
- Inference only sends prompts for indices that do **not** yet have a non-empty `output`. On Resume, load existing output and continue for missing indices.
- Final `model_output.jsonl` has one line per problem in dataset order with `output` set; evaluation runs when inference is complete.

## Sandbox and dataset

- **Dataset**: Hugging Face `tencent/AutoCodeBenchmark`, file `autocodebench.jsonl`. Download via bundled Python script (requires `huggingface_hub`) or cache path in Application Support.
- **Evaluation**: Sandbox at `http://localhost:8080/submit` (Docker image `hunyuansandbox/multi-language-sandbox:v1`). Payload uses `func_code` (solution), `main_code` (test), `lang`. Pass = both full and demo tests return `exec_outcome: "PASSED"`.

## References

- Dimillian Skills: https://github.com/Dimillian/Skills
- AutoCodeBenchmark sandbox runner: https://github.com/Tencent-Hunyuan/AutoCodeBenchmark/blob/main/call_sandbox.py
- Apple HIG: https://developer.apple.com/design/human-interface-guidelines/

## Update as we learn

- When we adopt a new pattern (Liquid Glass usage, testing approach, provider config, etc.), add a short note here and in `.cursor/rules/autocodebench-macos.mdc` so future sessions stay aligned.
