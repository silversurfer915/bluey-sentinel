import Foundation
import Speech

/// Turns recorded audio into a proper transcript (with speaker labels) and keeps each session's
/// meeting notes as plain files any agent can read: ~/Documents/Bluey Notes/<date> <id>/.
enum MeetingNotes {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bluey Notes", isDirectory: true)
    }

    struct Segment {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    // MARK: Folders

    /// The session's folder, made the first time it's needed.
    static func folder(session: String, started: Date) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        writeReadmeIfNeeded()
        let tag = String(session.prefix(8)).lowercased()
        if let existing = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasSuffix(tag) }) {
            return existing
        }
        let name = DateFormatter.folderName.string(from: started) + " " + tag
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        return url
    }

    private static func writeReadmeIfNeeded() {
        let url = root.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # Bluey Notes

        Meeting notes recorded by Riley's Bluey app (the blueberry on the iPhone). One folder per listening \
        session, named by start time.

        In each session folder:
        - `notes.md`: the full transcript with timestamps and speaker labels, plus Riley's questions to Bluey, \
        Bluey's replies and any research reports, in time order. Start here.
        - `session.json`: the same data, structured.
        - `audio/`: the raw recording, as five-minute AAC chunks.

        Speaker letters (A, B, …) are assigned per five-minute chunk, so the same letter can mean different people \
        in different chunks. Lines marked "(live)" are a rough live transcript for audio that hasn't been fully \
        transcribed yet.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Transcription

    /// Saves the chunk's audio into the session folder and transcribes it using cheap/free STT + DeepSeek.
    static func transcribe(audio: Data, session: String, index: Int, sessionStarted: Date) async throws -> (segments: [Segment], folder: URL) {
        let folder = folder(session: session, started: sessionStarted)
        let audioURL = folder.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        let chunkFile = audioURL.appendingPathComponent(String(format: "chunk-%03d.m4a", index))
        try audio.write(to: chunkFile)

        let rawText = try await transcribeAudio(fileURL: chunkFile, audioData: audio)
        let segments = await diarizeWithAI(rawText: rawText)
        return (segments, folder)
    }

    private static func transcribeAudio(fileURL: URL, audioData: Data) async throws -> String {
        // 1. If Groq key is present, use ultra-fast Groq Whisper API (whisper-large-v3-turbo)
        if let groqKey = Keychain.get(.groq) ?? ProcessInfo.processInfo.environment["GROQ_API_KEY"] {
            if let text = try? await postWhisper(audioData, endpoint: "https://api.groq.com/openai/v1/audio/transcriptions", model: "whisper-large-v3-turbo", key: groqKey) {
                return text
            }
        }
        // 2. Try native Apple Speech framework (FREE, on-device / native macOS)
        do {
            return try await appleSpeechTranscribe(url: fileURL)
        } catch {
            NSLog("Googly: Apple speech transcription failed: \(error)")
        }
        // 3. Fallback to OpenAI Whisper if an OpenAI key is present
        if let openAIKey = Keychain.get(.openai) {
            return try await postWhisper(audioData, endpoint: "https://api.openai.com/v1/audio/transcriptions", model: "whisper-1", key: openAIKey)
        }
        throw NSError(domain: "Googly", code: 1, userInfo: [NSLocalizedDescriptionKey: "No transcription service available. Turn on Apple Speech or add a Groq/OpenAI key."])
    }

    private static func appleSpeechTranscribe(url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw NSError(domain: "Googly", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple Speech Recognizer not available for en-US."])
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    if !hasResumed { hasResumed = true; continuation.resume(throwing: error) }
                } else if let result = result, result.isFinal {
                    if !hasResumed { hasResumed = true; continuation.resume(returning: result.bestTranscription.formattedString) }
                }
            }
        }
    }

    private static func diarizeWithAI(rawText: String) async -> [Segment] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let ai = AIConfig.resolve() else {
            return [Segment(speaker: "?", start: 0, end: 0, text: trimmed)]
        }

        let prompt = """
        The following is a raw audio transcript chunk from a meeting:
        \"\(trimmed)\"

        Please format this transcript with speaker labels (e.g. Speaker A, Speaker B).
        Return ONLY a JSON array of objects:
        [
          {"speaker": "A", "start": 0.0, "end": 10.0, "text": "..."}
        ]
        """

        let body: [String: Any] = [
            "model": ai.model,
            "messages": [
                ["role": "system", "content": "You are a meeting transcription formatter. Format raw speech into speaker turns. Return ONLY a valid JSON array."],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 1500,
            "temperature": 0.2
        ]

        guard let data = try? await AIClient.send(body, ai: ai),
              let message = try? AIClient.message(data),
              let content = message["content"] as? String else {
            return [Segment(speaker: "?", start: 0, end: 0, text: trimmed)]
        }

        // Parse JSON array from content
        var jsonText = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = jsonText.firstIndex(of: "["), let end = jsonText.lastIndex(of: "]"), start < end {
            jsonText = String(jsonText[start...end])
        }
        guard let arrayData = jsonText.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: arrayData) as? [[String: Any]] else {
            return [Segment(speaker: "?", start: 0, end: 0, text: trimmed)]
        }

        let parsed = list.compactMap { item -> Segment? in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            let speaker = item["speaker"] as? String ?? "?"
            let start = item["start"] as? Double ?? 0
            let end = item["end"] as? Double ?? 0
            return Segment(speaker: speaker, start: start, end: end, text: text)
        }
        return parsed.isEmpty ? [Segment(speaker: "?", start: 0, end: 0, text: trimmed)] : parsed
    }

    private static func postWhisper(_ audio: Data, endpoint: String, model: String, key: String) async throws -> String {
        let boundary = "googly-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        guard let url = URL(string: endpoint) else { throw NSError(domain: "Googly", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint"]) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Googly", code: code, userInfo: [NSLocalizedDescriptionKey: "Whisper failed \(code): \(detail)"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Notes files

    /// Writes session.json and notes.md from the phone's copy of the session. Returns the folder.
    @discardableResult
    static func write(session json: [String: Any]) -> URL? {
        guard let id = json["id"] as? String, let startedAt = json["started"] as? Double else { return nil }
        let started = Date(timeIntervalSince1970: startedAt)
        let folder = folder(session: id, started: started)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
        try? markdown(json, started: started).write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return folder
    }

    private static func markdown(_ json: [String: Any], started: Date) -> String {
        let ended = (json["ended"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let entries = json["entries"] as? [[String: Any]] ?? []
        let pending = json["transcribing"] as? Int ?? 0
        let day = DateFormatter()
        day.dateStyle = .full
        day.timeStyle = .short
        let clock = DateFormatter()
        clock.dateFormat = "h:mm:ss a"

        var out = ["# Bluey session: \(day.string(from: started))", ""]
        if let ended {
            let minutes = Int(ended.timeIntervalSince(started) / 60)
            out.append("Ended \(clock.string(from: ended)) (\(minutes / 60)h \(minutes % 60)m).")
        } else {
            out.append("Still recording.")
        }
        if pending > 0 { out.append("\(pending) recording chunk(s) still being transcribed; this file updates when they're done.") }
        let asked = entries.filter { $0["kind"] as? String == "asked" }.count
        if asked > 0 { out.append("Riley asked Bluey \(asked) question(s); they're marked inline below.") }
        out += ["", "## Transcript", ""]

        for entry in entries {
            let text = (entry["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let time = (entry["time"] as? Double).map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            switch entry["kind"] as? String {
            case "transcript":
                out.append("**[\(time)] Speaker \(entry["speaker"] as? String ?? "?"):** \(text)")
            case "heard":
                out.append("[\(time)] (live) \(text)")
            case "asked":
                out.append("> **[\(time)] Riley asked Bluey:** \(text)")
            case "reply":
                out.append("> **Bluey:** \(text)")
            case "report":
                let quoted = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                out.append("> **Research report:**\n" + quoted)
            default:
                out.append("[\(time)] \(text)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let folderName: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}
