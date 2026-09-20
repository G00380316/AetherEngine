import Foundation
import AVFoundation

/// Off-main hop for batched synchronous AVFoundation property reads (#134). Getters backed by
/// figplayer (`accessLog`, `currentTime`, `loadedTimeRanges`, ...) are sync XPC round-trips to
/// mediaserverd; on the main actor a momentarily busy media server turns any of them into a
/// fully blocked main thread and, past the watchdog threshold, a process kill. Batch such reads
/// in `body` and run them here on a caller-owned queue: a stalled reply then parks a GCD thread,
/// not the main thread or the shared cooperative pool.
///
/// The queue IS the caller's admission policy, so it is passed in rather than owned here. Most
/// callers pass a serial queue (`offMainReadQueue`, the sampler's `readQueue`, the memprobe's) and
/// get one outstanding read by construction. `ItemDiagnosticReadPool` is the exception: it passes a
/// concurrent queue and counts the lanes itself, so a getter stranded on an outgoing item still
/// leaves a lane for the incoming one. Either way the bound on parked threads is the caller's,
/// never GCD's.
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
}
