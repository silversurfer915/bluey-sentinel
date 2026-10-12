import Foundation

/// Lightweight background service for current local weather (used in chatbot companion context).
@MainActor
final class WeatherService {
    static let shared = WeatherService()

    private(set) var currentWeather: String?
    private var lastFetchedAt: Date = .distantPast
    private var isFetching = false

    init() {
        refresh()
    }

    /// Asynchronously refreshes weather without blocking startup or UI. Cached for 20 minutes.
    func refresh(force: Bool = false) {
        guard !isFetching else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastFetchedAt) > 1200 || currentWeather == nil else { return }

        isFetching = true
        Task { [weak self] in
            defer { self?.isFetching = false }
            let weather = await Self.fetchWeatherString()
            if let weather, !weather.isEmpty {
                self?.currentWeather = weather
                self?.lastFetchedAt = Date()
            }
        }
    }

    /// Fetches a clean one-line weather string from wttr.in (e.g. "Overcast, +30°C in Coimbatore").
    private static func fetchWeatherString(location: String? = nil) async -> String? {
        let loc = location?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "https://wttr.in/\(loc)?format=%C,+%t+in+%l") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !text.contains("<html") else {
                return nil
            }
            return text
        } catch {
            return nil
        }
    }
}
