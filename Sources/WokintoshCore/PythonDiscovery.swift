import Foundation

/// The same actual-version probe is used by local collection and remote installation.
/// The interpreter must also be suitable for the remote collector's pinned shebang.
enum PythonDiscovery {
    struct Probe: Decodable {
        let home: String
        let python: String
        let version: [Int]

        var isUsable: Bool {
            version.count >= 2 && (version[0] > 3 || (version[0] == 3 && version[1] >= 10)) &&
                Self.safeAbsolutePath(home) && Self.safeAbsolutePath(python) &&
                !python.contains(where: { $0.isWhitespace })
        }
        private static func safeAbsolutePath(_ value: String) -> Bool {
            value.hasPrefix("/") && value.utf8.count <= 4096 &&
                !value.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" })
        }
    }

    static func localPath(runner: (String) throws -> Data = {
        try CommandRunner.run("/bin/sh", arguments: ["-c", $0], timeout: 20, maxBytes: 64 * 1024)
    }) throws -> String {
        let probe = try JSONDecoder().decode(Probe.self, from: runner(probeCommand))
        guard probe.isUsable else {
            throw RunnerError.failed("Python 3.10 or later is required at an absolute path without spaces.")
        }
        return probe.python
    }

    static let probeCommand: String = {
        let script = "import json,os,sys; sys.exit(2) if sys.version_info < (3,10) or not sys.executable or not os.path.isabs(sys.executable) or len(sys.executable)>4096 or any(c.isspace() for c in sys.executable) else None; print(json.dumps({'home':os.path.expanduser('~'),'python':sys.executable,'version':list(sys.version_info[:3])}))"
        let shell = """
        search_directory() {
            case "$1" in /*) ;; *) return ;; esac
            for p in "$1"/python3 "$1"/python3.[0-9]*; do
                [ -f "$p" ] && [ -x "$p" ] || continue
                name=${p##*/}
                case "$name" in
                    python3) ;;
                    python3.*)
                        minor=${name#python3.}
                        case "$minor" in ''|*[!0-9]*) continue ;; esac
                        ;;
                    *) continue ;;
                esac
                if "$p" -c \(RemoteCommand.shellQuote(script)) 2>/dev/null; then exit 0; fi
            done
        }
        if python3 -c \(RemoteCommand.shellQuote(script)) 2>/dev/null; then exit 0; fi
        remaining=${PATH:-}
        while [ -n "$remaining" ]; do
            case "$remaining" in
                *:*) directory=${remaining%%:*}; remaining=${remaining#*:} ;;
                *) directory=$remaining; remaining= ;;
            esac
            search_directory "$directory"
        done
        for directory in /opt/homebrew/bin /usr/local/bin /usr/bin \\
                         /opt/homebrew/opt/python@3.*/bin /usr/local/opt/python@3.*/bin \\
                         /Library/Frameworks/Python.framework/Versions/3.*/bin; do
            search_directory "$directory"
        done
        printf '%s\\n' 'Wokintosh could not find Python 3.10 or later in PATH or common Python installation locations.' >&2
        exit 1
        """
        return "sh -c " + RemoteCommand.shellQuote(shell)
    }()

}

/// A successful interpreter is retained while executable. Failed discovery is retried
/// after a short delay so installing Python can recover without restarting the app.
public actor LocalPythonDiscovery {
    private let probe: @Sendable () throws -> String
    private let retryInterval: TimeInterval
    private var cachedPath: String?
    private var nextRetry: Date?
    private var pending: Task<String?, Never>?

    public init() {
        probe = { try PythonDiscovery.localPath() }
        retryInterval = 30
    }

    init(retryInterval: TimeInterval, probe: @escaping @Sendable () throws -> String) {
        self.retryInterval = retryInterval
        self.probe = probe
    }

    public func path() async -> String? {
        if let cachedPath {
            if FileManager.default.isExecutableFile(atPath: cachedPath) { return cachedPath }
            self.cachedPath = nil
        }
        if let pending { return await pending.value }
        if let nextRetry, Date() < nextRetry { return nil }
        let probe = self.probe
        let task = Task.detached(priority: .utility) { () -> String? in
            guard let path = try? probe(), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        }
        pending = task
        let path = await task.value
        cachedPath = path
        nextRetry = path == nil ? Date().addingTimeInterval(retryInterval) : nil
        pending = nil
        return path
    }
}
