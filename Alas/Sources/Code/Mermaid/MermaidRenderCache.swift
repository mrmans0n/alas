struct MermaidRenderCache {
    private struct Entry {
        let outcome: MermaidRenderOutcome
        let cost: Int
    }

    private var entries: [MermaidRenderKey: Entry] = [:]
    private var recency: [MermaidRenderKey] = []
    private(set) var totalCost = 0
    let countLimit: Int
    let costLimit: Int

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    mutating func value(for key: MermaidRenderKey) -> MermaidRenderOutcome? {
        guard let entry = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return entry.outcome
    }

    mutating func insert(_ outcome: MermaidRenderOutcome, for key: MermaidRenderKey) {
        if let old = entries.removeValue(forKey: key) {
            totalCost -= old.cost
        }
        recency.removeAll { $0 == key }
        entries[key] = Entry(outcome: outcome, cost: outcome.cacheCost)
        recency.append(key)
        totalCost += outcome.cacheCost

        while entries.count > countLimit || totalCost > costLimit {
            guard let victim = recency.first else { break }
            recency.removeFirst()
            if let removed = entries.removeValue(forKey: victim) {
                totalCost -= removed.cost
            }
        }
    }
}
