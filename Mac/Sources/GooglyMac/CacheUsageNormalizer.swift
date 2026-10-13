import Foundation

/// How confident Bluey can be about a provider's cache telemetry.
public enum CacheEvidence: String, Codable, Sendable {
    /// The provider reported a cache hit greater than zero.
    case confirmed
    /// The provider reported cache telemetry and the hit count was zero.
    case reportedNoHit
    /// Usage was returned but carried no usable cache field.
    case usageWithoutCacheField
    /// No usage object was returned at all.
    case usageUnavailable
}

/// Provider-neutral usage. Missing fields stay `nil`; Bluey never invents a hit.
public struct NormalizedTokenUsage: Codable, Equatable, Sendable {
    public let totalInputTokens: Int?
    public let cachedInputTokens: Int?
    public let uncachedInputTokens: Int?
    public let outputTokens: Int?
    public let evidence: CacheEvidence
    public let warningCode: String?

    public init(totalInputTokens: Int?,
                cachedInputTokens: Int?,
                uncachedInputTokens: Int?,
                outputTokens: Int?,
                evidence: CacheEvidence,
                warningCode: String? = nil) {
        self.totalInputTokens = totalInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.uncachedInputTokens = uncachedInputTokens
        self.outputTokens = outputTokens
        self.evidence = evidence
        self.warningCode = warningCode
    }
}

/// Parses provider usage JSON into `NormalizedTokenUsage` with explicit
/// precedence and fixed, non-sensitive warning codes.
public struct CacheUsageNormalizer: Sendable {
    public init() {}

    /// A sanity ceiling: no real prompt is anywhere near two billion tokens.
    private static let tokenCeiling = 2_000_000_000.0

    public func normalize(data: Data, provider: AIProvider, model: String) -> NormalizedTokenUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else {
            return NormalizedTokenUsage(totalInputTokens: nil, cachedInputTokens: nil,
                                        uncachedInputTokens: nil, outputTokens: nil,
                                        evidence: .usageUnavailable, warningCode: nil)
        }
        return normalize(usage: usage)
    }

    public func normalize(usage: [String: Any]) -> NormalizedTokenUsage {
        var warning: String?
        func note(_ code: String?) { if warning == nil, let code { warning = code } }

        let total = parseToken(usage["prompt_tokens"])
        let output = parseToken(usage["completion_tokens"])
        note(total.warning); note(output.warning)

        let hit = parseToken(usage["prompt_cache_hit_tokens"])
        let miss = parseToken(usage["prompt_cache_miss_tokens"])
        note(hit.warning); note(miss.warning)

        var detailsCached: ParsedToken?
        if let details = usage["prompt_tokens_details"] as? [String: Any] {
            detailsCached = parseToken(details["cached_tokens"])
            note(detailsCached?.warning)
        }

        let aliasKeys = ["cached_content_token_count", "total_cached_tokens", "cachedContentTokenCount"]
        var aliasCached: ParsedToken?
        for key in aliasKeys where usage[key] != nil {
            aliasCached = parseToken(usage[key])
            note(aliasCached?.warning)
            break
        }

        let hasCacheSignal = usage["prompt_cache_hit_tokens"] != nil
            || usage["prompt_cache_miss_tokens"] != nil
            || (detailsCached != nil && detailsCached?.present == true)
            || (aliasCached != nil && aliasCached?.present == true)

        // No usable cache field: usage is known but cache state is unknown.
        guard hasCacheSignal else {
            return NormalizedTokenUsage(totalInputTokens: total.value, cachedInputTokens: nil,
                                        uncachedInputTokens: nil, outputTokens: output.value,
                                        evidence: .usageWithoutCacheField, warningCode: warning)
        }

        // Prefer explicit hit/miss when both are present and consistent.
        if let hitValue = hit.value, let missValue = miss.value {
            if let totalValue = total.value, totalValue != hitValue + missValue {
                return unknown(total: total.value, output: output.value,
                               warning: "inconsistent_cache_totals")
            }
            return result(total: total.value ?? (hitValue + missValue), cached: hitValue,
                          uncached: missValue, output: output.value, warning: warning)
        }

        // Explicit hit without an explicit miss.
        if let hitValue = hit.value {
            if let totalValue = total.value, hitValue > totalValue {
                return unknown(total: total.value, output: output.value, warning: "cached_exceeds_total")
            }
            let uncached = total.value.map { max(0, $0 - hitValue) }
            return result(total: total.value, cached: hitValue, uncached: uncached,
                          output: output.value, warning: warning)
        }

        // Explicit miss without an explicit hit.
        if let missValue = miss.value {
            let cached = total.value.map { max(0, $0 - missValue) }
            return result(total: total.value, cached: cached, uncached: missValue,
                          output: output.value, warning: warning)
        }

        // Generic/OpenAI-compatible cached details or a known alias.
        if let cachedValue = detailsCached?.value ?? aliasCached?.value {
            if let totalValue = total.value, cachedValue > totalValue {
                return unknown(total: total.value, output: output.value, warning: "cached_exceeds_total")
            }
            let uncached = total.value.map { max(0, $0 - cachedValue) }
            return result(total: total.value, cached: cachedValue, uncached: uncached,
                          output: output.value, warning: warning)
        }

        // A cache field was present but every value was invalid.
        return unknown(total: total.value, output: output.value, warning: warning ?? "invalid_token_value")
    }

    // MARK: - Helpers

    private func result(total: Int?, cached: Int?, uncached: Int?, output: Int?, warning: String?) -> NormalizedTokenUsage {
        let evidence: CacheEvidence = (cached ?? 0) > 0 ? .confirmed : .reportedNoHit
        return NormalizedTokenUsage(totalInputTokens: total, cachedInputTokens: cached,
                                    uncachedInputTokens: uncached, outputTokens: output,
                                    evidence: evidence, warningCode: warning)
    }

    private func unknown(total: Int?, output: Int?, warning: String?) -> NormalizedTokenUsage {
        NormalizedTokenUsage(totalInputTokens: total, cachedInputTokens: nil,
                             uncachedInputTokens: nil, outputTokens: output,
                             evidence: .usageWithoutCacheField, warningCode: warning)
    }

    private struct ParsedToken {
        let value: Int?
        let present: Bool
        let warning: String?
    }

    private func parseToken(_ value: Any?) -> ParsedToken {
        guard let value, !(value is NSNull) else { return ParsedToken(value: nil, present: false, warning: nil) }

        let double: Double
        if value is Bool {
            return ParsedToken(value: nil, present: true, warning: "invalid_token_value")
        } else if let number = value as? NSNumber {
            double = number.doubleValue
        } else if let string = value as? String, let parsed = Double(string.trimmingCharacters(in: .whitespaces)) {
            double = parsed
        } else {
            return ParsedToken(value: nil, present: true, warning: "invalid_token_value")
        }

        guard double.isFinite else {
            return ParsedToken(value: nil, present: true, warning: "invalid_token_value")
        }
        if double < 0 {
            return ParsedToken(value: 0, present: true, warning: "negative_token_value")
        }
        if double > Self.tokenCeiling {
            return ParsedToken(value: nil, present: true, warning: "invalid_token_value")
        }
        return ParsedToken(value: Int(double), present: true, warning: nil)
    }
}
