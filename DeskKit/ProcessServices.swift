import Foundation
import Darwin
import JavaScriptCore

enum ChildProcessEnvironment {
    static var values: [String: String] {
        // Retain location/locale settings, but do not hand inherited tokens and passwords to plugins.
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "CODEX_HOME"]
        var result = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in
            inherited[key].map { (key, $0) }
        })
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        result["NO_COLOR"] = "1"
        return result
    }
}

struct ProcessOutput {
    var data: Data
    var errors: String
    var status: Int32
}

// Pipe() cannot report descriptor exhaustion through a throwing initializer.
// Allocate explicitly so exhausted resources become an ordinary component error.
private struct CheckedProcessPipe {
    let reading: FileHandle
    let writing: FileHandle

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { throw Self.systemError() }
        do {
            for descriptor in descriptors {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else { throw Self.systemError() }
            }
            // A child that closes stdin must produce EPIPE, not terminate DeskKit.
            guard fcntl(descriptors[1], F_SETNOSIGPIPE, 1) != -1 else { throw Self.systemError() }
        } catch {
            Darwin.close(descriptors[0]); Darwin.close(descriptors[1])
            throw error
        }
        reading = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        writing = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    }

    static func systemError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
    }

    static func makeNonblocking(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags != -1, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw systemError()
        }
    }
}

// Reading and teardown run on the owner's serial queue. Close only after GCD has
// released the source, so a recycled descriptor cannot be read by an old callback.
private final class ProcessPipeReader {
    private var source: DispatchSourceRead?
    private let receive: (Result<Data, Error>) -> Void

    init(handle: FileHandle, queue: DispatchQueue, cleanup: DispatchGroup, receive: @escaping (Result<Data, Error>) -> Void) throws {
        try CheckedProcessPipe.makeNonblocking(handle)
        self.receive = receive
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in self?.drain() }
        cleanup.enter()
        source.setCancelHandler { try? handle.close(); cleanup.leave() }
        source.resume()
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Yield regularly even when stderr is continuously producing output.
        for _ in 0..<16 {
            guard let source else { return }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(Int32(source.handle), $0.baseAddress!, $0.count) }
            if count > 0 {
                receive(.success(Data(bytes.prefix(count))))
            } else if count == 0 {
                cancel(); receive(.success(Data())); return
            } else {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { return }
                cancel(); receive(.failure(CheckedProcessPipe.systemError(code))); return
            }
        }
    }

    deinit { source?.cancel() }
}

final class CommandJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DeskKit.Command")
    private let process = Process()
    private let ioCleanup = DispatchGroup()
    private var output: ProcessPipeReader?, errors: ProcessPipeReader?
    private var input: DispatchSourceWrite?
    private var inputSuspended = false
    private var request = Data(), requestOffset = 0
    private var stdout = Data(), stderr = Data()
    private var continuation: CheckedContinuation<ProcessOutput, Error>?
    private var completed = false
    private var timeout: DispatchWorkItem?
    private var stopOnResponseID: Int?
    private var outputEnded = false, errorsEnded = false
    private var exitStatus: Int32?

    static func run(executable: URL, arguments: [String], directory: URL? = nil, input: Data? = nil,
                    timeout: Double = 15, responseID: Int? = nil) async throws -> ProcessOutput {
        let job = CommandJob()
        // Callbacks are weak. The awaiting call owns the job until it completes.
        defer { withExtendedLifetime(job) {} }
        return try await withCheckedThrowingContinuation { continuation in
            job.queue.async {
                job.continuation = continuation
                job.start(executable, arguments, directory, input, timeout, responseID)
            }
        }
    }
    private func start(_ executable: URL, _ arguments: [String], _ directory: URL?, _ request: Data?, _ seconds: Double, _ responseID: Int?) {
        stopOnResponseID = responseID
        self.request = request ?? Data()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = ChildProcessEnvironment.values
        do {
            let stdoutPipe = try CheckedProcessPipe(), stderrPipe = try CheckedProcessPipe(), stdinPipe = try CheckedProcessPipe()
            // Process receives FileHandles, so we explicitly close the parent's
            // copies of the child's ends on both launch success and launch failure.
            defer {
                try? stdoutPipe.writing.close(); try? stderrPipe.writing.close(); try? stdinPipe.reading.close()
            }
            process.standardOutput = stdoutPipe.writing; process.standardError = stderrPipe.writing
            process.standardInput = stdinPipe.reading
            output = try ProcessPipeReader(handle: stdoutPipe.reading, queue: queue, cleanup: ioCleanup) { [weak self] result in
                switch result {
                case .success(let data): self?.readOutput(data)
                case .failure(let error): self?.finish(.failure(error))
                }
            }
            errors = try ProcessPipeReader(handle: stderrPipe.reading, queue: queue, cleanup: ioCleanup) { [weak self] result in
                switch result {
                case .success(let data): self?.readError(data)
                case .failure(let error): self?.finish(.failure(error))
                }
            }
            try CheckedProcessPipe.makeNonblocking(stdinPipe.writing)
            let writer = DispatchSource.makeWriteSource(fileDescriptor: stdinPipe.writing.fileDescriptor, queue: queue)
            let inputHandle = stdinPipe.writing
            let cleanup = ioCleanup
            cleanup.enter()
            writer.setCancelHandler { try? inputHandle.close(); cleanup.leave() }
            writer.setEventHandler { [weak self] in self?.writeInput() }
            input = writer; writer.resume()
            process.terminationHandler = { [weak self] process in
                self?.queue.async { [weak self] in
                    self?.exitStatus = process.terminationStatus; self?.completeIfExited()
                }
            }
            // Do not create job -> timeout -> job. cancel() alone doesn't sever ownership.
            let deadline = DispatchWorkItem { [weak self] in
                self?.finish(.failure(DeskKitError.message("数据源请求超时（\(Int(seconds)) 秒）。")))
            }
            timeout = deadline; queue.asyncAfter(deadline: .now() + seconds, execute: deadline)
            try process.run()
        } catch { finish(.failure(error)) }
    }
    private func writeInput() {
        guard !completed, let input else { return }
        // A child that stops reading must not block this queue and its timeout.
        while requestOffset < request.count {
            let offset = requestOffset
            let written = request.withUnsafeBytes {
                Darwin.write(Int32(input.handle), $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if written > 0 { requestOffset += written; continue }
            let code = written == 0 ? EIO : errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK { return }
            finish(.failure(CheckedProcessPipe.systemError(code))); return
        }
        request = Data(); requestOffset = 0
        if stopOnResponseID == nil {
            closeInput()
        } else {
            // RPC servers need stdin to remain open until their reply arrives.
            // Suspend the writable event to avoid spinning on an empty request.
            input.suspend(); inputSuspended = true
        }
    }
    private func closeInput() {
        guard let input else { return }
        self.input = nil
        input.cancel()
        if inputSuspended { input.resume(); inputSuspended = false }
    }
    private func readOutput(_ data: Data) {
        guard !completed else { return }
        guard !data.isEmpty else { outputEnded = true; output = nil; completeIfExited(); return }
        stdout.append(data)
        if stdout.count > 1_048_576 { finish(.failure(DeskKitError.message("数据源输出超过 1 MB。"))); return }
        if let target = stopOnResponseID {
            for line in stdout.split(separator: 10) {
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["id"] as? Int == target {
                    finish(.success(ProcessOutput(data: Data(line), errors: "", status: 0))); return
                }
            }
        }
    }
    private func readError(_ data: Data) {
        guard !completed else { return }
        if data.isEmpty { errorsEnded = true; errors = nil; completeIfExited(); return }
        if stderr.count < 4096 { stderr.append(data.prefix(4096 - stderr.count)) }
    }
    private func completeIfExited() {
        guard !completed, outputEnded, errorsEnded, let status = exitStatus else { return }
        finish(.success(ProcessOutput(data: stdout, errors: String(data: stderr, encoding: .utf8) ?? "", status: status)))
    }
    private func finish(_ result: Result<ProcessOutput, Error>) {
        guard !completed else { return }; completed = true
        timeout?.cancel(); timeout = nil; process.terminationHandler = nil
        output?.cancel(); output = nil
        errors?.cancel(); errors = nil
        closeInput(); request = Data()
        if process.isRunning { process.terminate(); let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in if process.isRunning { kill(pid, SIGKILL) } }
        }
        let callback = continuation; continuation = nil
        // The cancel handlers above close the parent pipe ends before the caller
        // is resumed. All teardown paths (reply, EOF, timeout, failure) converge here.
        ioCleanup.notify(queue: queue) { callback?.resume(with: result) }
    }
}

// The app keeps one lightweight worker alive. A bad render script cannot block the UI:
// the parent terminates this process if a render exceeds its deadline.
final class ScriptEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DeskKit.ScriptEngine")
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<PluginPresentation, Error>] = [:]
    private var deadlines: [String: DispatchWorkItem] = [:]

    func render(script: String, data: [String: Any]) async throws -> PluginPresentation {
        let id = UUID().uuidString
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "script": script, "data": data,
                                                                 "context": ["now": Date().timeIntervalSince1970 * 1000, "locale": "zh-CN"]]) + Data([10])
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try ensureStarted()
                    pending[id] = continuation
                    let deadline = DispatchWorkItem { [self] in
                        if pending[id] != nil { stop(error: DeskKitError.message("布局脚本运行超过 3 秒，已停止。")) }
                    }
                    deadlines[id] = deadline; queue.asyncAfter(deadline: .now() + 3, execute: deadline)
                    try input?.fileHandleForWriting.write(contentsOf: payload)
                } catch {
                    if pending[id] != nil { stop(error: error) } else { continuation.resume(throwing: error) }
                }
            }
        }
    }
    func shutdown() { queue.async { self.stop(error: DeskKitError.message("脚本服务已停止。")) } }
    private func ensureStarted() throws {
        if process?.isRunning == true { return }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--script-worker"]
        child.environment = ChildProcessEnvironment.values
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self, weak child] _ in self?.queue.async {
            guard let self, self.process === child else { return }
            self.stop(error: DeskKitError.message("布局脚本服务意外退出。"))
        } }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.read(data) }
        }
        process = child; input = stdin; output = stdout; buffer = Data()
        try child.run()
    }
    private func read(_ chunk: Data) {
        guard let output else { return }
        if chunk.isEmpty { output.fileHandleForReading.readabilityHandler = nil; return }
        buffer.append(chunk)
        if buffer.count > 1_048_576 { stop(error: DeskKitError.message("脚本返回的数据过大。")); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            do {
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = object["id"] as? String, let callback = pending.removeValue(forKey: id) else { continue }
                deadlines.removeValue(forKey: id)?.cancel()
                if let error = object["error"] as? String { callback.resume(throwing: DeskKitError.message(error)); continue }
                do {
                    let data = try JSONSerialization.data(withJSONObject: object["result"] ?? [:])
                    let presentation = try JSONDecoder().decode(PluginPresentation.self, from: data)
                    try presentation.validate(); callback.resume(returning: presentation)
                } catch { callback.resume(throwing: error) }
            } catch { stop(error: DeskKitError.message("脚本返回了无效的 JSON。")); return }
        }
    }
    private func stop(error: Error) {
        let old = process; process = nil
        output?.fileHandleForReading.readabilityHandler = nil; input = nil; output = nil; buffer = Data()
        if old?.isRunning == true { kill(old!.processIdentifier, SIGKILL) }
        for item in deadlines.values { item.cancel() }; deadlines.removeAll()
        let callbacks = pending.values; pending.removeAll()
        for callback in callbacks { callback.resume(throwing: error) }
    }
}

enum ScriptWorker {
    static func main() {
        while let line = readLine() {
            autoreleasepool {
                var id = ""
                var response: [String: Any]
                do {
                    guard let data = line.data(using: .utf8), data.count <= 1_048_576,
                          let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let requestID = request["id"] as? String, let script = request["script"] as? String,
                          let context = JSContext() else { throw DeskKitError.message("无效的脚本请求。") }
                    id = requestID
                    context.evaluateScript(script)
                    if let exception = context.exception { throw DeskKitError.message(exception.toString() ?? "JavaScript 语法错误") }
                    guard let render = context.objectForKeyedSubscript("render"), !render.isUndefined else {
                        throw DeskKitError.message("脚本需要定义 function render(data, context)。")
                    }
                    let result = render.call(withArguments: [request["data"] ?? [:], request["context"] ?? [:]])
                    if let exception = context.exception { throw DeskKitError.message(exception.toString() ?? "JavaScript 错误") }
                    guard let object = result?.toObject(), JSONSerialization.isValidJSONObject(object) else {
                        throw DeskKitError.message("render 必须返回可序列化的布局对象。")
                    }
                    response = ["id": id, "result": object]
                } catch { response = ["id": id, "error": error.localizedDescription] }
                if let data = try? JSONSerialization.data(withJSONObject: response) {
                    try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
                }
            }
        }
    }
}
