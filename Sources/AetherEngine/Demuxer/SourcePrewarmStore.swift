import Foundation

/// #551: bytes fetched for a source the engine is not playing yet.
///
/// The head always starts at byte zero, which is what makes it useful before anything is known
/// about the container: it is the box chain, the EBML header, and the run of media that follows
/// them. The tail is the 64 KB suffix, present only where the origin has already shown it serves
/// suffix ranges, and it carries its own start because only the origin's `Content-Range` knows
/// where the source ends.
struct PrewarmedSource: Sendable {
    let head: ResidentSpan
    let tail: ResidentSpan?
    /// The total size out of the warming response's `Content-Range`, seeded into `fileSize` and
    /// `SourceContentLengthCache` on adoption so the later open neither probes for it nor waits on
    /// a response header to learn it. Not optional: a source whose size the warm did not resolve
    /// cannot be adopted without putting the open back on the network, so it is never stored.
    let contentLength: Int64

    var byteCount: Int { head.data.count + (tail?.data.count ?? 0) }
}

/// Process-wide, URL-keyed store of prewarmed source bytes (#551).
///
/// Shaped after `SourceContentLengthCache`, which memoizes the same kind of fact about the same
/// kind of key, and bounded the same way.
///
/// **Adoption takes the entry.** A session that has adopted the bytes holds them in its own reader
/// for as long as it needs them, so a copy left here would hold megabytes for an item that is now
/// playing, and the cap would be spent on sources nobody is going to open again. Taking is also
/// what keeps the store free of an expiry policy: an entry lives until it is used or displaced.
///
/// Thread-safe: a host warms off the main actor while a reader adopts on the demuxer's thread.
final class SourcePrewarmStore: @unchecked Sendable {

    static let shared = SourcePrewarmStore()

    /// Across all entries, not per entry. A host warming three items ahead on a series is the case
    /// this bounds; `prewarmByteBudget` bounds one call.
    static let defaultTotalByteCap = 64 * 1024 * 1024

    private let lock = NSLock()
    private let totalByteCap: Int
    private var entries: [String: PrewarmedSource] = [:]
    /// Recency, least recent first. Only `store` writes it: a take removes the entry outright, so
    /// there is no read recency to track.
    private var order: [String] = []
    private var _retainedBytes = 0

    init(totalByteCap: Int = SourcePrewarmStore.defaultTotalByteCap) {
        self.totalByteCap = totalByteCap
    }

    var retainedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _retainedBytes
    }

    /// Returns whether the entry was accepted. An entry larger than the whole cap is refused rather
    /// than made room for: evicting every other source for one that still does not fit would spend
    /// the store to hold nothing.
    @discardableResult
    func store(_ source: PrewarmedSource, for url: URL) -> Bool {
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        guard source.byteCount <= totalByteCap else { return false }
        removeLocked(key)
        while _retainedBytes + source.byteCount > totalByteCap, let oldest = order.first {
            removeLocked(oldest)
        }
        entries[key] = source
        order.append(key)
        _retainedBytes += source.byteCount
        return true
    }

    /// The adoption path. Returns the entry and removes it.
    func take(for url: URL) -> PrewarmedSource? {
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        guard let hit = entries[key] else { return nil }
        removeLocked(key)
        return hit
    }

    /// Whether a source is warm, without consuming it. For diagnostics and tests; the playback path
    /// uses `take`.
    func isWarm(for url: URL) -> Bool {
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        return entries[key] != nil
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        _retainedBytes = 0
    }

    private func removeLocked(_ key: String) {
        guard let existing = entries.removeValue(forKey: key) else { return }
        _retainedBytes -= existing.byteCount
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
    }
}
