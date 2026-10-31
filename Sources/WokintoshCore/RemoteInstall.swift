import Foundation

public struct RemoteInstallCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public let timeout: TimeInterval
    public let maxBytes: Int
}

public struct RemoteInstallResult: Sendable {
    public let snapshot: Snapshot
    public let collectorPath: String
    public let pythonVersion: String
    public let backupPath: String?
    public let cleanupWarning: String?
}

public enum RemoteInstall {
    public typealias Runner = @Sendable (RemoteInstallCommand) throws -> Data
    public typealias Progress = @Sendable (String) -> Void

    /// Runs off the main actor. The injected runner keeps tests entirely local.
    public static func run(destination: String, collectorPath: String, localCollectorPath: String,
                           runner: Runner = { try CommandRunner.run($0.executable, arguments: $0.arguments, timeout: $0.timeout, maxBytes: $0.maxBytes) },
                           progress: Progress = { _ in }) throws -> RemoteInstallResult {
        guard RemoteCommand.isValidDestination(destination), RemoteCommand.isValidCollectorPath(collectorPath),
              localCollectorPath.hasPrefix("/"), !localCollectorPath.contains("\0") else {
            throw RunnerError.failed("Use an SSH alias or user@host and an absolute or ~/ collector file path, without shell commands or .. components.")
        }
        func ssh(_ command: String, maxBytes: Int = 64 * 1024, timeout: TimeInterval = 20) throws -> Data {
            try runner(RemoteInstallCommand(executable: "/usr/bin/ssh", arguments: RemoteCommand.sshArguments(destination: destination, command: command), timeout: timeout, maxBytes: maxBytes))
        }
        progress("Checking SSH and Python 3.10 or later…")
        let probe = try JSONDecoder().decode(PythonProbe.self, from: ssh(probeCommand))
        guard probe.version.count >= 2, probe.version[0] > 3 || (probe.version[0] == 3 && probe.version[1] >= 10),
              safeAbsolutePath(probe.home), safeAbsolutePath(probe.python),
              !probe.python.contains(where: { $0.isWhitespace }) else {
            throw RunnerError.failed("The remote machine needs Python 3.10 or later at an absolute path without spaces, and a valid home directory.")
        }
        let home = probe.home == "/" ? "" : probe.home.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = collectorPath.hasPrefix("~/") ? (home.isEmpty ? "/" : "/" + home + "/") + collectorPath.dropFirst(2) : collectorPath
        let identifier = UUID().uuidString.lowercased()
        let parent = String(path.prefix(upTo: path.lastIndex(of: "/")!))
        let staging = (parent.isEmpty ? "/" : parent + "/") + ".wokintosh-install-" + identifier
        let stagedCollector = staging + "/collector"
        let backup = path + ".wokintosh-backup-" + identifier
        func python(_ script: String, _ arguments: [String] = []) -> String {
            ([probe.python, "-c", script] + arguments).map(RemoteCommand.shellQuote).joined(separator: " ")
        }
        var prepared = false
        var promotionStarted = false
        do {
            progress("Preparing a private upload folder…")
            // Mark before execution: a dropped SSH connection may have created the folder.
            prepared = true
            _ = try ssh(python(prepareScript, [path, staging]))
            progress("Copying the bundled collector over SCP…")
            let remoteFile = RemoteCommand.scpDestination(destination) + ":" + RemoteCommand.shellQuote(stagedCollector)
            _ = try runner(RemoteInstallCommand(executable: "/usr/bin/scp", arguments: [
                "-B", "-O", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oConnectTimeout=7",
                "-oServerAliveInterval=3", "-oServerAliveCountMax=2", "--", localCollectorPath, remoteFile
            ], timeout: 45, maxBytes: 64 * 1024))
            progress("Checking the uploaded collector’s snapshot…")
            _ = try Snapshot.decode(ssh(python(verifyScript, [stagedCollector, probe.python]), maxBytes: 16 * 1024 * 1024, timeout: 30))
            progress("Saving the previous collector and installing the update…")
            promotionStarted = true
            let commit = try JSONDecoder().decode(CommitResult.self, from: ssh(python(promoteScript, [path, staging, backup])))
            guard commit.backupPath == nil || commit.backupPath == backup else { throw RunnerError.failed("The remote installer returned an unexpected backup path.") }
            progress("Verifying the installed collector…")
            let snapshot = try Snapshot.decode(ssh(python(verifyInstalledScript, [path, staging]), maxBytes: 16 * 1024 * 1024, timeout: 30))
            let cleanupWarning: String?
            do { _ = try ssh(python(cleanupScript, [staging])); cleanupWarning = nil }
            catch { cleanupWarning = "The collector is installed, but the temporary folder could not be removed: \(staging)" }
            return RemoteInstallResult(snapshot: snapshot, collectorPath: path,
                                       pythonVersion: probe.version.map(String.init).joined(separator: "."),
                                       backupPath: commit.backupPath, cleanupWarning: cleanupWarning)
        } catch {
            let original = error.localizedDescription
            if promotionStarted {
                progress("Restoring the previous collector…")
                do { _ = try ssh(python(rollbackScript, [path, staging, backup])) }
                catch {
                    throw RunnerError.failed("\(original)\n\nAutomatic rollback could not be confirmed. Check \(path) on \(destination). If there was a previous collector, its backup is \(backup). Recovery details remain in \(staging).\n\n\(error.localizedDescription)")
                }
            }
            if prepared { _ = try? ssh(python(cleanupScript, [staging])) }
            throw RunnerError.failed(original)
        }
    }

    private struct PythonProbe: Decodable { let home: String; let python: String; let version: [Int] }
    private struct CommitResult: Decodable { let backupPath: String? }
    private static func safeAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" })
    }

    private static let probeCommand: String = {
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
        printf '%s\\n' 'Wokintosh could not find Python 3.10 or later in the SSH PATH or common Python installation locations.' >&2
        exit 1
        """
        return "sh -c " + RemoteCommand.shellQuote(shell)
    }()

    // The lock is precreated inside the private stage. Never recreate it: a late
    // process holding an unlinked lock must fail its stage/inode check after cleanup.
    private static let lockScript = """
    import fcntl,os,stat,sys
    def stage_lock(stage,allow_cancelled=False):
        lockpath=os.path.join(stage,'lock')
        descriptor=os.open(lockpath,os.O_RDWR|os.O_NOFOLLOW)
        lock=os.fdopen(descriptor,'r+b')
        try:
            fcntl.flock(lock,fcntl.LOCK_EX)
            held=os.fstat(lock.fileno())
            current=os.lstat(lockpath)
            if not os.path.isdir(stage) or os.path.islink(stage) or not stat.S_ISREG(current.st_mode) or (held.st_dev,held.st_ino)!=(current.st_dev,current.st_ino):
                raise SystemExit('The remote installation folder changed; refusing to continue.')
            if not allow_cancelled and os.path.exists(os.path.join(stage,'cancelled')):
                raise SystemExit('This remote installation was cancelled; refusing to continue.')
            return lock
        except BaseException:
            lock.close()
            raise
    """

    // Only explicit collector operations occur here; provider hooks and state directories are untouched.
    private static let prepareScript = lockScript + "\n" + """
    target,stage=sys.argv[1:]
    os.makedirs(os.path.dirname(target),mode=0o755,exist_ok=True)
    os.mkdir(stage,mode=0o700)
    descriptor=os.open(os.path.join(stage,'lock'),os.O_CREAT|os.O_EXCL|os.O_RDWR,0o600)
    os.close(descriptor)
    with stage_lock(stage):
        if os.path.lexists(target) and not stat.S_ISREG(os.lstat(target).st_mode):
            raise SystemExit('The collector destination must be a regular file, not a directory or symbolic link.')
    """
    private static let verifyScript = lockScript + "\n" + """
    import subprocess
    path,python=sys.argv[1:]
    stage=os.path.dirname(path)
    with stage_lock(stage):
        with open(path,'rb') as f: content=f.read()
        if not content.startswith(b'#!'):
            raise SystemExit('The uploaded collector is missing its interpreter line.')
        content=('#!'+python+'\\n').encode()+content.split(b'\\n',1)[1]
        with open(path,'wb') as f: f.write(content)
        os.chmod(path,0o700)
        subprocess.run([path,'snapshot','--json'],check=True)
    """
    private static let verifyInstalledScript = lockScript + "\n" + """
    import subprocess
    target,stage=sys.argv[1:]
    with stage_lock(stage):
        subprocess.run([target,'snapshot','--json'],check=True)
    """
    private static let promoteScript = lockScript + "\n" + """
    import hashlib,json,shutil
    target,stage,backup=sys.argv[1:]
    with stage_lock(stage):
        candidate=os.path.join(stage,'collector')
        with open(candidate,'rb') as f: digest=hashlib.sha256(f.read()).hexdigest()
        existed=os.path.lexists(target)
        original_digest=None
        if existed:
            if not stat.S_ISREG(os.lstat(target).st_mode):
                raise SystemExit('The collector destination changed; refusing to overwrite it.')
            with open(target,'rb') as source,open(backup,'xb') as dest: shutil.copyfileobj(source,dest)
            os.chmod(backup,0o700)
            with open(backup,'rb') as f: original_digest=hashlib.sha256(f.read()).hexdigest()
        with open(os.path.join(stage,'state'),'x') as f: json.dump({'existed':existed,'digest':digest,'originalDigest':original_digest},f)
        os.replace(candidate,target)
        print(json.dumps({'backupPath':backup if existed else None}))
    """
    private static let rollbackScript = lockScript + "\n" + """
    import hashlib,json
    target,stage,backup=sys.argv[1:]
    with stage_lock(stage,allow_cancelled=True):
        open(os.path.join(stage,'cancelled'),'a').close()
        statepath=os.path.join(stage,'state')
        rolledback=os.path.join(stage,'rolledback')
        if os.path.exists(rolledback): sys.exit(0)
        if not os.path.exists(statepath) or os.path.exists(os.path.join(stage,'collector')):
            open(rolledback,'a').close()
            sys.exit(0)
        with open(statepath) as f: state=json.load(f)
        if not state['existed'] and not os.path.lexists(target):
            open(rolledback,'a').close()
            sys.exit(0)
        if not os.path.isfile(target) or os.path.islink(target):
            raise SystemExit('Collector destination changed during installation; recovery files were retained.')
        with open(target,'rb') as f: digest=hashlib.sha256(f.read()).hexdigest()
        if state['existed'] and digest == state['originalDigest'] and not os.path.lexists(backup):
            open(rolledback,'a').close()
            sys.exit(0)
        if digest != state['digest']:
            raise SystemExit('Collector changed during installation; recovery files were retained.')
        if state['existed']: os.replace(backup,target)
        else: os.unlink(target)
        open(rolledback,'a').close()
    """
    private static let cleanupScript = lockScript + "\n" + """
    import shutil
    stage=sys.argv[1]
    if not os.path.lexists(stage): sys.exit(0)
    with stage_lock(stage,allow_cancelled=True):
        open(os.path.join(stage,'cancelled'),'a').close()
        shutil.rmtree(stage)
    """
}
