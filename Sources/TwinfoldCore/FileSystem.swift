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
    /// Also files with a document id (UF_TRACKED), which Versions and iCloud follow by inode.
    static let untouchableFlags: UInt32 =
        0x4000_0000 /* SF_DATALESS */ | UInt32(UF_COMPRESSED) | UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)
        | UInt32(UF_APPEND) | UInt32(SF_APPEND) | UInt32(SF_RESTRICTED) | UInt32(UF_TRACKED)

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
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        func offset(_ at: Int64) -> Int64? {
            var l2p = log2phys(l2p_flags: 0, l2p_contigbytes: 1, l2p_devoffset: at)
            guard fcntl(fd, F_LOG2PHYS_EXT, &l2p) != -1 else { return nil }
            return l2p.l2p_devoffset
        }
        guard let first = offset(0), let last = offset(max(0, (size - 1) / 4096 * 4096)) else { return nil }
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

    /// Copies ownership-independent metadata (xattrs, mode, flags, ACL, times) from `source` onto `target`.
    static func copyMetadata(from source: String, to target: String) -> Bool {
        // Extended attributes are copied byte for byte by hand, after copyfile(3): it re-stamps
        // com.apple.quarantine on the way, dropping the app that downloaded the file.
        let flags = copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_STAT | COPYFILE_NOFOLLOW)
        guard copyfile(source, target, nil, flags) == 0, copyXattrs(from: source, to: target) else { return false }
        return copyTimes(from: source, to: target)
    }

    static func xattrNames(_ path: String) -> [String]? {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return size == 0 ? [] : nil }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return nil }
        return names.split(separator: 0).map { String(cString: Array($0) + [0]) }
    }

    static func xattr(_ path: String, _ name: String) -> [UInt8]? {
        let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { return nil }
        var value = [UInt8](repeating: 0, count: length)
        guard getxattr(path, name, &value, length, 0, XATTR_NOFOLLOW) == length else { return nil }
        return value
    }

    /// Makes `target`'s extended attributes exactly `source`'s. The clone starts with the keeper's,
    /// so those are cleared first. Attributes the system won't let us remove or set are caught by
    /// the metadata check afterwards, which then leaves the file alone.
    static func copyXattrs(from source: String, to target: String) -> Bool {
        guard let wanted = xattrNames(source), let existing = xattrNames(target) else { return false }
        for name in existing where !wanted.contains(name) { removexattr(target, name, XATTR_NOFOLLOW) }
        for name in wanted {
            guard let value = xattr(source, name) else { return false }
            if xattr(target, name) == value { continue }
            _ = value.withUnsafeBytes { setxattr(target, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        }
        return true
    }

    /// Creation, modification, access and "date added" dates, so Finder shows and sorts exactly as before.
    static func copyTimes(from source: String, to target: String) -> Bool {
        guard let t = times(source) else { return false }
        var attrs = timeAttrs
        var values = (t[0], t[1], t[2], t[3])
        return setattrlist(target, &attrs, &values, MemoryLayout.size(ofValue: values), UInt32(FSOPT_NOFOLLOW)) == 0
    }

    private static var timeAttrs: attrlist {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME)
            | attrgroup_t(ATTR_CMN_ADDEDTIME)
        return attrs
    }

    /// Creation, modification, access and added times, in that order.
    static func times(_ path: String) -> [timespec]? {
        var attrs = timeAttrs
        // The reply is a UInt32 length followed by timespecs packed at 4-byte alignment,
        // so read it as raw bytes rather than through a padded Swift struct.
        let stride = MemoryLayout<timespec>.size
        var reply = [UInt8](repeating: 0, count: 4 + 4 * stride)
        guard getattrlist(path, &attrs, &reply, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else { return nil }
        return reply.withUnsafeBytes { raw in
            (0..<4).map { raw.loadUnaligned(fromByteOffset: 4 + $0 * stride, as: timespec.self) }
        }
    }

    /// Everything about a file except its contents and inode that a person or an app could notice.
    struct Metadata: Equatable {
        let mode: mode_t, uid: uid_t, gid: gid_t, flags: UInt32
        let created: Int, modified: Int, modifiedNanos: Int, added: Int
        let xattrs: [String: [UInt8]]
        let acl: String?
    }

    /// What differs between two files' metadata, for the reason shown when a file is left alone.
    static func difference(_ a: Metadata, _ b: Metadata) -> String {
        var parts: [String] = []
        if a.mode != b.mode { parts.append("permissions") }
        if a.uid != b.uid || a.gid != b.gid { parts.append("owner") }
        if a.flags != b.flags { parts.append("flags") }
        if a.created != b.created || a.modified != b.modified || a.modifiedNanos != b.modifiedNanos { parts.append("dates") }
        if a.added != b.added { parts.append("date added") }
        if a.acl != b.acl { parts.append("ACL") }
        for name in Set(a.xattrs.keys).union(b.xattrs.keys).sorted() where a.xattrs[name] != b.xattrs[name] {
            parts.append(name)
        }
        return parts.joined(separator: ", ")
    }

    static func metadata(_ path: String) -> Metadata? {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0, let t = times(path) else { return nil }
        guard let names = xattrNames(path) else { return nil }
        var xattrs: [String: [UInt8]] = [:]
        for name in names {
            guard let value = xattr(path, name) else { return nil }
            xattrs[name] = value
        }
        var acl: String?
        if let a = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
            if let text = acl_to_text(a, nil) { acl = String(cString: text); acl_free(UnsafeMutableRawPointer(text)) }
            acl_free(UnsafeMutableRawPointer(a))
        }
        return Metadata(mode: st.st_mode, uid: st.st_uid, gid: st.st_gid, flags: st.st_flags,
                        created: t[0].tv_sec, modified: t[1].tv_sec, modifiedNanos: t[1].tv_nsec, added: t[3].tv_sec,
                        xattrs: xattrs, acl: acl)
    }

    /// Removes one of Twinfold's own temporary clones, even if it already carries a "deny delete" ACL or a lock flag
    /// copied from the original.
    static func removeTemp(_ path: String) {
        guard (path as NSString).lastPathComponent.hasPrefix(".twinfold-") else { return }
        if unlink(path) == 0 || errno == ENOENT { return }
        _ = lchflags(path, 0)
        if let empty = acl_init(0) {
            _ = acl_set_link_np(path, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        unlink(path)
    }

    /// Whether the file carries an ACL rule that denies something, which we read as "leave this alone".
    static func hasDenyRule(_ path: String) -> Bool {
        guard let a = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(a)) }
        guard let text = acl_to_text(a, nil) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text).contains(":deny")
    }

    struct FileID: Hashable { let device: Int64; let inode: UInt64 }

    /// Every file some process we can see has open for writing. A file swapped while a program is writing to it
    /// would lose that program's later writes, so those are left alone.
    static func filesOpenForWriting() -> Set<FileID> {
        var found = Set<FileID>()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return found }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 32)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size,
                      info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
                let st = info.pvip.vip_vi.vi_stat
                found.insert(FileID(device: Int64(st.vst_dev), inode: st.vst_ino))
            }
        }
        return found
    }
}
