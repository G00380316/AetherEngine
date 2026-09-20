import Foundation
import AVFoundation

/// Off-main hop for batched synchronous AVFoundation property reads (#134). Getters backed by
/// figplayer (`accessLog`, `currentTime`, `loadedTimeRanges`, ...) are sync XPC round-trips to
/// mediaserverd; on the main actor a momentarily busy media server turns any of them into a
/// fully blocked main thread and, past the watchdog threshold, a process kill. Batch such reads
/// in `body` and run them here, off the main thread and off the shared cooperative pool.
///
/// Two carriers, because the caller's admission policy decides which one is honest.
///
/// `read(_:on:_:)` is for a caller whose SERIAL queue IS its admission policy (`offMainReadQueue`,
/// the sampler's `readQueue`, the memprobe's): one outstanding read by construction, and the queue
/// object is the thing that says so. `read(_:_:)` is for a caller that already counts its own
/// admission and would otherwise have to invent a queue to carry it.
///
/// The distinction is not cosmetic, the two carriers hit a wall at different widths. Measured on
/// macOS 27, 8 cores: with 64 work items blocked on the global pool, a private CONCURRENT queue and
/// `DispatchQueue.global()` had not started after 30 s, while a private serial queue started in
/// 0.2 ms, because a serial queue draws from the overcommit root and a concurrent one does not.
/// Push further, to ~512 blocked overcommit threads, and the serial queue stops starting too;
/// `Thread` started in 0.1 ms in every configuration. So a queue moves the wall, a thread removes
/// it, and a caller that blocks by design gets the thread.
///
/// `refs` crosses the isolation boundary unchecked; `body` must restrict itself to documented
/// thread-safe AVFoundation getters and must not touch actor-isolated state.
enum AVFoundationOffMain {
    private struct UncheckedRefs<Refs>: @unchecked Sendable {
        let refs: Refs
    }

    static func read<Refs, T: Sendable>(
        _ refs: Refs,
        on queue: DispatchQueue,
        _ body: @escaping @Sendable (Refs) -> T
    ) async -> T {
        let boxed = UncheckedRefs(refs: refs)
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body(boxed.refs))
            }
        }
    }

    /// The same hop on a thread of its own, for a caller that bounds its own concurrency. The
    /// thread lives exactly as long as the read, so the caller's bound is the bound on threads.
    static func read<Refs, T: Sendable>(
        _ refs: Refs,
        _ body: @escaping @Sendable (Refs) -> T
    ) async -> T {
        let boxed = UncheckedRefs(refs: refs)
        return await withCheckedContinuation { continuation in
            let worker = Thread {
                continuation.resume(returning: body(boxed.refs))
            }
            worker.name = "com.aetherengine.avfoundation.read"
            worker.qualityOfService = .utility
            worker.start()
        }
    }
}
