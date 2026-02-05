import Foundation

public struct SandboxDiagnosticsService: Sendable {
    public struct CommandResult: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    private let evaluationService: EvaluationService
    private let imageName = "hunyuansandbox/multi-language-sandbox:v1"
    private let portMapping = "8080:8080"

    public init(evaluationService: EvaluationService = EvaluationService()) {
        self.evaluationService = evaluationService
    }

    public func diagnose() async -> SandboxStatus {
        if !isBrewAvailable() {
            return SandboxStatus(
                kind: .brewMissing,
                message: "Homebrew is required to install Colima and Docker.",
                suggestedCommand: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            )
        }

        if !isDockerAvailable() {
            return SandboxStatus(
                kind: .dockerCLIMissing,
                message: "Docker CLI is not installed. Install Colima and Docker via Homebrew.",
                suggestedCommand: "brew install colima docker docker-compose"
            )
        }

        if !isDockerDaemonRunning() {
            return SandboxStatus(
                kind: .dockerDaemonNotRunning,
                message: "Docker daemon is not running. Start Colima to run Docker.",
                suggestedCommand: "colima start"
            )
        }

        if !isImagePresent() {
            return SandboxStatus(
                kind: .imageNotPresent,
                message: "Sandbox image is not present locally.",
                suggestedCommand: "docker pull \(imageName)"
            )
        }

        if !isContainerRunning() {
            return SandboxStatus(
                kind: .containerNotRunning,
                message: "Sandbox container is not running on port 8080.",
                suggestedCommand: "docker run -d -p \(portMapping) \(imageName)"
            )
        }

        let ok = await evaluationService.healthCheck()
        if ok {
            return SandboxStatus(
                kind: .sandboxReachable,
                message: "Sandbox is reachable and ready."
            )
        }

        return SandboxStatus(
            kind: .containerNotRunning,
            message: "Sandbox container is running, but the API is not responding. Try restarting the container.",
            suggestedCommand: "docker run -d -p \(portMapping) \(imageName)"
        )
    }

    public func installHomebrew() -> CommandResult {
        runCommand("/bin/bash", ["-c", "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | /bin/bash"])
    }

    public func installDockerStack() -> CommandResult {
        runEnvCommand("brew", ["install", "colima", "docker", "docker-compose"])
    }

    public func startColima() -> CommandResult {
        runEnvCommand("colima", ["start"])
    }

    /// Pulls the sandbox image. If `progress` is non-nil, it is called with each line of docker pull stderr (e.g. layer progress).
    public func pullImage(progress: (@Sendable (String) -> Void)? = nil) -> CommandResult {
        runCommandStreaming(
            executable: "/usr/bin/env",
            args: ["docker", "pull", imageName],
            onStderrLine: progress
        )
    }

    public func startContainer() -> CommandResult {
        runEnvCommand("docker", ["run", "-d", "-p", portMapping, imageName])
    }

    private func isBrewAvailable() -> Bool {
        runEnvCommand("brew", ["--version"]).exitCode == 0
    }

    private func isDockerAvailable() -> Bool {
        runEnvCommand("docker", ["--version"]).exitCode == 0
    }

    private func isDockerDaemonRunning() -> Bool {
        let result = runEnvCommand("docker", ["info"])
        if result.exitCode != 0 { return false }
        let combined = (result.stdout + result.stderr).lowercased()
        if combined.contains("cannot connect") { return false }
        return true
    }

    private func isImagePresent() -> Bool {
        let result = runEnvCommand("docker", ["images", "--format", "{{.Repository}}:{{.Tag}}"])
        guard result.exitCode == 0 else { return false }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains(imageName)
    }

    private func isContainerRunning() -> Bool {
        let result = runEnvCommand("docker", ["ps", "--format", "{{.Image}}|{{.Ports}}"])
        guard result.exitCode == 0 else { return false }
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let image = parts[0]
            let ports = parts[1]
            if image == imageName && ports.contains("8080->8080") {
                return true
            }
        }
        return false
    }

    private func runEnvCommand(_ command: String, _ args: [String]) -> CommandResult {
        runCommand("/usr/bin/env", [command] + args)
    }

    /// Runs a command and optionally streams stderr line-by-line to `onStderrLine`. Used for long-running commands like `docker pull`.
    private func runCommandStreaming(
        executable: String,
        args: [String],
        onStderrLine: (@Sendable (String) -> Void)?
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = subprocessEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: String(describing: error))
        }

        let stderrHandle = stderrPipe.fileHandleForReading
        var stderrAccumulator = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            var lineBuffer = ""
            while true {
                let data = stderrHandle.availableData
                if data.isEmpty { break }
                stderrAccumulator.append(data)
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                lineBuffer += chunk
                while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
                    let line = String(lineBuffer[..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                    lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])
                    if !line.isEmpty, let callback = onStderrLine {
                        callback(line)
                    }
                }
            }
            if !lineBuffer.isEmpty, let callback = onStderrLine {
                callback(lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        process.waitUntilExit()
        group.wait()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrString = String(data: stderrAccumulator, encoding: .utf8) ?? ""

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: stderrString
        )
    }

    private func runCommand(_ executable: String, _ args: [String]) -> CommandResult {
        runCommandStreaming(executable: executable, args: args, onStderrLine: nil)
    }

    /// Environment for subprocesses. Includes PATH (with Homebrew) and HOME so that
    /// tools like `brew` run correctly when launched from a GUI app (which doesn't inherit shell env).
    private func subprocessEnvironment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        return [
            "PATH": environmentPath(),
            "HOME": home,
            "USER": user.isEmpty ? "unknown" : user
        ]
    }

    private func environmentPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.orbstack/bin"
        ]
        return paths.joined(separator: ":")
    }
}
