import Foundation

/// Tracking of LONG-RUNNING commands.
///
/// A command that hands back in a few milliseconds answers directly. Those that start an
/// offline render (a sound object bake, a plugin scan) cannot: they work through completion
/// blocks and can run for minutes. So they return a `{job_id}` immediately, and the caller
/// follows with `job.status` / `job.wait`.
///
/// A job "in progress" counts towards quiescence: `wait_idle` does not declare things calm
/// while a render is running.
@MainActor
final class JobRegistry {

    static let shared = JobRegistry()

    enum State: String, Sendable {
        case running, done, failed
    }

    struct Job {
        let id: String
        let command: String
        var state: State
        var result: JSONValue?
        var error: CommandError?
        let startedAt: Date
        var endedAt: Date?

        var jsonObject: JSONValue {
            var o: [String: JSONValue] = [
                "job_id": .string(id),
                "command": .string(command),
                "state": .string(state.rawValue),
                "started_at": .number(startedAt.timeIntervalSince1970),
            ]
            if let endedAt {
                o["ended_at"] = .number(endedAt.timeIntervalSince1970)
                o["duration_ms"] = .int(Int(endedAt.timeIntervalSince(startedAt) * 1000))
            }
            if let result { o["result"] = result }
            if let error { o["error"] = error.jsonObject }
            return .object(o)
        }
    }

    private var jobs: [String: Job] = [:]
    private var counter = 0

    /// Bounding the history: batch driving can chain thousands of jobs over a long session; we
    /// only keep the most recent ones once they are finished.
    private static let maxFinishedJobs = 200

    private init() {}

    // MARK: A job's lifecycle

    func begin(command: String) -> String {
        counter += 1
        let id = "job-\(counter)"
        jobs[id] = Job(id: id, command: command, state: .running,
                       result: nil, error: nil, startedAt: Date(), endedAt: nil)
        return id
    }

    func finish(_ id: String, result: JSONValue) {
        guard var job = jobs[id], job.state == .running else { return }
        job.state = .done
        job.result = result
        job.endedAt = Date()
        jobs[id] = job
        pruneFinished()
    }

    func fail(_ id: String, error: Error) {
        guard var job = jobs[id], job.state == .running else { return }
        job.state = .failed
        job.error = CommandError.wrap(error)
        job.endedAt = Date()
        jobs[id] = job
        pruneFinished()
    }

    // MARK: Reading

    func job(_ id: String) throws -> Job {
        guard let job = jobs[id] else {
            throw CommandError(code: .not_found, message: "unknown job: \(id)")
        }
        return job
    }

    func runningJobIDs() -> [String] {
        jobs.values.filter { $0.state == .running }.map(\.id).sorted()
    }

    func allJobs() -> [Job] {
        jobs.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Waits for a job to finish. Polling rather than a continuation: a job can end from an
    /// engine completion block that has no notion of the wait in progress, and several clients
    /// can wait on the same job.
    func wait(_ id: String, timeoutMs: Int) async throws -> Job {
        let started = ContinuousClock.now
        let budget = Duration.milliseconds(max(0, timeoutMs))
        while true {
            let current = try job(id)
            if current.state != .running { return current }
            guard ContinuousClock.now - started < budget else {
                throw CommandError(code: .timeout,
                                   message: "job \(id) still running after \(timeoutMs) ms",
                                   details: current.jsonObject)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pruneFinished() {
        let finished = jobs.values
            .filter { $0.state != .running }
            .sorted { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
        guard finished.count > Self.maxFinishedJobs else { return }
        for job in finished.prefix(finished.count - Self.maxFinishedJobs) {
            jobs.removeValue(forKey: job.id)
        }
    }
}
