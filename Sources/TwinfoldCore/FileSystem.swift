import Darwin
import Foundation

/// Thin wrappers over the Darwin calls Twinfold relies on.
enum FileSystem {
    struct Stat: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let links: nlink_t
        let flags: UInt32
        let uid: uid_t
        let mtime: timespec
        let ctime: timespec

        static func == (a: Stat, b: Stat) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size && a.links == b.links
                && a.flags == b.flags && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
                && a.ctime.tv_sec == b.ctime.tv_sec && a.ctime.tv_nsec == b.ctime.tv_nsec
        }
    }

    static func lstat(_ path: String) -> Stat? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Stat(device: st.st_dev, inode: st.st_ino, size: st.st_size, links: st.st_nlink,
                    flags: st.st_flags, uid: st.st_uid, mtime: st.st_mtimespec, ctime: st.st_ctimespec)
    }

    /// Flags that mean "leave this file alone": iCloud/File Provider placeholders,
    /// transparently compressed system files, and locked or append-only files.
    static let untouchableFlags: UInt32 =
        0x4000_0000 /* SF_DATALESS */ | UInt32(UF_COMPRESSED) | UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)
        | UInt32(UF_APPEND) | UInt32(SF_APPEND) | UInt32(SF_RESTRICTED)

    /// Physical device offset of the byte at `offset` in the file, or nil if unknown.
    /// Two files whose first and last blocks map to the same place already share storage.
    static func physicalOffset(_ path: String, at offset: Int64) -> Int64? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var l2p = log2phys(l2p_flags: 0, l2p_contigbytes: 1, l2p_devoffset: offset)
        guard fcntl(fd, F_LOG2PHYS_EXT, &l2p) != -1 else { return nil }
        return l2p.l2p_devoffset
    }

    /// A fingerprint of where a file's data lives on disk (first and last block).
    static func extentKey(_ path: String, size: Int64) -> String? {
        guard let first = physicalOffset(path, at: 0) else { return nil }
        let lastOffset = max(0, (size - 1) / 4096 * 4096)
        guard let last = physicalOffset(path, at: lastOffset) else { return nil }
        return "\(first):\(last)"
    }

    /// Whether the volume holding `path` supports APFS-style file clones.
    static func supportsClones(_ path: String) -> Bool {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        struct Reply {
            var length: UInt32 = 0
            var caps = vol_capabilities_attr_t()
        }
        var reply = Reply()
        let mount = mountPoint(of: path)
        guard getattrlist(mount, &attrs, &reply, MemoryLayout<Reply>.size, 0) == 0 else { return false }
        let bit = UInt32(VOL_CAP_INT_CLONE)
        let index = Int(VOL_CAPABILITIES_INTERFACES)
        let valid = withUnsafeBytes(of: reply.caps.valid) { $0.load(fromByteOffset: index * 4, as: UInt32.self) }
        let caps = withUnsafeBytes(of: reply.caps.capabilities) { $0.load(fromByteOffset: index * 4, as: UInt32.self) }
        return (valid & bit) != 0 && (caps & bit) != 0
    }

    /// The canonical path with every symlink resolved (e.g. /var -> /private/var), so paths compare reliably.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func mountPoint(of path: String) -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return "/" }
        return withUnsafeBytes(of: fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    static func freeBytes(_ path: String) -> Int64 {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return 0 }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    /// Byte-for-byte comparison. Hashes find candidates; this is what we trust.
    static func contentsEqual(_ a: String, _ b: String) -> Bool {
        let fa = open(a, O_RDONLY | O_NOFOLLOW), fb = open(b, O_RDONLY | O_NOFOLLOW)
        defer { if fa >= 0 { close(fa) }; if fb >= 0 { close(fb) } }
        guard fa >= 0, fb >= 0 else { return false }
        _ = fcntl(fa, F_NOCACHE, 1)
        _ = fcntl(fb, F_NOCACHE, 1)
        let size = 1 << 20
        let ba = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        let bb = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { ba.deallocate(); bb.deallocate() }
        while true {
            let na = readFully(fa, ba, size), nb = readFully(fb, bb, size)
            if na < 0 || nb < 0 || na != nb { return false }
            if na == 0 { return true }
            if memcmp(ba, bb, na) != 0 { return false }
        }
    }

    static func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var total = 0
        while total < count {
            let n = read(fd, buffer + total, count - total)
            if n < 0 { if errno == EINTR { continue }; return -1 }
            if n == 0 { break }
            total += n
        }
        return total
    }

    /// Copies ownership-independent metadata (mode, flags, ACL, xattrs, times) from `source` onto `target`.
    static func copyMetadata(from source: String, to target: String) -> Bool {
        // The clone carries the keeper's xattrs; start clean so only the original's survive.
        let size = listxattr(target, nil, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var names = [CChar](repeating: 0, count: size)
            _ = listxattr(target, &names, size, XATTR_NOFOLLOW)
            for name in names.split(separator: 0) {
                let n = String(cString: Array(name) + [0])
                removexattr(target, n, XATTR_NOFOLLOW)
            }
        }
        let flags = copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR | COPYFILE_STAT | COPYFILE_NOFOLLOW)
        guard copyfile(source, target, nil, flags) == 0 else { return false }
        return copyTimes(from: source, to: target)
    }

    /// Creation, modification and access dates, so Finder shows exactly what it showed before.
    static func copyTimes(from source: String, to target: String) -> Bool {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME)
        // The reply is a UInt32 length followed by three timespecs packed at 4-byte alignment,
        // so read it as raw bytes rather than through a padded Swift struct.
        let stride = MemoryLayout<timespec>.size
        var reply = [UInt8](repeating: 0, count: 4 + 3 * stride)
        guard getattrlist(source, &attrs, &reply, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else { return false }
        let t = reply.withUnsafeBytes { raw in
            (0..<3).map { raw.loadUnaligned(fromByteOffset: 4 + $0 * stride, as: timespec.self) }
        }
        var values = (t[0], t[1], t[2])
        return setattrlist(target, &attrs, &values, MemoryLayout.size(ofValue: values), UInt32(FSOPT_NOFOLLOW)) == 0
    }
}
