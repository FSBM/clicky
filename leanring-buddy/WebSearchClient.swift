//
//  WebSearchClient.swift
//  leanring-buddy
//
//  Optional web search hook for research questions. Queries Tavily, Brave
//  Search, or Exa (in priority order) when the user's transcript starts
//  with "search" or "look up". Returns the top 3 results as a formatted
//  context block that gets prepended to the LLM prompt.
//
//  Keys are read from environment variables or UserDefaults. If no keys
//  are set, all methods silently return nil — the app stays fully
//  functional offline.
//

import Foundation

/// Provides web search context for research questions using up to three
/// search providers with automatic fallback. Entirely optional — if no
/// API keys are configured, all calls silently return nil.
@MainActor
final class WebSearchClient {
    /// A single search result with title, snippet, and source URL.
    struct SearchResult {
        let title: String
        let snippet: String
        let url: String
    }

    // MARK: - Key Resolution

    /// Reads an API key from the process environment first, then UserDefaults.
    /// Never hardcodes or fabricates key values.
    private static func resolveKey(envName: String) -> String? {
        if let envValue = ProcessInfo.processInfo.environment[envName],
           !envValue.isEmpty {
            return envValue
        }
        if let defaultsValue = UserDefaults.standard.string(forKey: envName),
           !defaultsValue.isEmpty {
            return defaultsValue
        }
        return nil
    }

    private var tavilyAPIKey: String? { Self.resolveKey(envName: "TAVILY_API_KEY") }
    private var braveSearchAPIKey: String? { Self.resolveKey(envName: "BRAVE_SEARCH_API_KEY") }
    private var exaAPIKey: String? { Self.resolveKey(envName: "EXA_API_KEY") }

    /// Whether any search provider is configured with a key.
    var isConfigured: Bool {
        tavilyAPIKey != nil || braveSearchAPIKey != nil || exaAPIKey != nil
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Public Interface

    /// Returns true if the transcript looks like a search query (starts
    /// with "search" or "look up", case-insensitive).
    func isSearchQuery(_ transcript: String) -> Bool {
        let lowered = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix("search") || lowered.hasPrefix("look up")
    }

    /// Fetches web context for the given query. Tries Tavily → Brave → Exa
    /// in order. Returns a formatted "WEB CONTEXT:" block to prepend to the
    /// LLM prompt, or nil if no providers are available or all fail.
    func fetchSearchContext(for query: String) async -> String? {
        guard isConfigured else { return nil }

        let results = await searchWithFallback(query: query)
        guard !results.isEmpty else { return nil }

        var contextBlock = "WEB CONTEXT (from web search — use to supplement your knowledge):\n"
        for (index, result) in results.prefix(3).enumerated() {
            contextBlock += "\(index + 1). \(result.title)\n"
            contextBlock += "   \(result.snippet)\n"
            contextBlock += "   Source: \(result.url)\n"
        }
        contextBlock += "---\n"
        return contextBlock
    }

    // MARK: - Provider Cascade

    private func searchWithFallback(query: String) async -> [SearchResult] {
        // Tavily (primary)
        if let key = tavilyAPIKey {
            if let results = await searchTavily(query: query, apiKey: key), !results.isEmpty {
                return results
            }
        }

        // Brave Search (fallback 1)
        if let key = braveSearchAPIKey {
            if let results = await searchBrave(query: query, apiKey: key), !results.isEmpty {
                return results
            }
        }

        // Exa (fallback 2)
        if let key = exaAPIKey {
            if let results = await searchExa(query: query, apiKey: key), !results.isEmpty {
                return results
            }
        }

        return []
    }

    // MARK: - Tavily

    private func searchTavily(query: String, apiKey: String) async -> [SearchResult]? {
        guard let url = URL(string: "https://api.tavily.com/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": 3,
            "include_answer": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return nil }

            return results.compactMap { item in
                guard let title = item["title"] as? String,
                      let snippet = item["content"] as? String,
                      let resultURL = item["url"] as? String else { return nil }
                return SearchResult(title: title, snippet: snippet, url: resultURL)
            }
        } catch {
            print("⚠️ WebSearch: Tavily error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Brave Search

    private func searchBrave(query: String, apiKey: String) async -> [SearchResult]? {
        var urlComponents = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        urlComponents?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "3")
        ]
        guard let url = urlComponents?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let web = json["web"] as? [String: Any],
                  let results = web["results"] as? [[String: Any]] else { return nil }

            return results.compactMap { item in
                guard let title = item["title"] as? String,
                      let resultURL = item["url"] as? String else { return nil }
                let snippet = item["description"] as? String ?? ""
                return SearchResult(title: title, snippet: snippet, url: resultURL)
            }
        } catch {
            print("⚠️ WebSearch: Brave error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Exa

    private func searchExa(query: String, apiKey: String) async -> [SearchResult]? {
        guard let url = URL(string: "https://api.exa.ai/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "query": query,
            "num_results": 3,
            "contents": ["text": ["max_characters": 300]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return nil }

            return results.compactMap { item in
                guard let title = item["title"] as? String,
                      let resultURL = item["url"] as? String else { return nil }
                let snippet = item["text"] as? String ?? ""
                return SearchResult(title: title, snippet: snippet, url: resultURL)
            }
        } catch {
            print("⚠️ WebSearch: Exa error: \(error.localizedDescription)")
            return nil
        }
    }
}
