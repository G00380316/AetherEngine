import Foundation

/// #551: what a warm did, in the words a host can act on.
public struct SourcePrewarmReport: Sendable, Equatable {
    /// Bytes now held for this source. Zero means nothing was retained, and `declined` says why.
    public let retainedBytes: Int
    /// The source's total size, once the origin has stated it.
    public let contentLength: Int64?
    /// Why no bytes were retained, in one sentence, or nil when they were. A host can log it; the
    /// engine logs it either way.
    public let declined: String?

    public var isWarm: Bool { retainedBytes > 0 }
}

/// #551: fetches the bytes a cold open would have to fetch, for a source the engine is not playing.
///
/// Deliberately not a second `Demuxer`. It issues one ranged GET from byte zero, and a second one
/// for the trailing object only where the head says a cold open would go looking for it
/// (`SourcePrewarmPlan`). Everything else about a source is learned by the session that opens it.
///
/// It is a speculative path by construction, so it follows the rule the other speculative paths
/// follow: it takes an origin slot only if one is free right now, and it never queues for one
/// (#377). A prewarm that would have to wait for the playing session's uplink is a prewarm that has
/// stopped helping.
enum SourcePrewarmFetcher {

    /// The trailing object is asked for as an explicit range, not as `bytes=-n`. The head response
    /// has already stated the total by then, so the suffix form is not needed, and an explicit
    /// range is served by origins that decline suffixes (#281 measured a whole class of them).
    static let tailBytes = 64 * 1024

    static let defaultByteBudget = 8 * 1024 * 1024

    private static let session: URLSession = URLSession(
        configuration: AVIOReader.makeSessionConfig(),
        delegate: EngineTLS.sessionDelegate,
        delegateQueue: nil)

    static func warm(url: URL,
                     extraHeaders: [String: String],
                     byteBudget: Int,
                     into store: SourcePrewarmStore = .shared) async -> SourcePrewarmReport {
        let budget = max(0, byteBudget)
        guard budget > 0 else { return decline(url, "byte budget is zero") }
        // The same early-out the tail prefetch takes: on an origin metered down to one request at a
        // time, a speculative request is a slot the playing session needs.
        guard !OriginRequestBudget.shared.requiresSerialRequests(url) else {
            return decline(url, "this origin is down to one request at a time (#377)")
        }

        let head: RangeFetch.Result
        do {
            head = try await RangeFetch.run(url: url, extraHeaders: extraHeaders,
                                            range: "bytes=0-\(budget - 1)",
                                            label: "prewarm head", session: session)
        } catch let error as PrewarmDecline {
            return decline(url, error.reason)
        } catch {
            return decline(url, "cancelled")
        }
        guard head.range.start == 0 else {
            return decline(url, "the origin answered from \(head.range.start) instead of byte zero")
        }
        if Task.isCancelled { return decline(url, "cancelled") }

        var tail: ResidentSpan?
        if SourcePrewarmPlan.needsTrailingObject(head: head.body),
           head.total > Int64(head.body.count) + Int64(tailBytes) {
            let start = head.total - Int64(tailBytes)
            if let fetched = try? await RangeFetch.run(
                url: url, extraHeaders: extraHeaders,
                range: "bytes=\(start)-\(head.total - 1)",
                label: "prewarm tail", session: session),
               fetched.range.start == start {
                tail = ResidentSpan(start: start, data: fetched.body)
            } else {
                EngineLog.emit("[SourcePrewarm] trailing object not retained for \(url.lastPathComponent); "
                               + "the head alone is warm", category: .demux)
            }
        }
        if Task.isCancelled { return decline(url, "cancelled") }

        let warmed = PrewarmedSource(head: ResidentSpan(start: 0, data: head.body),
                                     tail: tail,
                                     contentLength: head.total)
        guard store.store(warmed, for: url) else {
            return decline(url, "\(warmed.byteCount) bytes exceed the prewarm store's cap")
        }
        EngineLog.emit(
            "[SourcePrewarm] warmed \(url.lastPathComponent): head=\(head.body.count)B "
            + "tail=\(tail?.data.count ?? 0)B of \(head.total)B (#551)",
            category: .demux)
        return SourcePrewarmReport(retainedBytes: warmed.byteCount,
                                   contentLength: head.total,
                                   declined: nil)
    }

    private static func decline(_ url: URL, _ reason: String) -> SourcePrewarmReport {
        EngineLog.emit("[SourcePrewarm] \(url.lastPathComponent) not warmed: \(reason) (#551)",
                       category: .demux)
        return SourcePrewarmReport(retainedBytes: 0, contentLength: nil, declined: reason)
    }
}

/// Why a warm stopped, carried out of the fetch so the report can name it.
struct PrewarmDecline: Error {
    let reason: String
}

/// One ranged GET that decides at the response header and buffers a bounded body.
///
/// The decision at the header is the load-bearing part, and #255 paid for it once already: a
/// completion handler only fires with the body in hand, so an origin that ignores `Range` and
/// answers 200 with a whole film would be downloaded in full before this code could look at the
/// status.
enum RangeFetch {

    struct Result {
        let body: Data
        let range: (start: Int64, end: Int64)
        let total: Int64
    }

    static func run(url: URL,
                    extraHeaders: [String: String],
                    range: String,
                    label: String,
                    session: URLSession) async throws -> Result {
        guard let ticket = OriginRequestBudget.shared.tryAcquire(for: url, label: label) else {
            throw PrewarmDecline(reason: "no origin request slot free (#377)")
        }
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let delegate = RangeFetchDelegate(extraHeaders: extraHeaders)
        let task = session.dataTask(with: request)
        task.delegate = delegate

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                delegate.onOutcome = { outcome in
                    OriginRequestBudget.shared.release(ticket)
                    switch outcome {
                    case .body(let result): continuation.resume(returning: result)
                    case .rejected(let reason): continuation.resume(throwing: PrewarmDecline(reason: reason))
                    }
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class RangeFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome {
        case body(RangeFetch.Result)
        case rejected(String)
    }

    private let extraHeaders: [String: String]
    private var buffer = Data()
    private var contentRange: (start: Int64, end: Int64, total: Int64)?
    private var rejection: String?

    /// Called exactly once, whatever happened. A caller is suspended on it, so a silent failure
    /// would be a continuation that never resumes.
    var onOutcome: ((Outcome) -> Void)?

    init(extraHeaders: [String: String]) {
        self.extraHeaders = extraHeaders
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let from = task.originalRequest?.url, let to = request.url {
            OriginRequestBudget.shared.noteRedirect(from: from, to: to)
        }
        // Credential headers do not follow a redirect to another host (#126 cross-origin replay).
        completionHandler(RedirectHeaderPolicy.redirectRequest(
            request,
            originalURL: task.originalRequest?.url,
            originalRange: task.originalRequest?.value(forHTTPHeaderField: "Range"),
            extraHeaders: extraHeaders))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            rejection = "no HTTP response"
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 206 else {
            rejection = http.statusCode == 200
                ? "status=200: this origin ignores Range and would have sent the whole source"
                : "status=\(http.statusCode)"
            if http.statusCode == 429 || http.statusCode == 503 || http.statusCode == 509 {
                OriginRequestBudget.shared.noteRefusal(for: http.url ?? dataTask.originalRequest?.url ?? URL(string: "http://invalid")!,
                                                       status: http.statusCode)
            }
            completionHandler(.cancel)
            return
        }
        guard let value = http.value(forHTTPHeaderField: "Content-Range"),
              let parsed = Self.parseContentRange(value) else {
            rejection = "Content-Range: \(http.value(forHTTPHeaderField: "Content-Range") ?? "absent")"
            completionHandler(.cancel)
            return
        }
        contentRange = parsed
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let expected = contentRange.map({ Int($0.end - $0.start + 1) }), buffer.count < expected else { return }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = self.outcome(error: error)
        onOutcome?(outcome)
        onOutcome = nil
    }

    private func outcome(error: Error?) -> Outcome {
        if let rejection { return .rejected(rejection) }
        if let error { return .rejected("transport: \(error.localizedDescription)") }
        guard let range = contentRange else { return .rejected("no usable response header") }
        let expected = Int(range.end - range.start + 1)
        // A short body would put later offsets at the wrong place in the span. This is an
        // optimisation, and a wrong optimisation is worse than none, so a partial delivery is
        // dropped rather than trimmed.
        guard buffer.count == expected else {
            return .rejected("short body: \(buffer.count)B of \(expected)B")
        }
        return .body(RangeFetch.Result(body: buffer,
                                       range: (start: range.start, end: range.end),
                                       total: range.total))
    }

    /// `bytes <start>-<end>/<total>`. A `*` total is a range the origin will not size, which is
    /// exactly the case a prewarm cannot adopt later, so it is rejected here rather than stored.
    static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
        let span = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard span.count == 2, let start = Int64(span[0]), let end = Int64(span[1]),
              start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }
}
