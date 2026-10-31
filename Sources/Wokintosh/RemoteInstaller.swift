import Foundation
import WokintoshCore

enum RemoteInstaller {
    static func install(host: RemoteHost, collectorURL: URL,
                        progress: @escaping RemoteInstall.Progress) async throws -> RemoteInstallResult {
        try await Task.detached(priority: .utility) {
            try RemoteInstall.run(destination: host.destination, collectorPath: host.collectorPath,
                                  localCollectorPath: collectorURL.path, progress: progress)
        }.value
    }

    static func connect(host: RemoteHost) async throws -> Snapshot {
        guard let arguments = RemoteCommand.arguments(destination: host.destination, collectorPath: host.collectorPath) else {
            throw RunnerError.failed("Check the SSH destination and collector path.")
        }
        return try await Task.detached(priority: .utility) {
            try Snapshot.decode(CommandRunner.run("/usr/bin/ssh", arguments: arguments, timeout: 15))
        }.value
    }
}
