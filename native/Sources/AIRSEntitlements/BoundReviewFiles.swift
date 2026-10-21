import Foundation
import Darwin
import AIRSCore

/// Descriptor-bound regular-file read, adapting the existing owned importer and
/// ResumeFileIdentity change witness. The witness is not a content digest.
public enum BoundReviewFiles {
    public static func read(_ url: URL, limit: Int) throws -> Data { try snapshot(url,limit:limit).0 }
    static func snapshot(_ url: URL, limit: Int) throws -> (Data,ResumeFileIdentity) {
        guard url.isFileURL,limit > 0 else { throw BoundReviewError.invalid("Choose a bounded local file.") }
        let fd = Darwin.open(url.path,O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW)
        guard fd >= 0 else { throw BoundReviewError.invalid("Cannot open evidence file.") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_size >= 0,info.st_size <= limit else { throw InspectionArchiveError.limit }
        let before = try ResumeFileIdentity.capture(url)
        func sameDescriptor() -> Bool {
            var current = stat()
            return fstat(fd,&current) == 0 && current.st_mode & S_IFMT == S_IFREG &&
                UInt64(UInt32(bitPattern:current.st_dev)) == before.device && current.st_ino == before.inode && current.st_size == before.size &&
                Int64(current.st_mtimespec.tv_sec) == before.modifiedSeconds && Int64(current.st_mtimespec.tv_nsec) == before.modifiedNanos &&
                Int64(current.st_ctimespec.tv_sec) == before.changedSeconds && Int64(current.st_ctimespec.tv_nsec) == before.changedNanos
        }
        guard sameDescriptor() else { throw BoundReviewError.invalid("Evidence changed before reading.") }
        var bytes = Data()
        while bytes.count <= limit {
            let chunk = try handle.read(upToCount:min(65_536,limit+1-bytes.count)) ?? Data()
            if chunk.isEmpty { break }; bytes.append(chunk)
        }
        guard bytes.count <= limit,bytes.count == before.size,sameDescriptor(),try ResumeFileIdentity.capture(url) == before else { throw BoundReviewError.invalid("Evidence changed while reading or exceeded its limit.") }
        return (bytes,before)
    }
}
