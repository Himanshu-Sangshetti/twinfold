import Darwin
import Foundation

/// Fast parallel directory walk built on getattrlistbulk(2): one system call returns the size, ids and flags
/// of many directory entries at once, instead of one lstat per file.
struct Walker {
    struct File {
        let path: String
        let stat: FileSystem.Stat
    }

    let skip: Set<String>
    let threads: Int

    /// Calls `visit` for every regular file under `root` on the same volume, from several threads.
    /// `visit` must be thread-safe.
    func walk(_ root: String, visit: @escaping @Sendable (File) -> Void) {
        var st = Darwin.stat()
        guard Darwin.lstat(root, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFREG {
            if let s = FileSystem.lstat(root) { visit(File(path: root, stat: s)) }
            return
        }
        let queue = WorkQueue(first: root)
        let device = Int32(st.st_dev)
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024, alignment: 16)
            defer { buffer.deallocate() }
            while let dir = queue.next() {
                var subdirs: [String] = []
                list(dir, device: device, buffer: buffer, files: visit) { subdirs.append($0) }
                queue.finish(adding: subdirs)
            }
        }
    }

    private func list(_ dir: String, device: Int32, buffer: UnsafeMutableRawPointer,
                      files: (File) -> Void, dirs: (String) -> Void) {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_CHGTIME) | attrgroup_t(ATTR_CMN_OWNERID) | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
        attrs.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_DATALENGTH)
        let options = UInt64(FSOPT_PACK_INVAL_ATTRS) | UInt64(FSOPT_NOFOLLOW)
        let prefix = dir == "/" ? "" : dir

        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, 256 * 1024, options)
            if count <= 0 { return }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                // Layout follows the attribute bit order; every field is 4-byte aligned.
                var p = entry + 4 + MemoryLayout<attribute_set_t>.size
                let nameRef = p
                let nameOffset = Int(p.loadUnaligned(as: Int32.self))
                let nameLength = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                p += 8
                let devid = p.loadUnaligned(as: Int32.self); p += 4
                let type = p.loadUnaligned(as: UInt32.self); p += 4
                let mtime = p.loadUnaligned(as: timespec.self); p += MemoryLayout<timespec>.size
                let ctime = p.loadUnaligned(as: timespec.self); p += MemoryLayout<timespec>.size
                let uid = p.loadUnaligned(as: UInt32.self); p += 4
                let flags = p.loadUnaligned(as: UInt32.self); p += 4
                let inode = p.loadUnaligned(as: UInt64.self); p += 8
                let links = p.loadUnaligned(as: UInt32.self); p += 4
                let size = p.loadUnaligned(as: Int64.self)

                let namePtr = (nameRef + nameOffset).assumingMemoryBound(to: CChar.self)
                let name = String(decoding: UnsafeRawBufferPointer(start: namePtr, count: max(0, nameLength - 1)),
                                  as: UTF8.self)
                let path = prefix + "/" + name

                switch type {
                case UInt32(VDIR.rawValue):
                    if devid == device, !skip.contains(path), !Scanner.isProtectedBundle(path) { dirs(path) }
                case UInt32(VREG.rawValue):
                    let stat = FileSystem.Stat(device: devid, inode: inode, size: size, links: nlink_t(links),
                                               flags: flags, uid: uid, mtime: mtime, ctime: ctime)
                    files(File(path: path, stat: stat))
                default:
                    continue  // symlinks, devices, sockets
                }
            }
        }
    }
}

/// A shared stack of directories with "all done" detection: done when the stack is empty and no worker is
/// still listing a directory (which could add more).
final class WorkQueue: @unchecked Sendable {
    private var stack: [String]
    private var busy = 0
    private let condition = NSCondition()

    init(first: String) { stack = [first] }

    func next() -> String? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty {
            if busy == 0 { return nil }
            condition.wait()
        }
        busy += 1
        return stack.removeLast()
    }

    func finish(adding dirs: [String]) {
        condition.lock()
        stack.append(contentsOf: dirs)
        busy -= 1
        condition.broadcast()
        condition.unlock()
    }
}
