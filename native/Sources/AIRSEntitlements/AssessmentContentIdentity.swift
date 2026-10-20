import Foundation
import Darwin
import CryptoKit
import AIRSCore

/// Bounded physical subtree identity. Adapted from AIRS/MacScope descriptor traversal
/// and donor incremental SHA256. Links and special files are explicitly unsupported.
/// A digest is computed once; admission checks reuse it via observed inode/time identities.
public struct AssessmentContentIdentity: Sendable {
    public let url: URL
    public let digest: String
    private let witnesses: [Witness]
    private struct Witness: Sendable, Equatable {
        let path: Data
        let values: [Int64]
        init(_ path:String,_ s:stat) {
            self.path=Data(path.utf8)
            values=[Int64(s.st_dev),Int64(bitPattern:s.st_ino),Int64(s.st_mode),Int64(s.st_uid),Int64(s.st_gid),s.st_size,
                Int64(s.st_mtimespec.tv_sec),Int64(s.st_mtimespec.tv_nsec),Int64(s.st_ctimespec.tv_sec),Int64(s.st_ctimespec.tv_nsec),Int64(s.st_flags)]
        }
    }
    public static func capture(_ url:URL,maximumBytes:Int=268_435_456) throws -> Self {
        guard maximumBytes > 0 && maximumBytes <= 268_435_456 else { throw InspectionArchiveError.limit }
        let canonical=url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL, canonical.path.utf8.elementsEqual(url.standardizedFileURL.path.utf8) else { throw failure("Choose a physical local path without symbolic links.") }
        let result=try scan(canonical,hash:true,maximumBytes:maximumBytes)
        return .init(url:canonical,digest:result.1,witnesses:result.0)
    }
    public func validate() throws {
        guard try Self.scan(url,hash:false,maximumBytes:268_435_456).0 == witnesses else {
            throw Self.failure("Content changed since capture; rebuild the assessment review.")
        }
    }
    private static func failure(_ message:String) -> Error { ReportError.invalidContents(message) }
    private static func scan(_ url:URL,hash:Bool,maximumBytes:Int) throws -> ([Witness],String) {
        let root=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard root >= 0 else { throw failure("Cannot open assessment subject.") }; defer { Darwin.close(root) }
        var witnesses:[Witness]=[], hasher=SHA256(), consumed=0, entries=0
        let deadline=Date().addingTimeInterval(30)
        func checkpoint() throws { try Task.checkCancellation(); guard Date() < deadline else { throw failure("Content identity exceeded 30 seconds.") } }
        func metadata(_ fd:Int32) throws -> stat { var s=stat(); guard Darwin.fstat(fd,&s)==0 else {throw failure("Cannot inspect subject identity.")}; return s }
        func add(_ data:Data) throws { guard data.count <= maximumBytes-consumed else {throw InspectionArchiveError.limit}; consumed += data.count; hasher.update(data:data) }
        func walk(_ fd:Int32,_ path:String,_ depth:Int) throws {
            try checkpoint(); entries += 1
            guard entries <= 4096, depth <= 32, path.utf8.count <= 4096 else {throw InspectionArchiveError.limit}
            let before=try metadata(fd), witness=Witness(path,before), type=before.st_mode&S_IFMT
            guard type == S_IFREG || type == S_IFDIR else {throw failure("Links and special files are outside the assessment identity scope.")}
            witnesses.append(witness)
            if hash {
                try add(JSONEncoder().encode([path,String(before.st_mode),String(before.st_uid),String(before.st_gid),String(before.st_flags)]))
                let count=Darwin.flistxattr(fd,nil,0,0)
                guard count >= 0, count <= 65536 else { throw failure("Extended attribute names unavailable or over budget.") }
                var names=[CChar](repeating:0,count:max(1,count))
                guard Darwin.flistxattr(fd,&names,count,0)==count else {throw failure("Extended attributes changed.")}
                let bytes=names.prefix(count).map{UInt8(bitPattern:$0)}
                for nameBytes in bytes.split(separator:0).sorted(by:{$0.lexicographicallyPrecedes($1)}) {
                    guard let name=String(bytes:nameBytes,encoding:.utf8) else {throw failure("Non-UTF8 attribute name.")}
                    let size=Darwin.fgetxattr(fd,name,nil,0,0,0)
                    guard size >= 0, size <= 1_048_576 else {throw failure("Extended attribute unavailable or over 1 MiB.")}
                    var value=Data(count:size)
                    let read=value.withUnsafeMutableBytes { Darwin.fgetxattr(fd,name,$0.baseAddress,size,0,0) }
                    guard read == size else {throw failure("Extended attribute changed.")}
                    try add(JSONEncoder().encode(name)); try add(JSONEncoder().encode(value))
                }
            }
            if type == S_IFREG {
                guard before.st_size >= 0, before.st_size <= maximumBytes else {throw InspectionArchiveError.limit}
                if hash {
                    var fileHash=SHA256(), count=0, buffer=[UInt8](repeating:0,count:65536)
                    while true {
                        try checkpoint(); let n=Darwin.read(fd,&buffer,buffer.count)
                        guard n >= 0 else {throw failure("Cannot read subject bytes.")}; if n == 0 {break}
                        guard n <= maximumBytes-consumed else {throw InspectionArchiveError.limit}
                        consumed += n; count += n; fileHash.update(data:Data(buffer.prefix(n)))
                    }
                    guard count == before.st_size else {throw failure("Subject length changed.")}
                    hasher.update(data:Data(fileHash.finalize()))
                }
            } else {
                let duplicate=Darwin.dup(fd)
                guard duplicate >= 0, let stream=Darwin.fdopendir(duplicate) else {if duplicate >= 0 {Darwin.close(duplicate)}; throw failure("Cannot enumerate subject.")}
                defer {Darwin.closedir(stream)}
                var names:[String]=[]
                while true {
                    try checkpoint(); errno=0
                    guard let entry=Darwin.readdir(stream) else {guard errno == 0 else {throw failure("Enumeration failed.")}; break}
                    let name=withUnsafePointer(to:entry.pointee.d_name) {p in p.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)) {String(validatingCString:$0)}}
                    guard let name else {throw failure("Non-UTF8 subject entry.")}; if name == "." || name == ".." {continue}
                    guard names.count+entries < 4096 else {throw InspectionArchiveError.limit}; names.append(name)
                }
                for name in names.sorted(by:{$0.utf8.lexicographicallyPrecedes($1.utf8)}) {
                    let child=Darwin.openat(fd,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
                    guard child >= 0 else {throw failure("Linked, unreadable or changed entry; full scope cannot be bound.")}; defer {Darwin.close(child)}
                    try walk(child,path.isEmpty ? name : path+"/"+name,depth+1)
                }
            }
            guard witness == Witness(path,try metadata(fd)) else {throw failure("Subject changed while reading identity.")}
        }
        try walk(root,"",0)
        // Rebind pathname to the descriptor's root identity after traversal.
        let reopened=Darwin.open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard reopened >= 0 else {throw failure("Subject root moved.")}; defer {Darwin.close(reopened)}
        guard witnesses.first == Witness("",try metadata(reopened)) else {throw failure("Subject root replaced.")}
        return (witnesses,hasher.finalize().map{String(format:"%02x",$0)}.joined())
    }
}
