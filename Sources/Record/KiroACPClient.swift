import Foundation

struct KiroACPClient {
    private let configuredExecutable: String?
    private let timeout: TimeInterval

    init(executable: String? = nil, timeout: TimeInterval = 300) {
        self.configuredExecutable = executable
        self.timeout = timeout
    }

    enum ClientError: LocalizedError {
        case unavailable
        case invalidReply
        case timedOut
        case agentError(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "kiro-cli is not available. Set RECORD_KIRO_CLI to its absolute path or add it to PATH."
            case .invalidReply:
                "kiro-cli ACP returned an unreadable response."
            case .timedOut:
                "kiro-cli did not respond in time."
            case .agentError(let message):
                "kiro-cli ACP failed: \(message)"
            }
        }
    }

    func ask(question: String, evidence: [TranscriptSegment], visualImage: Data?) async throws -> String {
        guard let executable = executablePath() else {
            throw ClientError.unavailable
        }
        let prompt = KiroPrompt.opening(question: question, evidence: evidence)
        let timeout = self.timeout
        return try await Task.detached(priority: .userInitiated) {
            try ACPProcess(executable: executable, timeout: timeout)
                .ask(prompt: prompt, visualImage: visualImage)
        }.value
    }

    /// Starts a long-lived conversation with kiro-cli that can accept
    /// follow-up prompts. Returns nil if kiro-cli can't be found.
    func startConversation() -> KiroConversation? {
        guard let executable = executablePath() else { return nil }
        let configuredTimeout = UserDefaults.standard.object(forKey: "record.kiroTimeoutSeconds") as? Double
        let effectiveTimeout = max(30, configuredTimeout ?? timeout)
        return KiroConversation(executable: executable, timeout: effectiveTimeout)
    }

    private func executablePath() -> String? {
        if let configuredExecutable, FileManager.default.isExecutableFile(atPath: configuredExecutable) {
            return resolveSymlinks(configuredExecutable)
        }
        let userOverride = UserDefaults.standard.string(forKey: "record.kiroExecutableOverride")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let userOverride, !userOverride.isEmpty,
           FileManager.default.isExecutableFile(atPath: userOverride) {
            return resolveSymlinks(userOverride)
        }
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["RECORD_KIRO_CLI"], FileManager.default.isExecutableFile(atPath: configured) {
            return resolveSymlinks(configured)
        }
        // Prefer the real binary inside the Kiro CLI.app bundle over any
        // symlinks in the user's PATH. Rust CLIs typically use
        // `std::env::current_exe()` to locate their companion resource
        // files, and going through a symlink can send that lookup somewhere
        // that doesn't have them, causing kiro-cli to die at startup with
        // `No such file or directory (os error 2)`.
        let bundlePaths = [
            "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"
        ]
        for path in bundlePaths where FileManager.default.isExecutableFile(atPath: path) {
            return resolveSymlinks(path)
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/kiro-cli"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return resolveSymlinks(candidate)
            }
        }
        // Well-known dev install locations as last-resort fallbacks.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras: [String] = [
            "\(home)/.local/bin/kiro-cli",
            "\(home)/.kiro/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
            "/opt/homebrew/bin/kiro-cli"
        ]
        for candidate in extras where FileManager.default.isExecutableFile(atPath: candidate) {
            return resolveSymlinks(candidate)
        }
        return nil
    }

    private func resolveSymlinks(_ path: String) -> String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path))
            .flatMap { resolved -> String? in
                // destinationOfSymbolicLink returns the target as stored,
                // which may itself be relative or another symlink. Ask the
                // URL machinery to fully resolve.
                let base = URL(fileURLWithPath: path).deletingLastPathComponent()
                let resolvedURL = URL(fileURLWithPath: resolved, relativeTo: base).resolvingSymlinksInPath()
                return resolvedURL.path
            } ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

private final class ACPProcess: @unchecked Sendable {
    private let executable: String
    private let timeout: TimeInterval
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let stderr = Pipe()
    private var unread = Data()
    private var answerChunks: [String] = []
    private var expectedResponseID: Int?
    private var deadline = Date.distantFuture

    init(executable: String, timeout: TimeInterval) {
        self.executable = executable
        self.timeout = timeout
    }

    func ask(prompt: String, visualImage: Data?) throws -> String {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["acp"]
        process.currentDirectoryURL = URL(fileURLWithPath: KiroWorkspace.path())
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = KiroWorkspace.home()
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderr
        // Drain stderr so a chatty CLI can't deadlock its own pipe.
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        try process.run()
        defer {
            stderr.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }

        _ = try request(
            id: 1,
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": [:],
                "clientInfo": ["name": "Record", "version": "0.1.0"]
            ]
        )

        let session = try request(
            id: 2,
            method: "session/new",
            params: [
                "cwd": KiroWorkspace.path(),
                "mcpServers": []
            ]
        )
        guard let sessionID = value(at: ["sessionId"], in: session) as? String else {
            throw KiroACPClient.ClientError.invalidReply
        }

        var promptBlocks: [[String: Any]] = [["type": "text", "text": prompt]]
        if let visualImage {
            promptBlocks.append([
                "type": "image",
                "mimeType": "image/jpeg",
                "data": visualImage.base64EncodedString()
            ])
        }

        _ = try request(
            id: 3,
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": promptBlocks
            ]
        )

        let answer = answerChunks.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            throw KiroACPClient.ClientError.invalidReply
        }
        return answer
    }

    private func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))

        expectedResponseID = id
        deadline = Date.now.addingTimeInterval(timeout)
        while let message = try nextMessage() {
            if let error = message["error"] as? [String: Any] {
                throw KiroACPClient.ClientError.agentError(error["message"] as? String ?? "Unknown error")
            }
            if let responseID = message["id"] as? Int, responseID == id {
                return message["result"] as? [String: Any] ?? [:]
            }
            // Only capture agent text once we're waiting for the prompt reply.
            if id == 3 {
                captureAnswerChunk(message)
            }
        }
        throw KiroACPClient.ClientError.invalidReply
    }

    private func nextMessage() throws -> [String: Any]? {
        while true {
            if let newline = unread.firstIndex(of: 0x0A) {
                let line = unread.prefix(upTo: newline)
                unread.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                return object
            }
            if Date.now >= deadline {
                throw KiroACPClient.ClientError.timedOut
            }
            let data = output.fileHandleForReading.availableData
            if data.isEmpty {
                if !process.isRunning { return nil }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            unread.append(data)
        }
    }

    private func captureAnswerChunk(_ message: [String: Any]) {
        guard message["method"] as? String == "session/update",
              let params = message["params"] as? [String: Any],
              let update = params["update"] as? [String: Any] else {
            return
        }
        // Prefer the "agent_message_chunk" style updates.
        if let kind = update["sessionUpdate"] as? String,
           kind != "agent_message_chunk" && kind != "message_chunk" {
            return
        }
        if let content = update["content"] as? [String: Any],
           content["type"] as? String != "image",
           let text = content["text"] as? String {
            answerChunks.append(text)
        } else if let text = update["text"] as? String {
            answerChunks.append(text)
        }
    }

    private func value(at path: [String], in object: [String: Any]) -> Any? {
        path.reduce(object as Any?) { partial, key in
            (partial as? [String: Any])?[key]
        }
    }
}


enum KiroPrompt {
    enum Mode {
        case singleMeeting
        case archive
    }

    /// Builds an evidence-scoped prompt for the FIRST message going through
    /// a given Kiro ACP session. If `priorTurns` is provided, they're
    /// included as memory so Kiro can continue a chat whose original
    /// process is no longer alive (e.g., the user resumed a saved chat).
    static func opening(
        question: String,
        evidence: [TranscriptSegment],
        hasAttachments: Bool = false,
        priorTurns: [ChatTurn]? = nil,
        mode: Mode = .singleMeeting
    ) -> String {
        let transcript = evidence.map {
            "[\($0.timestamp.formatted(date: .omitted, time: .standard))] \($0.source.title): \($0.text)"
        }.joined(separator: "\n")

        // Prior-conversation block — up to the last 12 turns, question+answer pairs.
        var memoryBlock = ""
        if let priorTurns, !priorTurns.isEmpty {
            let recent = priorTurns.suffix(12)
            let lines = recent.flatMap { turn -> [String] in
                var out = ["User: \(turn.question)"]
                if !turn.answer.isEmpty { out.append("Assistant: \(turn.answer)") }
                return out
            }
            memoryBlock = """

            Prior conversation (this chat was resumed from a saved thread; treat this as your memory of what we already discussed):
            \(lines.joined(separator: "\n"))
            """
        }

        // No meeting, no attachments, no prior — general chat.
        if evidence.isEmpty, !hasAttachments, memoryBlock.isEmpty {
            return """
            You are Kiro answering a user's question inside the Record meeting-notes app.
            There is no meeting transcript or attached document for this question, so answer
            using your general knowledge. Be direct and concise.

            Question: \(question)
            """
        }

        let intro: String
        switch mode {
        case .archive:
            intro = """
            You are Kiro answering the user's question about their SAVED MEETING ARCHIVE inside the Record app. The evidence below is a synthesized index of every meeting the user has saved — one line per meeting with its title, date, duration, tag list, and auto-generated summary — plus, when the question includes specific keywords, any transcript segments that matched those keywords (prefixed with "[From "<meeting title>"]").

            Answer based on what's in this archive. When you reference a meeting, name it in your answer. When you cite a transcript snippet, include the meeting title so the user can find it. If the archive doesn't have enough information, say so and suggest what to record next.
            """
        case .singleMeeting:
            if evidence.isEmpty && hasAttachments {
                intro = "Answer using the attached documents below. We may keep talking in follow-up messages, so remember them."
            } else if hasAttachments {
                intro = "Answer using this meeting's evidence AND the attached documents below. Cite meeting timestamps when the answer comes from the transcript. If the answer comes from an attachment, name the file. We may keep talking, so remember both the evidence and the attachments."
            } else if !evidence.isEmpty {
                intro = "Answer only from this meeting's evidence. Cite the relevant timestamps. If the evidence doesn't answer the question, say so. We may keep talking about this meeting in follow-up messages, so remember the evidence below."
            } else {
                intro = "You are continuing a previous conversation. Refer back to the prior turns for context and answer the user's next question below."
            }
        }

        let evidenceBlock: String
        if evidence.isEmpty {
            evidenceBlock = mode == .archive ? "(the user has no saved meetings yet)" : "(no meeting transcript yet)"
        } else {
            evidenceBlock = transcript
        }

        return """
        \(intro)
        \(memoryBlock)

        Question: \(question)

        Evidence:
        \(evidenceBlock)
        """
    }
}

enum KiroWorkspace {
    /// Returns a dedicated scratch directory (created if missing) inside
    /// Record's Application Support folder. Passed to kiro-cli as its cwd
    /// so it doesn't try to walk the user's home directory.
    static func path() -> String {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "Record/kiro-workspace")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base.path
        } catch {
            return NSTemporaryDirectory()
        }
    }

    /// Returns a sandboxed HOME directory to hand to kiro-cli. Symlinks pass
    /// through kiro's config/state but not TCC-protected user folders, and a
    /// stripped `settings/mcp.json` prevents kiro-cli from launching MCP
    /// servers that hang or fail.
    static func home() -> String {
        let fileManager = FileManager.default
        let userHome = fileManager.homeDirectoryForCurrentUser
        let baseURL: URL
        do {
            baseURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "Record/kiro-home")
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            return userHome.path
        }
        // Harmless config directories (nothing TCC-protected).
        let symlinkNames = [".aws", ".config", ".cache", "Library"]
        for name in symlinkNames {
            let source = userHome.appending(path: name)
            let destination = baseURL.appending(path: name)
            if !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: source.path) {
                try? fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
            }
        }
        let kiroDest = baseURL.appending(path: ".kiro")
        try? rebuildKiroMirror(source: userHome.appending(path: ".kiro"), destination: kiroDest)
        return baseURL.path
    }

    /// Prepends common developer bin directories to whatever PATH the GUI
    /// launcher inherited. GUI-launched apps only see /usr/bin:/bin:/usr/sbin:/sbin
    /// by default, which is too narrow for anything kiro-cli wants to spawn.
    static func enhancedPath(base: String?) -> String {
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        var parts: [String] = [
            "\(userHome)/.local/bin",
            "\(userHome)/.cargo/bin",
            "\(userHome)/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin"
        ]
        if let base, !base.isEmpty {
            parts.append(contentsOf: base.split(separator: ":").map(String.init))
        }
        parts.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        // Dedupe while preserving order.
        var seen: Set<String> = []
        return parts.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Path of the log file we tee kiro-cli's stderr into.
    static func stderrLogURL() -> URL {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "Record")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base.appending(path: "kiro-stderr.log")
        } catch {
            return URL(fileURLWithPath: "/tmp/record-kiro-stderr.log")
        }
    }

    private static func rebuildKiroMirror(source: URL, destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        let attrs = try? fileManager.attributesOfItem(atPath: destination.path)
        if attrs?[.type] as? FileAttributeType == .typeSymbolicLink {
            try? fileManager.removeItem(at: destination)
        }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        // Symlink everything except settings/, which we'll rebuild.
        let children = (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? []
        for name in children where name != "settings" {
            let child = source.appending(path: name)
            let mirror = destination.appending(path: name)
            if !fileManager.fileExists(atPath: mirror.path) {
                try? fileManager.createSymbolicLink(at: mirror, withDestinationURL: child)
            }
        }

        let settingsSource = source.appending(path: "settings")
        let settingsDest = destination.appending(path: "settings")
        if fileManager.fileExists(atPath: settingsSource.path) {
            let sAttrs = try? fileManager.attributesOfItem(atPath: settingsDest.path)
            if sAttrs?[.type] as? FileAttributeType == .typeSymbolicLink {
                try? fileManager.removeItem(at: settingsDest)
            }
            try? fileManager.createDirectory(at: settingsDest, withIntermediateDirectories: true)
            let overrides: Set<String> = ["mcp.json", "mcp.lock"]
            let settingsChildren = (try? fileManager.contentsOfDirectory(atPath: settingsSource.path)) ?? []
            for name in settingsChildren where !overrides.contains(name) {
                let child = settingsSource.appending(path: name)
                let mirror = settingsDest.appending(path: name)
                if !fileManager.fileExists(atPath: mirror.path) {
                    try? fileManager.createSymbolicLink(at: mirror, withDestinationURL: child)
                }
            }
            let emptyMCP = settingsDest.appending(path: "mcp.json")
            if !fileManager.fileExists(atPath: emptyMCP.path) {
                try? Data("{\"mcpServers\":{}}\n".utf8).write(to: emptyMCP)
            }
        }

        let legacy = destination.appending(path: "mcp.json")
        if !fileManager.fileExists(atPath: legacy.path) {
            try? Data("{\"mcpServers\":{}}\n".utf8).write(to: legacy)
        }
    }
}
