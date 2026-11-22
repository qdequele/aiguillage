import Foundation

/// Tiny logger: timestamped lines on stdout (line-buffered), debug lines only with --verbose.
enum Log {
    nonisolated(unsafe) static var verbose = false
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: @autoclosure () -> String) { emit("", message()) }
    static func warn(_ message: @autoclosure () -> String) { emit("WARN ", message()) }
    static func error(_ message: @autoclosure () -> String) { emit("ERROR ", message()) }
    static func debug(_ message: @autoclosure () -> String) {
        if verbose { emit("debug ", message()) }
    }

    private static func emit(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        print("\(formatter.string(from: Date())) \(level)\(message)")
        fflush(stdout)
    }
}

struct ShellError: Error, CustomStringConvertible {
    let command: String
    let status: Int32
    let output: String
    var description: String { "`\(command)` failed (exit \(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

/// Runs a command synchronously and returns its combined stdout+stderr.
@discardableResult
func run(_ path: String, _ args: [String], allowFailure: Bool = false) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(decoding: data, as: UTF8.self)
    let cmd = ([path] + args).joined(separator: " ")
    Log.debug("$ \(cmd) -> \(p.terminationStatus)")
    if p.terminationStatus != 0 && !allowFailure {
        throw ShellError(command: cmd, status: p.terminationStatus, output: out)
    }
    return out
}

/// Monotonic seconds, used for all timeouts and NAT/flow expiry.
func monotonicNow() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
}

func formatBytes(_ n: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(n)
    var i = 0
    while v >= 1024 && i < units.count - 1 {
        v /= 1024
        i += 1
    }
    return i == 0 ? "\(n)B" : String(format: "%.1f%@", v, units[i])
}

func formatRTT(_ rtt: Double?) -> String {
    rtt.map { "\(Int(($0 * 1000).rounded()))ms" } ?? "-"
}

struct UsageError: Error, CustomStringConvertible {
    let description: String
}
