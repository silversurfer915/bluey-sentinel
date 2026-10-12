import Foundation

/// Bounded public web retrieval. Content is always passed to the model as untrusted evidence.
enum LiveWeb {
    struct Source { let title: String; let url: URL; let text: String }
    static func validURL(_ input: String) -> URL? {
        guard let parts = URLComponents(string: input), parts.scheme == "https", parts.user == nil, parts.password == nil,
              let host = parts.host?.lowercased(), host.contains("."), !host.hasSuffix(".local"),
              !["localhost", "127.0.0.1", "0.0.0.0", "169.254.169.254"].contains(host),
              !host.hasPrefix("10."), !host.hasPrefix("192.168."), !host.hasPrefix("172."),
              let url = parts.url else { return nil }
        return url
    }
    static func fetch(_ url: URL) async throws -> String {
        guard validURL(url.absoluteString) != nil else { throw WebResearch.ResearchError.failed("Only public HTTPS pages are supported.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bluey/1.0 (study assistant)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let final = response.url, validURL(final.absoluteString) != nil else { throw WebResearch.ResearchError.failed("The page could not be retrieved.") }
        let mime = response.mimeType ?? ""
        guard mime.contains("text") || mime.contains("html") || mime.contains("json") else { throw WebResearch.ResearchError.failed("This page format is not readable.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count >= 750_000 { break }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?is)<(script|style|noscript)\b[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func searchLinks(_ html: String) -> [(String, URL)] {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<a\b[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html) else { return nil }
            let raw = String(html[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            let target = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw)?.queryItems?.first { $0.name == "uddg" }?.value ?? raw
            guard let url = validURL(target) else { return nil }
            return (plainText(String(html[titleRange])), url)
        }
    }
    static func search(_ question: String) async throws -> [Source] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: question)]
        let html = try await fetch(components.url!)
        let links = Array(searchLinks(html).prefix(4))
        guard !links.isEmpty else { throw WebResearch.ResearchError.failed("Live search is unavailable. Try opening a reference page and asking about it.") }
        var sources: [Source] = []
        for (title, url) in links {
            if let page = try? await fetch(url) {
                let text = String(plainText(page).prefix(7000))
                if !text.isEmpty { sources.append(Source(title: title, url: url, text: text)) }
            }
        }
        guard !sources.isEmpty else { throw WebResearch.ResearchError.failed("Search results were found, but their pages could not be read.") }
        return sources
    }
}
