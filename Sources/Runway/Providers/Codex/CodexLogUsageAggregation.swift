import Foundation

extension CodexLogUsageScanner {
    private struct EventKey: Hashable {
        var timestamp: Date
        var model: String
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
    }

    private struct PricingContextKey: Hashable {
        var model: String
        var isFast: Bool
    }

    private enum PricingResolution {
        case priced(model: String, context: EventPricingContext)
        case unpriced(model: String?)
    }

    private struct EventPricingContext {
        var rates: ModelRates
        var fastTier: Bool

        func cost(for event: Event) -> Double {
            let nonCached = max(0, event.input - event.cached)
            return rates.costDollars(for: TokenBreakdown(
                input: nonCached,
                cacheRead: event.cached,
                output: event.output,
                isFast: fastTier
            ))
        }
    }

    /// Bucket events into local calendar days. Identical events across files (copied session logs)
    /// count once. Cost is per-event codex math (see type doc).
    ///
    /// Events that can't be priced (an unknown model, or a blank slug) are excluded from every displayed
    /// total — tokens, dollars, the trend, and the model breakdown — because mixing measured tokens with
    /// unpriceable ones makes the figures incoherent. An unknown model's name lands in
    /// `unknownModelsByDay` (the tile's warning triangle), the only place unpriceable usage surfaces.
    /// A blank slug is unattributed, not unknown — there is no name to warn about.
    static func aggregate(
        events: [Event], since: Date, pricing: ModelPricing
    ) -> LogUsageScan {
        var seen: Set<EventKey> = []
        var accumulator = DailyUsageAccumulator()
        var pricingContexts: [PricingContextKey: PricingResolution] = [:]

        for event in events where event.timestamp >= since {
            let key = EventKey(
                timestamp: event.timestamp, model: event.model, input: event.input,
                cached: event.cached, output: event.output, reasoning: event.reasoning, total: event.total
            )
            guard seen.insert(key).inserted else { continue }

            let day = DailyUsageAccumulator.dayKey(from: event.timestamp)
            let contextKey = PricingContextKey(model: event.model, isFast: event.isFast)
            let resolution: PricingResolution
            if let cached = pricingContexts[contextKey] {
                resolution = cached
            } else {
                resolution = resolvePricingContext(
                    rawModel: event.model,
                    isFast: event.isFast,
                    pricing: pricing
                )
                pricingContexts[contextKey] = resolution
            }

            switch resolution {
            case .priced(let model, let context):
                accumulator.add(
                    day: day,
                    tokens: event.total,
                    cost: context.cost(for: event),
                    model: model
                )
            case .unpriced(let model):
                if event.total > 0, let model {
                    accumulator.addUnknownModel(day: day, model: model)
                }
            }
        }

        return accumulator.build()
    }

    private static func resolvePricingContext(
        rawModel: String,
        isFast: Bool,
        pricing: ModelPricing
    ) -> PricingResolution {
        // One trimmed slug feeds pricing, the unknown-model warning, and the breakdown key alike —
        // diverging spellings would let the warning triangle and hover panel disagree.
        guard let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return .unpriced(model: nil)
        }

        let canonicalModel = pricing.supplement.canonicalName(for: model) ?? model
        let isFastAlias = canonicalModel.hasSuffix("-fast")
        let rateModel = isFastAlias ? String(canonicalModel.dropLast("-fast".count)) : canonicalModel

        // Codex speed is a provider tier, not Cursor's `-fast` price variant. Resolve a fast
        // alias through its unscaled base rates, then apply the Codex multiplier exactly once.
        // If a third-party fast-only model has no base entry, retain its already-scaled rate
        // and do not apply a second speed multiplier.
        let baseRates = pricing.resolve(model: rateModel)
        guard let rates = baseRates ?? pricing.resolve(model: model) else {
            return .unpriced(model: model)
        }
        let appliesCodexFastTier = isFastAlias ? baseRates != nil : isFast
        let baseModel = datedBaseModel(rateModel)
        return .priced(
            model: model,
            context: pricingContext(
                rates: rates,
                baseModel: baseModel,
                fastTier: appliesCodexFastTier,
                fastMultiplier: codexPriorityMultiplier(forBaseModel: baseModel, rates: rates)
            )
        )
    }

    /// Codex cost math (ccusage's): non-cached input at the input rate, cached input at the explicit
    /// cache-read rate (or full input when the source publishes no discount), and output (reasoning
    /// included) at the output rate. Supported OpenAI models switch the whole request above 272k.
    static func cost(
        rates: ModelRates,
        event: Event,
        model: String,
        fastTier: Bool,
        fastMultiplier: Double
    ) -> Double {
        pricingContext(
            rates: rates,
            baseModel: datedBaseModel(model),
            fastTier: fastTier,
            fastMultiplier: fastMultiplier
        ).cost(for: event)
    }

    private static func pricingContext(
        rates: ModelRates,
        baseModel: String,
        fastTier: Bool,
        fastMultiplier: Double
    ) -> EventPricingContext {
        var effectiveRates = rates
        if let longContext = codexLongContextRates(forBaseModel: baseModel) {
            effectiveRates.inputAbove200kPerMillion = longContext.input
            effectiveRates.outputAbove200kPerMillion = longContext.output
            effectiveRates.cacheReadAbove200kPerMillion = longContext.cacheRead
            effectiveRates.longContextThresholdTokens = 272_000
        }
        if codexModelHasNoCacheDiscount(baseModel) {
            effectiveRates.cacheReadPerMillion = effectiveRates.inputPerMillion
            effectiveRates.cacheReadAbove200kPerMillion = effectiveRates.inputAbove200kPerMillion
        } else if !rates.cacheReadIsExplicit {
            effectiveRates.cacheReadPerMillion = effectiveRates.inputPerMillion
            effectiveRates.cacheReadAbove200kPerMillion = effectiveRates.inputAbove200kPerMillion
        }
        effectiveRates.fastMultiplier = fastMultiplier

        return EventPricingContext(rates: effectiveRates, fastTier: fastTier)
    }

    /// Codex priority service-tier multipliers are provider-specific and intentionally do not use
    /// the supplement's Cursor `-fast` multipliers. Unknown models retain the catalog/fallback rule.
    private static func codexPriorityMultiplier(forBaseModel baseModel: String, rates: ModelRates) -> Double {
        switch baseModel {
        case "gpt-5.5", "gpt-5.5-pro": return 2.5
        case "gpt-5.4", "gpt-5.4-pro",
             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": return 2
        default: return rates.fastMultiplier == 1 ? 2 : rates.fastMultiplier
        }
    }

    /// OpenAI explicitly publishes no cached-input discount for these Pro models. Keep this
    /// provider rule even while an older bundled catalog lacks cache-rate provenance.
    private static func codexModelHasNoCacheDiscount(_ baseModel: String) -> Bool {
        switch baseModel {
        case "gpt-5.4-pro", "gpt-5.5-pro": return true
        default: return false
        }
    }

    private static func codexLongContextRates(
        forBaseModel baseModel: String
    ) -> (input: Double, output: Double, cacheRead: Double)? {
        switch baseModel {
        case "gpt-5.4": return (5, 22.5, 0.5)
        case "gpt-5.4-pro": return (60, 270, 60)
        case "gpt-5.5": return (10, 45, 1)
        case "gpt-5.5-pro": return (60, 270, 60)
        case "gpt-5.6-sol": return (10, 45, 1)
        case "gpt-5.6-terra": return (5, 22.5, 0.5)
        case "gpt-5.6-luna": return (2, 9, 0.2)
        default: return nil
        }
    }

    private static func datedBaseModel(_ model: String) -> String {
        if model.count > 11 {
            let suffix = model.suffix(11)
            if isDateSuffix(suffix, hyphenated: true) {
                return String(model.dropLast(11))
            }
        }
        if model.count > 9 {
            let suffix = model.suffix(9)
            if isDateSuffix(suffix, hyphenated: false) {
                return String(model.dropLast(9))
            }
        }
        return model
    }

    private static func isDateSuffix(_ suffix: Substring, hyphenated: Bool) -> Bool {
        let expectedCount = hyphenated ? 11 : 9
        guard suffix.utf8.count == expectedCount else { return false }

        for (offset, byte) in suffix.utf8.enumerated() {
            let isSeparator = hyphenated
                ? offset == 0 || offset == 5 || offset == 8
                : offset == 0
            if isSeparator {
                guard byte == 45 else { return false } // "-"
            } else {
                guard (48...57).contains(byte) else { return false } // "0"..."9"
            }
        }
        return true
    }
}
