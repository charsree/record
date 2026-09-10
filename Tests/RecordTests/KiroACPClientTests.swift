import Foundation
import Testing
@testable import Record

struct KiroACPClientTests {
    @Test
    func readsAStreamedACPAnswer() async throws {
        let script = FileManager.default.temporaryDirectory
            .appending(path: "record-acp-\(UUID().uuidString).zsh")
        let content = """
        #!/bin/zsh
        while IFS= read -r line; do
          if [[ "$line" == *'"id":1'* ]]; then
            print '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
          elif [[ "$line" == *'"id":2'* ]]; then
            print '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"test-session"}}'
          elif [[ "$line" == *'"id":3'* ]]; then
            print '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought","content":{"type":"text","text":"Thinking..."}}}}'
            print '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Oct 14."}}}}'
            print '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
            exit 0
          fi
        done
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let client = KiroACPClient(executable: script.path)
        let answer = try await client.ask(
            question: "When does phase two start?",
            evidence: [TranscriptSegment(source: .visual, text: "Phase 2 starts Oct 14", isFinal: true)],
            visualImage: nil
        )

        #expect(answer == "Oct 14.")
    }

    @Test
    func timesOutWhenAgentDoesNotRespond() async {
        let script = FileManager.default.temporaryDirectory
            .appending(path: "record-acp-timeout-\(UUID().uuidString).zsh")
        // Reads once and then just waits — no reply at all.
        let content = """
        #!/bin/zsh
        read line
        # Sleep in short intervals so a SIGTERM from Process.terminate wakes us.
        for _ in {1..40}; do sleep 0.1; done
        """
        try? content.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let client = KiroACPClient(executable: script.path, timeout: 0.4)
        do {
            _ = try await client.ask(
                question: "?",
                evidence: [TranscriptSegment(source: .microphone, text: "hi", isFinal: true)],
                visualImage: nil
            )
            #expect(Bool(false), "Expected a timeout")
        } catch let error as KiroACPClient.ClientError {
            switch error {
            case .timedOut, .invalidReply:
                break // acceptable — either the read loop timed out or unread produced no message.
            default:
                #expect(Bool(false), "Unexpected error \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error \(error)")
        }
    }
}
