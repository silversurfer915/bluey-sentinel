import XCTest
@testable import GooglyMac

final class CacheUsageNormalizerTests: XCTestCase {
    let normalizer = CacheUsageNormalizer()

    private func normalize(_ json: String, provider: AIProvider = .auto) -> NormalizedTokenUsage {
        normalizer.normalize(data: Data(json.utf8), provider: provider, model: "test-model")
    }

    // MARK: - Provider fixtures

    func testDeepSeekHitAndMissFields() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 1500, "completion_tokens": 80,
                   "prompt_cache_hit_tokens": 1200, "prompt_cache_miss_tokens": 300}}
        """, provider: .deepseek)
        XCTAssertEqual(usage.totalInputTokens, 1500)
        XCTAssertEqual(usage.cachedInputTokens, 1200)
        XCTAssertEqual(usage.uncachedInputTokens, 300)
        XCTAssertEqual(usage.outputTokens, 80)
        XCTAssertEqual(usage.evidence, .confirmed)
        XCTAssertNil(usage.warningCode)
    }

    func testDeepSeekPromptTokensDetailsAlias() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 1500, "completion_tokens": 80,
                   "prompt_tokens_details": {"cached_tokens": 1200}}}
        """, provider: .deepseek)
        XCTAssertEqual(usage.totalInputTokens, 1500)
        XCTAssertEqual(usage.cachedInputTokens, 1200)
        XCTAssertEqual(usage.uncachedInputTokens, 300)
        XCTAssertEqual(usage.evidence, .confirmed)
    }

    func testGeminiOpenAICompatibleCachedDetails() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 2000, "completion_tokens": 120,
                   "prompt_tokens_details": {"cached_tokens": 1600}}}
        """, provider: .gemini)
        XCTAssertEqual(usage.totalInputTokens, 2000)
        XCTAssertEqual(usage.cachedInputTokens, 1600)
        XCTAssertEqual(usage.uncachedInputTokens, 400)
        XCTAssertEqual(usage.evidence, .confirmed)
    }

    func testGeminiNativeCachedContentAlias() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 2000, "cached_content_token_count": 1600, "completion_tokens": 120}}
        """, provider: .gemini)
        XCTAssertEqual(usage.cachedInputTokens, 1600)
        XCTAssertEqual(usage.uncachedInputTokens, 400)
        XCTAssertEqual(usage.evidence, .confirmed)
    }

    func testGeminiUsageWithoutCacheField() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 2000, "completion_tokens": 120}}
        """, provider: .gemini)
        XCTAssertEqual(usage.totalInputTokens, 2000)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertNil(usage.uncachedInputTokens)
        XCTAssertEqual(usage.outputTokens, 120)
        XCTAssertEqual(usage.evidence, .usageWithoutCacheField)
        XCTAssertNil(usage.warningCode)
    }

    func testTokenHarborGenericCachedDetails() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 900, "completion_tokens": 40,
                   "prompt_tokens_details": {"cached_tokens": 450}}}
        """, provider: .tokenHarbor)
        XCTAssertEqual(usage.totalInputTokens, 900)
        XCTAssertEqual(usage.cachedInputTokens, 450)
        XCTAssertEqual(usage.uncachedInputTokens, 450)
        XCTAssertEqual(usage.evidence, .confirmed)
    }

    func testUsageObjectAbsent() {
        let usage = normalize(#"{"choices": [{"message": {"content": "hi"}}]}"#)
        XCTAssertNil(usage.totalInputTokens)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertNil(usage.uncachedInputTokens)
        XCTAssertNil(usage.outputTokens)
        XCTAssertEqual(usage.evidence, .usageUnavailable)
        XCTAssertNil(usage.warningCode)
    }

    func testDeepSeekReportedNoHit() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 1000, "completion_tokens": 10,
                   "prompt_cache_hit_tokens": 0, "prompt_cache_miss_tokens": 1000}}
        """, provider: .deepseek)
        XCTAssertEqual(usage.cachedInputTokens, 0)
        XCTAssertEqual(usage.uncachedInputTokens, 1000)
        XCTAssertEqual(usage.evidence, .reportedNoHit)
    }

    // MARK: - Malformed and inconsistent usage

    func testNegativeValuesAreClampedToZero() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": -5, "completion_tokens": -3,
                   "prompt_tokens_details": {"cached_tokens": -1}}}
        """)
        XCTAssertEqual(usage.totalInputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.cachedInputTokens, 0)
        XCTAssertGreaterThanOrEqual(usage.totalInputTokens ?? 0, 0)
        XCTAssertGreaterThanOrEqual(usage.cachedInputTokens ?? 0, 0)
        XCTAssertEqual(usage.warningCode, "negative_token_value")
    }

    func testCachedGreaterThanTotalIsRejected() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 100, "completion_tokens": 5,
                   "prompt_tokens_details": {"cached_tokens": 500}}}
        """)
        XCTAssertEqual(usage.totalInputTokens, 100)
        XCTAssertNil(usage.cachedInputTokens, "An impossible cached count must not be trusted")
        XCTAssertNil(usage.uncachedInputTokens)
        XCTAssertEqual(usage.evidence, .usageWithoutCacheField)
        XCTAssertEqual(usage.warningCode, "cached_exceeds_total")
    }

    func testHitPlusMissMismatchIsUnknown() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 1000, "prompt_cache_hit_tokens": 800, "prompt_cache_miss_tokens": 100}}
        """, provider: .deepseek)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertNil(usage.uncachedInputTokens)
        XCTAssertEqual(usage.evidence, .usageWithoutCacheField)
        XCTAssertEqual(usage.warningCode, "inconsistent_cache_totals")
    }

    func testNumericStringsAreParsed() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": "1500", "completion_tokens": "80",
                   "prompt_tokens_details": {"cached_tokens": "1200"}}}
        """)
        XCTAssertEqual(usage.totalInputTokens, 1500)
        XCTAssertEqual(usage.cachedInputTokens, 1200)
        XCTAssertEqual(usage.uncachedInputTokens, 300)
        XCTAssertEqual(usage.evidence, .confirmed)
    }

    func testNonNumericStringsAreInvalid() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": "not-a-number",
                   "prompt_tokens_details": {"cached_tokens": "??"}}}
        """)
        XCTAssertNil(usage.totalInputTokens)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertEqual(usage.evidence, .usageWithoutCacheField)
        XCTAssertEqual(usage.warningCode, "invalid_token_value")
    }

    func testEnormousValuesDoNotCrash() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 9223372036854775807, "completion_tokens": 1.0e19,
                   "prompt_tokens_details": {"cached_tokens": 9.0e18}}}
        """)
        XCTAssertNil(usage.totalInputTokens)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertEqual(usage.evidence, .usageWithoutCacheField)
        XCTAssertEqual(usage.warningCode, "invalid_token_value")
    }

    func testDeepSeekHitWithoutMissUsesTotal() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 1500, "prompt_cache_hit_tokens": 1200}}
        """, provider: .deepseek)
        XCTAssertEqual(usage.cachedInputTokens, 1200)
        XCTAssertEqual(usage.uncachedInputTokens, 300)
        XCTAssertEqual(usage.evidence, .confirmed)
    }

    func testDeepSeekMissWithoutHit() {
        let usage = normalize("""
        {"usage": {"prompt_tokens": 1000, "prompt_cache_miss_tokens": 1000}}
        """, provider: .deepseek)
        XCTAssertEqual(usage.cachedInputTokens, 0)
        XCTAssertEqual(usage.uncachedInputTokens, 1000)
        XCTAssertEqual(usage.evidence, .reportedNoHit)
    }

    func testEvidenceRawValuesAreStable() {
        XCTAssertEqual(CacheEvidence.confirmed.rawValue, "confirmed")
        XCTAssertEqual(CacheEvidence.reportedNoHit.rawValue, "reportedNoHit")
        XCTAssertEqual(CacheEvidence.usageWithoutCacheField.rawValue, "usageWithoutCacheField")
        XCTAssertEqual(CacheEvidence.usageUnavailable.rawValue, "usageUnavailable")
    }
}
