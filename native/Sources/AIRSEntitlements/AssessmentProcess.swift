import Foundation
import Darwin

struct AssessmentProcessResult: Sendable {
    let status: Int32
    let exited: Bool
    let diagnostic: String
    let interruption: String?
}
/// Adapted from EngineInvocation: launch/cancel races share one lock and the
/// owned process is retained through exit. Two drains bound retained output.
final class AssessmentProcess: @unchecked Sendable {
    private let process=Process(), lock=NSLock(), group=DispatchGroup()
    private let output=Pipe(), errors=Pipe()
    private var buffers=[Data(),Data()], started=false, finished=false
    private var interruption:String?
    private var directExitAt:Date?
    private var continuation:CheckedContinuation<AssessmentProcessResult,Error>?
    private var timer:DispatchWorkItem?
    let timeout:TimeInterval
    init(executable:URL,arguments:[String],timeout:TimeInterval=30) {
        self.timeout=timeout; process.executableURL=executable; process.arguments=arguments
        process.standardInput=FileHandle.nullDevice; process.standardOutput=output; process.standardError=errors
        process.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C"]
    }
    func run() async throws -> AssessmentProcessResult {
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { start($0) }
        },onCancel:{self.cancel("Cancelled; owned helper is settling.")})
    }
    private func start(_ continuation:CheckedContinuation<AssessmentProcessResult,Error>) {
        lock.lock(); self.continuation=continuation
        if interruption != nil { finished=true; lock.unlock(); continuation.resume(throwing:CancellationError()); return }
        process.terminationHandler={ [self] process in
            lock.lock(); directExitAt=Date(); lock.unlock()
            group.wait()
            lock.lock(); finished=true; timer?.cancel()
            let result=AssessmentProcessResult(status:process.terminationStatus,exited:process.terminationReason == .exit,
                diagnostic:buffers.map{String(decoding:$0,as:UTF8.self)}.joined(separator:"\n"),interruption:interruption)
            let completion=self.continuation; self.continuation=nil; lock.unlock()
            completion?.resume(returning:result)
        }
        group.enter(); group.enter()
        do {
            try process.run(); started=true
            for (index,handle) in [output.fileHandleForReading,errors.fileHandleForReading].enumerated() {
                DispatchQueue.global(qos:.utility).async { [self] in
                    defer {try? handle.close(); group.leave()}
                    let fd=handle.fileDescriptor
                    let oldFlags=Darwin.fcntl(fd,F_GETFL)
                    guard oldFlags >= 0, Darwin.fcntl(fd,F_SETFL,oldFlags|O_NONBLOCK) == 0 else {
                        cancel("Cannot configure bounded diagnostic drain."); return
                    }
                    var bytes=[UInt8](repeating:0,count:4096)
                    while true {
                        lock.lock(); let exit=directExitAt; lock.unlock()
                        if let exit, Date().timeIntervalSince(exit) > 1 {
                            cancel("Diagnostic stream remained open after helper exit; drain deadline reached."); break
                        }
                        var descriptor=pollfd(fd:fd,events:Int16(POLLIN|POLLHUP),revents:0)
                        let ready=Darwin.poll(&descriptor,1,100)
                        if ready == 0 {continue}
                        if ready < 0 {if errno == EINTR {continue};cancel("Diagnostic poll failed.");break}
                        let count=Darwin.read(fd,&bytes,bytes.count)
                        if count == 0 {break}
                        if count < 0 {if errno == EINTR || errno == EAGAIN {continue};cancel("Diagnostic read failed.");break}
                        let data=Data(bytes.prefix(count))
                        lock.lock(); let available=max(0,32768-buffers[index].count)
                        buffers[index].append(data.prefix(available)); let exceeded=data.count>available; lock.unlock()
                        if exceeded {cancel("Output exceeded 64 KiB combined stream budgets; diagnostic truncated.")}
                    }
                }
            }
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            let work=DispatchWorkItem { [weak self] in self?.cancel("Assessment helper exceeded its time budget.") }
            timer=work; DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+timeout,execute:work)
            lock.unlock()
        } catch {
            group.leave(); group.leave()
            finished=true; self.continuation=nil; lock.unlock()
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            continuation.resume(throwing:error)
        }
    }
    func cancel(_ reason:String) {
        lock.lock(); if interruption == nil {interruption=reason}; let active=started && !finished; lock.unlock()
        guard active,process.isRunning else {return}
        let pid=process.processIdentifier; process.terminate()
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+2) { [self] in
            lock.lock(); let active=started && !finished; lock.unlock()
            if active,process.isRunning,process.processIdentifier == pid { _=Darwin.kill(pid,SIGKILL) }
        }
    }
}
