import Foundation

/// Parallel map for CPU/IO-bound synchronous work (directory listings, plist reads, sizing).
/// Each index is written by exactly one iteration into a pre-allocated buffer.
func concurrentMap<T, R>(_ items: [T], _ transform: (T) -> R) -> [R] {
    guard items.count > 1 else { return items.map(transform) }
    let buffer = UnsafeMutableBufferPointer<R?>.allocate(capacity: items.count)
    buffer.initialize(repeating: nil)
    defer {
        buffer.baseAddress?.deinitialize(count: items.count)
        buffer.deallocate()
    }
    items.withUnsafeBufferPointer { input in
        DispatchQueue.concurrentPerform(iterations: input.count) { i in
            buffer[i] = transform(input[i])
        }
    }
    return buffer.map { $0! }
}
