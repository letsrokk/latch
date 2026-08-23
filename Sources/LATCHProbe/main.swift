import Darwin
import Foundation
import LATCHNative
import LATCHShared

func emit(_ result: ProbeResult, exitCode: Int32) -> Never {
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(result) {
        FileHandle.standardOutput.write(data)
    }
    exit(exitCode)
}

guard CommandLine.arguments.count == 2 else {
    emit(ProbeResult(metadataErrno: EINVAL, failedOperation: .metadata), exitCode: 64)
}

let mountPoint = CommandLine.arguments[1]
var metadata = stat()
guard latch_stat_path(mountPoint, &metadata) == 0 else {
    emit(ProbeResult(metadataErrno: errno, failedOperation: .metadata), exitCode: 1)
}
guard let directory = opendir(mountPoint) else {
    emit(ProbeResult(directoryErrno: errno, failedOperation: .directoryOpen), exitCode: 1)
}
defer { closedir(directory) }

errno = 0
_ = readdir(directory)
guard errno == 0 else {
    emit(ProbeResult(directoryErrno: errno, failedOperation: .directoryRead), exitCode: 1)
}
emit(ProbeResult(), exitCode: 0)
