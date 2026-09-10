import Foundation

/// One user question and Kiro's answer within an ongoing conversation.
/// One user question and Kiro's answer within an ongoing conversation.
struct ChatTurn: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    let question: String
    var answer: String
    var isLoading: Bool
    var errorMessage: String?
    let timestamp: Date
    var attachmentNames: [String] = []
}

/// A single, long-lived Kiro-CLI ACP process that can accept multiple
/// follow-up prompts within one session. Prompts run serially on the actor,
/// so callers can fire off `send(prompt:)` from anywhere without stepping
/// on the previous exchange.
actor KiroConversation {
    private let executable: String
    private let timeout: TimeInterval
    private let cwd: String
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var stderr: Pipe?
    private var logHandle: FileHandle?
    /// Tail of the child process's stderr. Surfaced in timeout errors so we
    /// can tell whether kiro-cli was stuck on auth, tool init, or something else.
    private let stderrTail = StderrTail()
    private var unread = Data()
    private var sessionID: String?
    private var nextRequestID = 1
    private var answerChunks: [String] = []
    private var captureAnswers = false

    init(executable: String, timeout: TimeInterval = 300, cwd: String? = nil) {
        self.executable = executable
        self.timeout = timeout
        self.cwd = cwd ?? KiroWorkspace.path()
    }

    deinit {
        process?.terminate()
    }

    func send(prompt: String, visualImage: Data? = nil, extraImages: [Data] = []) async throws -> String {
        if process == nil {
            try startProcess()
            try initializeSession()
        }
        var promptBlocks: [[String: Any]] = [["type": "text", "text": prompt]]
        if let visualImage {
            promptBlocks.append([
                "type": "image",
                "mimeType": "image/jpeg",
                "data": visualImage.base64EncodedString()
            ])
        }
        for image in extraImages {
            promptBlocks.append([
                "type": "image",
                "mimeType": "image/jpeg",
                "data": image.base64EncodedString()
            ])
        }
        guard let sessionID else { throw KiroACPClient.ClientError.invalidReply }

        answerChunks.removeAll(keepingCapacity: true)
        captureAnswers = true
        defer { captureAnswers = false }

        let id = nextRequestID
        nextRequestID += 1
        _ = try request(
            id: id,
            method: "session/prompt",
            params: ["sessionId": sessionID, "prompt": promptBlocks]
        )
        let answer = answerChunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw KiroACPClient.ClientError.invalidReply }
        return answer
    }

    /// Terminate the process so the next `send()` opens a fresh session
    /// with no context carry-over.
    func end() {
        if let input {
            try? input.fileHandleForWriting.close()
        }
        stderr?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        try? logHandle?.close()
        logHandle = nil
        process = nil
        input = nil
        output = nil
        stderr = nil
        sessionID = nil
        unread.removeAll()
        answerChunks.removeAll()
        nextRequestID = 1
    }

    // MARK: - Internals

    private func startProcess() throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["acp"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = KiroWorkspace.home()
        env["PATH"] = KiroWorkspace.enhancedPath(base: env["PATH"])
        env["USER"] = env["USER"] ?? NSUserName()
        env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        env["SHELL"] = env["SHELL"] ?? "/bin/zsh"
        env["TMPDIR"] = env["TMPDIR"] ?? "/tmp/"
        env["TERM"] = env["TERM"] ?? "dumb"
        env["CI"] = "1"  // hint to any Rust CLI that we're non-interactive
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = stderr

        // Tee stderr to a log file the user can open from the menu.
        let logURL = KiroWorkspace.stderrLogURL()
        try? FileManager.default.removeItem(at: logURL) // keep the last run only
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        try? logHandle?.write(contentsOf: Data("""
            === Record → kiro-cli ACP session ===
            executable: \(executable)
            cwd:        \(cwd)
            home:       \(env["HOME"] ?? "?")
            path:       \(env["PATH"] ?? "?")
            timestamp:  \(Date.now)
            
            """.utf8))

        stderr.fileHandleForReading.readabilityHandler = { [stderrTail] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderrTail.append(chunk)
                try? logHandle?.write(contentsOf: Data("STDERR: ".utf8))
                try? logHandle?.write(contentsOf: chunk)
            }
        }
        do {
            try process.run()
        } catch {
            try? logHandle?.write(contentsOf: Data("FAILED TO SPAWN: \(error.localizedDescription)\n".utf8))
            throw KiroACPClient.ClientError.agentError(error.localizedDescription)
        }
        try? logHandle?.write(contentsOf: Data("PID: \(process.processIdentifier)\n\n".utf8))
        self.process = process
        self.input = input
        self.output = output
        self.stderr = stderr
        self.logHandle = logHandle
    }

    /// Log every JSON-RPC frame we write to kiro-cli's stdin so the user can
    /// diff it against a working shell probe.
    private func logRequest(_ data: Data) {
        let preview = String(data: data.prefix(2_000), encoding: .utf8) ?? "<binary>"
        try? logHandle?.write(contentsOf: Data("SEND (\(data.count)B): \(preview)\n".utf8))
    }

    private func initializeSession() throws {
        _ = try request(
            id: nextRequestID,
            method: "initialize",
            params: [
                "protocolVersion": 1,
                "clientCapabilities": [:],
                "clientInfo": ["name": "Record", "version": "0.2.0"]
            ]
        )
        nextRequestID += 1

        let session = try request(
            id: nextRequestID,
            method: "session/new",
            params: ["cwd": cwd, "mcpServers": []]
        )
        nextRequestID += 1
        guard let id = value(at: ["sessionId"], in: session) as? String else {
            throw KiroACPClient.ClientError.invalidReply
        }
        sessionID = id
    }

    private func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        guard let input else { throw KiroACPClient.ClientError.invalidReply }
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        logRequest(data)
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))

        let deadline = Date.now.addingTimeInterval(timeout)
        while let message = try nextMessage(deadline: deadline) {
            if let error = message["error"] as? [String: Any] {
                throw KiroACPClient.ClientError.agentError(error["message"] as? String ?? "Unknown error")
            }
            if let responseID = message["id"] as? Int, responseID == id {
                return message["result"] as? [String: Any] ?? [:]
            }
            if captureAnswers {
                captureAnswerChunk(message)
            }
        }

        // Fell through nextMessage — figure out whether the process died or
        // we hit the deadline, and include stderr context either way.
        let tail = stderrTail.snapshot()
        let processDied = process?.isRunning == false
        if processDied {
            let exit = process?.terminationStatus ?? -1
            try? logHandle?.write(contentsOf: Data("EXIT status=\(exit)\n".utf8))
            let body = tail.isEmpty
                ? "kiro-cli exited (status \(exit)) before answering. No stderr output. See Kiro log for details."
                : "kiro-cli exited (status \(exit)) before answering. Stderr:\n\(tail)"
            throw KiroACPClient.ClientError.agentError(body)
        }
        if !tail.isEmpty {
            throw KiroACPClient.ClientError.agentError(
                "kiro-cli didn't reply within \(Int(timeout))s. Recent stderr:\n\(tail)"
            )
        }
        throw KiroACPClient.ClientError.timedOut
    }

    private func nextMessage(deadline: Date) throws -> [String: Any]? {
        while true {
            if let newline = unread.firstIndex(of: 0x0A) {
                let line = unread.prefix(upTo: newline)
                unread.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    return object
                }
                continue
            }
            if Date.now >= deadline { return nil } // deadline hit; caller handles stderr context
            guard let output else { return nil }
            let data = output.fileHandleForReading.availableData
            if data.isEmpty {
                if let process, !process.isRunning { return nil }
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


/// Lock-guarded rolling buffer that keeps the last N bytes of stderr from
/// kiro-cli. Written from the pipe's readabilityHandler thread and read
/// from the actor when we need to build an error message.
final class StderrTail: @unchecked Sendable {
    private let capacity: Int
    private var buffer = Data()
    private let lock = NSLock()

    init(capacity: Int = 4_096) {
        self.capacity = capacity
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
