import Foundation

/// A short researched answer: a title, up to four paragraphs, and where it came from.
struct ResearchReport {
    var question: String
    var title: String
    var paragraphs: [String]
    var sources: [(title: String, url: URL)]

    /// Plain text, for him (and the phone's saved transcript).
    var plainText: String {
        ([title] + paragraphs).joined(separator: "\n\n")
    }
}

/// Looks things up with AI reasoning (Gemini or DeepSeek).
enum WebResearch {
    enum ResearchError: LocalizedError {
        case noKey, failed(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "I need an AI API key for research (Gemini or DeepSeek). Add one under Gemini Key or DeepSeek Key in the menu bar."
            case .failed(let why): return "The research didn't come back: \(why.prefix(160))"
            }
        }
    }

    static func research(_ question: String, context: String?) async throws -> ResearchReport {
        guard let ai = AIConfig.resolve() else {
            throw ResearchError.noKey
        }
        var request = URLRequest(url: ai.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(ai.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var input = question
        if let context, !context.isEmpty {
            input += "\n\nWhat's on the user's screen, for context:\n\(context)"
        }

        let instructions = """
        Research the question and write a short, friendly report for a busy person. \
        First line: a plain title of under eight words. \
        Then one to four short paragraphs (four at most), leading with the direct answer, then the most useful details. \
        Plain text only: no markdown, no headings, no bullet lists, and no inline markdown links. \
        At the end, if relevant documentation or reference sites exist, add up to three sources formatted as: \
        SOURCE: Title | https://example.com
        """

        let payload: [String: Any] = [
            "model": ai.model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": input],
            ],
            "max_tokens": 1000,
            "temperature": 0.3,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var text = message["content"] as? String else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw ResearchError.failed("\(code) \(detail)")
        }

        var sources: [(String, URL)] = []
        let rawLines = text.components(separatedBy: "\n")
        var cleanLines: [String] = []

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("SOURCE:") {
                let rest = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                let parts = rest.components(separatedBy: "|")
                if parts.count >= 2,
                   let urlString = parts.last?.trimmingCharacters(in: .whitespaces),
                   let url = URL(string: clean(urlString)) {
                    let sourceTitle = parts.first?.trimmingCharacters(in: .whitespaces) ?? url.host ?? "Source"
                    sources.append((sourceTitle, url))
                } else if let url = URL(string: clean(rest)) {
                    sources.append((url.host ?? "Source", url))
                }
            } else {
                cleanLines.append(line)
            }
        }

        text = cleanLines.joined(separator: "\n")
        // Drop inline citations and markdown
        text = text.replacingOccurrences(of: #"\s*\(\[[^\]]*\]\([^)]*\)\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*\[https?://[^\]]*\]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "#", with: "")

        let blocks = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let title = blocks.first else { throw ResearchError.failed("empty answer") }

        return ResearchReport(
            question: question,
            title: title,
            paragraphs: Array(blocks.dropFirst().prefix(4)),
            sources: Array(sources.prefix(5))
        )
    }

    /// Removes tracking parameters the search tool adds.
    private static func clean(_ link: String) -> String {
        guard var parts = URLComponents(string: link) else { return link }
        parts.queryItems = parts.queryItems?.filter { $0.name != "utm_source" }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.string ?? link
    }
}
