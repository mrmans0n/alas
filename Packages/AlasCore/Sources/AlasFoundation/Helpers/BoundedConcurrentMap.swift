/// Transforms every item with at most `limit` transforms in flight, returning
/// the outputs in input order regardless of completion order.
public func boundedConcurrentMap<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    limit: Int,
    _ transform: @escaping @Sendable (Item) async -> Output
) async -> [Output] {
    await withTaskGroup(of: (Int, Output).self) { group in
        var outputs = [Output?](repeating: nil, count: items.count)
        var next = 0
        func startNext() {
            let index = next
            let item = items[index]
            group.addTask { (index, await transform(item)) }
            next += 1
        }
        while next < items.count && next < max(limit, 1) {
            startNext()
        }
        while let (index, output) = await group.next() {
            outputs[index] = output
            if next < items.count {
                startNext()
            }
        }
        return outputs.map { $0! }
    }
}
