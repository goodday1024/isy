// FileSyscalls.swift - 基础文件/进程 syscall 实现
//
// 实现 isy 第一版必须支持的核心 syscall:
//   read/write/openat/close/lseek/fstat/writev/readv
//   exit/exit_group/getpid/getuid/geteuid/getgid/getegid
//   clock_gettime/gettimeofday
//   brk/mmap/munmap/mprotect (简化版)
//   uname/getrandom/sysinfo
//
// 路径解析: Linux 路径 -> 宿主 (iOS) 沙盒路径, 由 VirtualFS 处理.
// 第一版直接透传到宿主 POSIX (read/write/open), 后续叠加 OverlayFS.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import isyCHot

// Linux struct stat 字段布局 (ARM64, 与 <asm-generic/stat.h> 一致)
// 128 字节, 顺序: st_dev, st_ino, st_mode, st_nlink, st_uid, st_gid,
// st_rdev, __pad1, st_size, st_blksize, __pad2, st_blocks,
// st_atim, st_mtim, st_ctim, __unused[3]
public struct LinuxStat {
    public var st_dev: UInt64 = 0
    public var st_ino: UInt64 = 0
    public var st_mode: UInt32 = 0
    public var st_nlink: UInt32 = 0
    public var st_uid: UInt32 = 0
    public var st_gid: UInt32 = 0
    public var st_rdev: UInt64 = 0
    public var __pad1: UInt64 = 0
    public var st_size: Int64 = 0
    public var st_blksize: UInt32 = 0
    public var __pad2: UInt32 = 0
    public var st_blocks: UInt64 = 0
    public var st_atim_sec: Int64 = 0
    public var st_atim_nsec: Int64 = 0
    public var st_mtim_sec: Int64 = 0
    public var st_mtim_nsec: Int64 = 0
    public var st_ctim_sec: Int64 = 0
    public var st_ctim_nsec: Int64 = 0
    public var __unused: (UInt32, UInt32, UInt32) = (0, 0, 0)
}

public struct LinuxTimeSpec {
    public var tv_sec: Int64
    public var tv_nsec: Int64
}

public extension SyscallDispatcher {

    /// 注册第一版核心 syscall (含所有模块)
    func registerCoreSyscalls(process: LinuxProcess) {
        // 调用各模块注册
        registerFileSyscalls(process: process)
        registerSignalSyscalls(process: process)
        registerNetworkSyscalls(process: process)
        registerProcessSyscalls(process: process)
    }

    /// 文件 + 时间 + 内存 + 杂项
    func registerFileSyscalls(process: LinuxProcess) {
        // ---------- 进程/线程 ----------
        register(.exit) { _, code, _, _, _, _, _ in
            process.exitCode = Int32(truncatingIfNeeded: Int64(bitPattern: code))
            process.exited = true
            // 调用 isy_request_exit 恢复 iOS 上下文并返回
            // 注意: isy_request_exit 不返回 (noreturn)
            isy_request_exit(process.exitCode)
            // 永远不会到达这里, 但编译器需要 return
            return 0
        }
        register(.exitGroup) { _, code, _, _, _, _, _ in
            process.exitCode = Int32(truncatingIfNeeded: Int64(bitPattern: code))
            process.exited = true
            isy_request_exit(process.exitCode)
            return 0
        }
        register(.getpid) { _, _, _, _, _, _, _ in Int64(process.pid) }
        register(.getppid) { _, _, _, _, _, _, _ in Int64(process.parentPid) }
        register(.gettid) { _, _, _, _, _, _, _ in Int64(process.pid) }
        register(.getuid) { _, _, _, _, _, _, _ in 501 }   // iOS App 沙盒 uid
        register(.geteuid) { _, _, _, _, _, _, _ in 501 }
        register(.getgid) { _, _, _, _, _, _, _ in 20 }    // iOS App 沙盒 gid
        register(.getegid) { _, _, _, _, _, _, _ in 20 }

        // ---------- 文件 ----------
        register(.read) { _, fd, buf, count, _, _, _ in
            process.sys_read(fd: Int32(fd), buf: VA(buf), count: Int(count))
        }
        register(.write) { _, fd, buf, count, _, _, _ in
            process.sys_write(fd: Int32(fd), buf: VA(buf), count: Int(count))
        }
        register(.writev) { _, fd, iov, iovcnt, _, _, _ in
            process.sys_writev(fd: Int32(fd), iovVA: VA(iov), iovcnt: Int(iovcnt))
        }
        register(.readv) { _, fd, iov, iovcnt, _, _, _ in
            process.sys_readv(fd: Int32(fd), iovVA: VA(iov), iovcnt: Int(iovcnt))
        }
        register(.openat) { _, dirfd, pathname, flags, mode, _, _ in
            process.sys_openat(dirfd: Int32(dirfd), pathname: VA(pathname),
                               flags: Int32(flags), mode: UInt32(mode))
        }
        register(.close) { _, fd, _, _, _, _, _ in
            process.sys_close(fd: Int32(fd))
        }
        register(.lseek) { _, fd, offset, whence, _, _, _ in
            process.sys_lseek(fd: Int32(fd), offset: Int64(bitPattern: offset), whence: Int32(whence))
        }
        register(.fstat) { _, fd, statbuf, _, _, _, _ in
            process.sys_fstat(fd: Int32(fd), statbuf: VA(statbuf))
        }
        register(.newfstatat) { _, dirfd, pathname, statbuf, flags, _, _ in
            process.sys_fstatat(dirfd: Int32(dirfd), pathname: VA(pathname),
                                statbuf: VA(statbuf), flags: Int32(flags))
        }
        register(.getcwd) { _, buf, size, _, _, _, _ in
            process.sys_getcwd(buf: VA(buf), size: Int(size))
        }
        register(.chdir) { _, path, _, _, _, _, _ in
            process.sys_chdir(path: VA(path))
        }
        register(.readlinkat) { _, dirfd, path, buf, bufsize, _, _ in
            process.sys_readlinkat(dirfd: Int32(dirfd), path: VA(path),
                                   buf: VA(buf), bufsize: Int(bufsize))
        }
        register(.faccessat) { _, dirfd, pathname, mode, _, _, _ in
            process.sys_faccessat(dirfd: Int32(dirfd), pathname: VA(pathname), mode: Int32(mode))
        }

        // ---------- 时间 ----------
        register(.clock_gettime) { _, clk_id, tp, _, _, _, _ in
            process.sys_clock_gettime(clk_id: Int32(clk_id), tp: VA(tp))
        }
        register(.gettimeofday) { _, tv, tz, _, _, _, _ in
            process.sys_gettimeofday(tv: VA(tv), tz: tz == 0 ? nil : VA(tz))
        }
        register(.nanosleep) { _, req, rem, _, _, _, _ in
            process.sys_nanosleep(req: VA(req), rem: rem == 0 ? nil : VA(rem))
        }

        // ---------- 内存 ----------
        register(.brk) { _, addr, _, _, _, _, _ in
            process.sys_brk(addr: addr)
        }
        register(.mmap) { _, addr, length, prot, flags, fd, offset in
            process.sys_mmap(addr: addr, length: Int(length), prot: Int32(prot),
                             flags: Int32(flags), fd: Int32(fd), offset: offset)
        }
        register(.munmap) { _, addr, length, _, _, _, _ in
            process.sys_munmap(addr: addr, length: Int(length))
        }
        register(.mprotect) { _, addr, length, prot, _, _, _ in
            process.sys_mprotect(addr: addr, length: Int(length), prot: Int32(prot))
        }

        // ---------- 杂项 ----------
        register(.uname) { _, buf, _, _, _, _, _ in
            process.sys_uname(buf: VA(buf))
        }
        register(.getrandom) { _, buf, len, flags, _, _, _ in
            process.sys_getrandom(buf: VA(buf), len: Int(len), flags: Int32(flags))
        }
        register(.sysinfo) { _, buf, _, _, _, _, _ in
            process.sys_sysinfo(buf: VA(buf))
        }
        register(.set_tid_address) { _, tidptr, _, _, _, _, _ in
            // 简化: 返回 pid
            Int64(process.pid)
        }
    }
}

// ---------- LinuxProcess syscall 实现 ----------
public extension LinuxProcess {

    // read/write 直接转发到宿主 fd
    func sys_read(fd: Int32, buf: VA, count: Int) -> Int64 {
        guard let hostPtr = addressSpace.hostPointer(for: buf, size: count) else {
            return Errno.efault.asSyscallReturn
        }
        guard let vfd = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        switch vfd {
        case .host(let h):
            let n = read(h, hostPtr, count)
            return n >= 0 ? Int64(n) : Errno.fromHost(Int32(errno)).asSyscallReturn
        case .pipe(let p):
            return p.read(into: hostPtr, max: count)
        case .eventfd(let e):
            return e.read(into: hostPtr, max: count)
        default:
            return Errno.einval.asSyscallReturn
        }
    }

    func sys_write(fd: Int32, buf: VA, count: Int) -> Int64 {
        guard let hostPtr = addressSpace.hostPointer(for: buf, size: count) else {
            return Errno.efault.asSyscallReturn
        }
        guard let vfd = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        switch vfd {
        case .host(let h):
            let n = write(h, hostPtr, count)
            return n >= 0 ? Int64(n) : Errno.fromHost(Int32(errno)).asSyscallReturn
        case .pipe(let p):
            return p.write(from: hostPtr, max: count)
        case .eventfd(let e):
            return e.write(from: hostPtr, max: count)
        default:
            return Errno.einval.asSyscallReturn
        }
    }

    func sys_writev(fd: Int32, iovVA: VA, iovcnt: Int) -> Int64 {
        // struct iovec { void *iov_base; size_t iov_len; }  (16 字节)
        guard let iovPtr = addressSpace.hostPointer(for: iovVA, size: iovcnt * 16) else {
            return Errno.efault.asSyscallReturn
        }
        var total: Int64 = 0
        for i in 0..<iovcnt {
            let base = iovPtr.advanced(by: i * 16).assumingMemoryBound(to: UInt64.self).pointee
            let len = iovPtr.advanced(by: i * 16 + 8).assumingMemoryBound(to: UInt64.self).pointee
            if len == 0 { continue }
            let r = sys_write(fd: fd, buf: VA(base), count: Int(len))
            if r < 0 { return r }
            total += r
            if Int(r) < Int(len) { break }  // 短写
        }
        return total
    }

    func sys_readv(fd: Int32, iovVA: VA, iovcnt: Int) -> Int64 {
        guard let iovPtr = addressSpace.hostPointer(for: iovVA, size: iovcnt * 16) else {
            return Errno.efault.asSyscallReturn
        }
        var total: Int64 = 0
        for i in 0..<iovcnt {
            let basePtr = iovPtr.advanced(by: i * 16).assumingMemoryBound(to: UInt64.self)
            let lenPtr = iovPtr.advanced(by: i * 16 + 8).assumingMemoryBound(to: UInt64.self)
            let len = lenPtr.pointee
            if len == 0 { continue }
            let r = sys_read(fd: fd, buf: VA(basePtr.pointee), count: Int(len))
            if r < 0 { return r }
            total += r
            if Int(r) < Int(len) { break }
        }
        return total
    }

    func sys_openat(dirfd: Int32, pathname: VA, flags: Int32, mode: UInt32) -> Int64 {
        // 第一版: 直接透传到宿主 POSIX open (后续叠加 VirtualFS 路径转换)
        guard let pathPtr = addressSpace.hostPointer(for: pathname, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let path = String(cString: pathPtr.assumingMemoryBound(to: CChar.self))

        // 转换 Linux open flags -> 宿主 flags (大部分一致)
        var hostFlags = flags
        // O_LARGEFILE 在 32-bit 是 0o100000, 64-bit 不需要
        hostFlags &= ~0o100000

        // 判断是否为写操作: O_WRONLY=1, O_RDWR=2, O_CREAT=0o100, O_TRUNC=0o1000, O_APPEND=0o2000
        let isWrite = (flags & 0o3) != 0  // O_WRONLY 或 O_RDWR
        let isCreate = (flags & 0o100) != 0  // O_CREAT

        // 对于写操作或创建, 使用 resolvePathForWrite (OverlayFS CoW)
        let resolved: String
        if isWrite || isCreate {
            resolved = resolvePathForWrite(path, dirfd: dirfd, operation: isCreate ? .create : .write)
        } else {
            // 检查是否请求打开目录
            if (flags & 0o200000) != 0 {  // O_DIRECTORY
                let linuxPath = path.hasPrefix("/") ? path : cwd + "/" + path
                let rp = resolvePath(path, dirfd: dirfd)
                var st = stat()
                if stat(rp, &st) < 0 {
                    return Errno.fromHost(Int32(errno)).asSyscallReturn
                }
                if (st.st_mode & 0o170000) != 0o040000 {
                    return Errno.enotdir.asSyscallReturn
                }
                // 返回目录 fd (使用 RootFS 合并视图)
                return Int64(openDirectory(linuxPath: linuxPath))
            }
            resolved = resolvePath(path, dirfd: dirfd)
        }

        // O_CLOEXEC 一致
        let hostFd = open(resolved, hostFlags, mode_t(mode & 0o7777))
        if hostFd < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        let fd = allocFd(.host(hostFd))
        return Int64(fd)
    }

    func sys_close(fd: Int32) -> Int64 {
        guard fdTable[fd] != nil else { return Errno.ebadf.asSyscallReturn }
        freeFd(fd)
        return 0
    }

    func sys_lseek(fd: Int32, offset: Int64, whence: Int32) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        let r = lseek(h, off_t(offset), Int32(whence))
        if r < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
        return Int64(r)
    }

    func sys_fstat(fd: Int32, statbuf: VA) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        guard let outPtr = addressSpace.hostPointer(for: statbuf, size: 128) else {
            return Errno.efault.asSyscallReturn
        }
        var hostStat = stat()
        if fstat(h, &hostStat) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        var ls = LinuxStat()
        ls.st_dev = UInt64(hostStat.st_dev)
        ls.st_ino = UInt64(hostStat.st_ino)
        #if canImport(Glibc)
        ls.st_mode = UInt32(hostStat.st_mode)
        ls.st_nlink = UInt32(hostStat.st_nlink)
        ls.st_uid = UInt32(hostStat.st_uid)
        ls.st_gid = UInt32(hostStat.st_gid)
        ls.st_rdev = UInt64(hostStat.st_rdev)
        ls.st_size = Int64(hostStat.st_size)
        ls.st_blksize = UInt32(hostStat.st_blksize)
        ls.st_blocks = UInt64(hostStat.st_blocks)
        #elseif canImport(Darwin)
        ls.st_mode = UInt32(hostStat.st_mode)
        ls.st_nlink = UInt32(hostStat.st_nlink)
        ls.st_uid = UInt32(hostStat.st_uid)
        ls.st_gid = UInt32(hostStat.st_gid)
        ls.st_rdev = UInt64(hostStat.st_rdev)
        ls.st_size = Int64(hostStat.st_size)
        ls.st_blksize = UInt32(hostStat.st_blksize)
        ls.st_blocks = UInt64(hostStat.st_blocks)
        #endif
        outPtr.assumingMemoryBound(to: LinuxStat.self).pointee = ls
        return 0
    }

    func sys_fstatat(dirfd: Int32, pathname: VA, statbuf: VA, flags: Int32) -> Int64 {
        guard let pathPtr = addressSpace.hostPointer(for: pathname, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let path = String(cString: pathPtr.assumingMemoryBound(to: CChar.self))
        let resolved = resolvePath(path, dirfd: dirfd)
        guard let outPtr = addressSpace.hostPointer(for: statbuf, size: 128) else {
            return Errno.efault.asSyscallReturn
        }
        var hostStat = stat()
        if stat(resolved, &hostStat) < 0 {
            // AT_EMPTY_PATH 等暂不处理
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        var ls = LinuxStat()
        ls.st_dev = UInt64(hostStat.st_dev)
        ls.st_ino = UInt64(hostStat.st_ino)
        ls.st_mode = UInt32(hostStat.st_mode)
        ls.st_nlink = UInt32(hostStat.st_nlink)
        ls.st_uid = UInt32(hostStat.st_uid)
        ls.st_gid = UInt32(hostStat.st_gid)
        ls.st_rdev = UInt64(hostStat.st_rdev)
        ls.st_size = Int64(hostStat.st_size)
        ls.st_blksize = UInt32(hostStat.st_blksize)
        ls.st_blocks = UInt64(hostStat.st_blocks)
        outPtr.assumingMemoryBound(to: LinuxStat.self).pointee = ls
        return 0
    }

    func sys_getcwd(buf: VA, size: Int) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: buf, size: size) else {
            return Errno.efault.asSyscallReturn
        }
        let cwdBytes = Array(cwd.utf8CString)
        if cwdBytes.count > size { return Errno.erange.asSyscallReturn }
        for (i, b) in cwdBytes.enumerated() {
            ptr.advanced(by: i).assumingMemoryBound(to: CChar.self).pointee = b
        }
        return Int64(cwdBytes.count - 1)  // 不含 \0
    }

    func sys_chdir(path: VA) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: path, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let p = String(cString: ptr.assumingMemoryBound(to: CChar.self))
        cwd = resolvePath(p, dirfd: -100 /* AT_FDCWD */)
        return 0
    }

    func sys_readlinkat(dirfd: Int32, path: VA, buf: VA, bufsize: Int) -> Int64 {
        guard let pathPtr = addressSpace.hostPointer(for: path, size: 1),
              let outPtr = addressSpace.hostPointer(for: buf, size: bufsize) else {
            return Errno.efault.asSyscallReturn
        }
        let p = String(cString: pathPtr.assumingMemoryBound(to: CChar.self))
        let resolved = resolvePath(p, dirfd: dirfd)
        let n = readlink(resolved, outPtr.assumingMemoryBound(to: CChar.self), bufsize)
        if n < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
        return Int64(n)
    }

    func sys_faccessat(dirfd: Int32, pathname: VA, mode: Int32) -> Int64 {
        guard let pathPtr = addressSpace.hostPointer(for: pathname, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let p = String(cString: pathPtr.assumingMemoryBound(to: CChar.self))
        let resolved = resolvePath(p, dirfd: dirfd)
        if access(resolved, Int32(mode)) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    // ---------- 时间 ----------
    func sys_clock_gettime(clk_id: Int32, tp: VA) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: tp, size: 16) else {
            return Errno.efault.asSyscallReturn
        }
        var ts = timespec()
        if clock_gettime(CLOCK_REALTIME, &ts) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        let out = ptr.assumingMemoryBound(to: LinuxTimeSpec.self)
        out.pointee = LinuxTimeSpec(tv_sec: Int64(ts.tv_sec), tv_nsec: Int64(ts.tv_nsec))
        return 0
    }

    func sys_gettimeofday(tv: VA, tz: VA?) -> Int64 {
        if tv.raw != 0,
           let ptr = addressSpace.hostPointer(for: tv, size: 16) {
            var ts = timespec()
            clock_gettime(CLOCK_REALTIME, &ts)
            let out = ptr.assumingMemoryBound(to: LinuxTimeSpec.self)
            out.pointee = LinuxTimeSpec(tv_sec: Int64(ts.tv_sec), tv_nsec: Int64(ts.tv_nsec))
        }
        // tz 忽略 (已废弃)
        return 0
    }

    func sys_nanosleep(req: VA, rem: VA?) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: req, size: 16) else {
            return Errno.efault.asSyscallReturn
        }
        let inTS = ptr.assumingMemoryBound(to: LinuxTimeSpec.self).pointee
        var ts = timespec(tv_sec: Int(inTS.tv_sec), tv_nsec: Int(inTS.tv_nsec))
        var rem_ts = timespec()
        if nanosleep(&ts, &rem_ts) < 0 {
            if rem != nil, let remVA = rem,
               let remPtr = addressSpace.hostPointer(for: remVA, size: 16) {
                let out = remPtr.assumingMemoryBound(to: LinuxTimeSpec.self)
                out.pointee = LinuxTimeSpec(tv_sec: Int64(rem_ts.tv_sec), tv_nsec: Int64(rem_ts.tv_nsec))
            }
            return Errno.eintr.asSyscallReturn
        }
        return 0
    }

    // ---------- 内存 ----------
    func sys_brk(addr: UInt64) -> Int64 {
        // 简化: 返回固定 brk (后续实现真正的堆)
        return Int64(addr == 0 ? 0x100000000 : addr)
    }

    func sys_mmap(addr: UInt64, length: Int, prot: Int32, flags: Int32,
                  fd: Int32, offset: UInt64) -> Int64 {
        // 第一版: 只支持匿名映射, 文件映射后续实现
        if (flags & 0x20) == 0 {
            return Errno.enosys.asSyscallReturn
        }
        do {
            let region = try addressSpace.allocateAnonymous(
                size: length,
                prot: ProtFlags(rawValue: prot),
                vaHint: addr
            )
            return Int64(region.vaBase)
        } catch {
            return Errno.enomem.asSyscallReturn
        }
    }

    func sys_munmap(addr: UInt64, length: Int) -> Int64 {
        // 简化: 不真正 unmap (后续实现段表清理)
        return 0
    }

    func sys_mprotect(addr: UInt64, length: Int, prot: Int32) -> Int64 {
        // 简化: 委托给 mprotect
        let ptr = UnsafeMutableRawPointer(bitPattern: UInt(addr))
        if let ptr = ptr {
            var p: Int32 = 0
            if prot & 1 != 0 { p |= PROT_READ }
            if prot & 2 != 0 { p |= PROT_WRITE }
            if prot & 4 != 0 { p |= PROT_EXEC }
            if mprotect(ptr, length, p) < 0 {
                return Errno.fromHost(Int32(errno)).asSyscallReturn
            }
        }
        return 0
    }

    // ---------- 杂项 ----------
    func sys_uname(buf: VA) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: buf, size: 6 * 65) else {
            return Errno.efault.asSyscallReturn
        }
        // struct utsname: 6 个 65 字节字段
        func writeField(_ offset: Int, _ s: String) {
            let bytes = Array(s.utf8)
            for (i, b) in bytes.enumerated() where i < 64 {
                ptr.advanced(by: offset + i).assumingMemoryBound(to: CChar.self).pointee = CChar(bitPattern: b)
            }
            ptr.advanced(by: offset + min(bytes.count, 64))
                .assumingMemoryBound(to: CChar.self).pointee = 0
        }
        writeField(0,    "Linux")
        writeField(65,   "isy")
        writeField(130,  "5.15.0-isy")
        writeField(195,  "isy-v1")
        writeField(260,  "aarch64")
        writeField(325,  "isy")
        return 0
    }

    func sys_getrandom(buf: VA, len: Int, flags: Int32) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: buf, size: len) else {
            return Errno.efault.asSyscallReturn
        }
        // 用宿主 /dev/urandom 或 arc4random
        let fd = open("/dev/urandom", 0)
        if fd < 0 { return Errno.eio.asSyscallReturn }
        defer { close(fd) }
        let n = read(fd, ptr, len)
        return n >= 0 ? Int64(n) : Errno.eio.asSyscallReturn
    }

    func sys_sysinfo(buf: VA) -> Int64 {
        // struct sysinfo 简化: 返回 0
        guard let _ = addressSpace.hostPointer(for: buf, size: 112) else {
            return Errno.efault.asSyscallReturn
        }
        return 0
    }

    // ---------- 路径解析 ----------
    func resolvePath(_ path: String, dirfd: Int32) -> String {
        // 如果有 RootFS, 使用 RootFS 路径解析
        if let rfs = rootfs {
            if path.hasPrefix("/") {
                return rfs.resolve(path)
            }
            if path == "." || path.isEmpty {
                return rfs.resolve(cwd)
            }
            let combined = cwd + "/" + path
            return rfs.resolve(combined)
        }
        // 兜底: 简单路径拼接
        if path.hasPrefix("/") {
            return path
        }
        if path == "." || path.isEmpty {
            return cwd
        }
        return cwd + "/" + path
    }

    /// 解析写入路径 (使用 RootFS OverlayFS)
    func resolvePathForWrite(_ path: String, dirfd: Int32, operation: FileOp = .write) -> String {
        if let rfs = rootfs {
            let linuxPath: String
            if path.hasPrefix("/") {
                linuxPath = path
            } else {
                linuxPath = cwd + "/" + path
            }
            return (try? rfs.resolveForWrite(linuxPath, operation: operation)) ?? linuxPath
        }
        return resolvePath(path, dirfd: dirfd)
    }
}

// ---------- Errno 宿主映射 ----------
extension Errno {
    /// 从宿主 errno 转为 Linux Errno (大部分一致)
    public static func fromHost(_ hostErrno: Int32) -> Errno {
        return Errno(rawValue: hostErrno) ?? .eio
    }
}

// ---------- EventFD I/O ----------
extension EventFD {
    func read(into buf: UnsafeMutableRawPointer, max: Int) -> Int64 {
        if max < 8 { return -Errno.einval.asSyscallReturn }
        let v = count
        count = 0
        buf.assumingMemoryBound(to: UInt64.self).pointee = v
        return 8
    }

    func write(from buf: UnsafeRawPointer, max: Int) -> Int64 {
        if max < 8 { return -Errno.einval.asSyscallReturn }
        count &+= buf.assumingMemoryBound(to: UInt64.self).pointee
        return 8
    }
}
