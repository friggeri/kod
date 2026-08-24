import Darwin
import Foundation

struct BoundedProcessProbeResult {
    let exitStatus: Int32
    let output: Data
}

enum BoundedProcessProbe {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int = 64 * 1_024
    ) -> BoundedProcessProbeResult? {
        var descriptors: [Int32] = [0, 0]
        guard descriptors.withUnsafeMutableBufferPointer({
            Darwin.pipe($0.baseAddress!)
        }) == 0 else {
            return nil
        }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(
            &fileActions,
            writeDescriptor,
            STDOUT_FILENO
        )
        posix_spawn_file_actions_addopen(
            &fileActions,
            STDERR_FILENO,
            "/dev/null",
            O_WRONLY,
            0
        )
        posix_spawn_file_actions_addopen(
            &fileActions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0
        )
        posix_spawn_file_actions_addclose(
            &fileActions,
            readDescriptor
        )
        posix_spawn_file_actions_addclose(
            &fileActions,
            writeDescriptor
        )

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP)
        )
        posix_spawnattr_setpgroup(&attributes, 0)

        let values = [executableURL.path] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = values.map {
            strdup($0)
        }
        guard argv.allSatisfy({ $0 != nil }) else {
            argv.compactMap { $0 }.forEach { free($0) }
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            return nil
        }
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        argv.append(nil)

        var processIdentifier: pid_t = 0
        let spawnResult = executableURL.path.withCString { path in
            argv.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processIdentifier,
                    path,
                    &fileActions,
                    &attributes,
                    buffer.baseAddress!,
                    environ
                )
            }
        }
        Darwin.close(writeDescriptor)
        guard spawnResult == 0 else {
            Darwin.close(readDescriptor)
            return nil
        }
        defer { Darwin.close(readDescriptor) }

        let existingFlags = fcntl(readDescriptor, F_GETFL)
        if existingFlags >= 0 {
            _ = fcntl(
                readDescriptor,
                F_SETFL,
                existingFlags | O_NONBLOCK
            )
        }

        var output = Data()
        func drainOutput(maximumChunks: Int = 16) {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            for _ in 0..<maximumChunks {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(
                        readDescriptor,
                        $0.baseAddress,
                        $0.count
                    )
                }
                guard count > 0 else {
                    return
                }
                if output.count < outputLimit {
                    output.append(
                        contentsOf: buffer.prefix(
                            min(
                                count,
                                outputLimit - output.count
                            )
                        )
                    )
                }
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .milliseconds(
                Int64((timeout * 1_000).rounded(.up))
            )
        )
        var status: Int32 = 0
        func terminateProcessGroupAndReapLeader() {
            Darwin.kill(-processIdentifier, SIGTERM)
            usleep(50_000)
            Darwin.kill(-processIdentifier, SIGKILL)
            Darwin.kill(processIdentifier, SIGKILL)
            while waitpid(processIdentifier, &status, 0) == -1,
                  errno == EINTR {
                continue
            }
        }
        while clock.now < deadline {
            drainOutput()
            let waitResult = waitpid(
                processIdentifier,
                &status,
                WNOHANG
            )
            if waitResult == processIdentifier {
                drainOutput()
                Darwin.kill(-processIdentifier, SIGKILL)
                let exitedNormally = status & 0x7f == 0
                return BoundedProcessProbeResult(
                    exitStatus: exitedNormally
                        ? (status >> 8) & 0xff
                        : -1,
                    output: output
                )
            }
            if waitResult == -1 {
                if errno == EINTR {
                    continue
                }
                terminateProcessGroupAndReapLeader()
                return nil
            }
            usleep(10_000)
        }

        terminateProcessGroupAndReapLeader()
        return nil
    }
}
