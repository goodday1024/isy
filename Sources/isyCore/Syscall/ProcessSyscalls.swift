// ProcessSyscalls.swift - 进程/IPC/文件操作 syscall 补全
//
// 补全第一版需要的剩余 syscall:
//   ioctl/fcntl/getdents64/pipe2/eventfd2
//   clone/execve/wait4 (骨架)
//   futex (骨架)
//   mkdirat/unlinkat/renameat/symlinkat/linkat/fchmodat/fchownat/fsync

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import isyCHot

public extension LinuxProcess {

    // ---------- 文件控制 ----------
    func sys_ioctl(fd: Int32, cmd: UInt64, arg: UInt64) -> Int64 {
        // 简化: 只处理常用 cmd, 其他返回 0 (成功无操作)
        // TIOCGWINSZ = 0x5413 (Linux) / 0x40087468 (BSD)
        if cmd == 0x5413, arg != 0 {
            // 返回一个 80x24 的 winsize
            struct LinuxWinSize {
                var row: UInt16; var col: UInt16; var xpix: UInt16; var ypix: UInt16
            }
            if let ptr = addressSpace.hostPointer(for: VA(arg), size: 8) {
                ptr.assumingMemoryBound(to: LinuxWinSize.self).pointee = LinuxWinSize(row: 24, col: 80, xpix: 0, ypix: 0)
                return 0
            }
        }
        return 0  // 默认成功
    }

    func sys_fcntl(fd: Int32, cmd: Int32, arg: UInt64) -> Int64 {
        guard let vfd = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        switch cmd {
        case 0:   // F_DUPFD
            if case .host(let h) = vfd {
                return Int64(allocFd(.host(h)))
            }
        case 1:   // F_GETFD
            return 0  // 默认 close-on-exec 关闭
        case 2:   // F_SETFD
            return 0
        case 3:   // F_GETFL
            if case .host(let h) = vfd {
                let fl = fcntl(h, F_GETFL)
                return Int64(fl)
            }
        case 4:   // F_SETFL
            if case .host(let h) = vfd {
                _ = fcntl(h, F_SETFL, Int32(arg))
                return 0
            }
        default:
            break
        }
        return 0
    }

    func sys_getdents64(fd: Int32, bufVA: VA, count: Int) -> Int64 {
        guard case .directory(let dir)? = fdTable[fd] else {
            // 不是目录 fd: 尝试宿主 fd 的 fstat 判断
            if case .host(let h)? = fdTable[fd] {
                var st = stat()
                if fstat(h, &st) == 0, (st.st_mode & 0o170000) == 0o040000 {
                    // 是目录, 但我们没缓存条目: 用 fdopendir + readdir
                    let dirPath = "/proc/self/fd/\(h)"  // 简化
                    let vfd = openDirectory(hostPath: dirPath)
                    if vfd >= 0 {
                        return sys_getdents64(fd: vfd, bufVA: bufVA, count: count)
                    }
                }
            }
            return Errno.enotdir.asSyscallReturn
        }
        guard let bufPtr = addressSpace.hostPointer(for: bufVA, size: count) else {
            return Errno.efault.asSyscallReturn
        }
        var written = 0
        while dir.pos < dir.entries.count {
            let name = dir.entries[dir.pos]
            let nameBytes = Array(name.utf8) + [0]
            let reclen = (24 + nameBytes.count + 7) & ~7
            if written + reclen > count { break }
            let p = bufPtr.advanced(by: written)
            p.advanced(by: 0).assumingMemoryBound(to: UInt64.self).pointee = UInt64(dir.pos + 1)
            p.advanced(by: 8).assumingMemoryBound(to: Int64.self).pointee = Int64(dir.pos + 1)
            p.advanced(by: 16).assumingMemoryBound(to: UInt16.self).pointee = UInt16(reclen)
            p.advanced(by: 18).assumingMemoryBound(to: UInt8.self).pointee = DT.regular.rawValue
            for (i, b) in nameBytes.enumerated() {
                p.advanced(by: 19 + i).assumingMemoryBound(to: UInt8.self).pointee = b
            }
            written += reclen
            dir.pos += 1
        }
        return Int64(written)
    }

    /// 打开目录 (返回 DirectoryFD)
    func openDirectory(hostPath: String) -> Int32 {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hostPath) else {
            return -1
        }
        let dir = DirectoryFD(path: hostPath)
        dir.entries = entries
        return allocFd(.directory(dir))
    }

    // ---------- pipe / eventfd ----------
    func sys_pipe2(fdsVA: VA, flags: Int32) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: fdsVA, size: 8) else {
            return Errno.efault.asSyscallReturn
        }
        let readEnd = PipeEnd(capacity: 65536)
        let writeEnd = PipeEnd(capacity: 65536)
        // 简化: 两个独立的 PipeEnd, 实际应共享同一缓冲
        // (完整实现: PipeEnd 持有共享缓冲引用)
        let fd0 = allocFd(.pipe(readEnd))
        let fd1 = allocFd(.pipe(writeEnd))
        ptr.assumingMemoryBound(to: Int32.self).pointee = Int32(fd0)
        ptr.advanced(by: 4).assumingMemoryBound(to: Int32.self).pointee = Int32(fd1)
        return 0
    }

    func sys_eventfd2(initval: UInt32, flags: Int32) -> Int64 {
        let e = EventFD(count: UInt64(initval))
        return Int64(allocFd(.eventfd(e)))
    }

    // ---------- 文件系统操作 ----------
    func sys_mkdirat(dirfd: Int32, pathname: VA, mode: UInt32) -> Int64 {
        guard let pathPtr = addressSpace.hostPointer(for: pathname, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let p = String(cString: pathPtr.assumingMemoryBound(to: CChar.self))
        let resolved = resolvePath(p, dirfd: dirfd)
        if mkdir(resolved, mode_t(mode & 0o7777)) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    func sys_unlinkat(dirfd: Int32, pathname: VA, flags: Int32) -> Int64 {
        guard let pathPtr = addressSpace.hostPointer(for: pathname, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let p = String(cString: pathPtr.assumingMemoryBound(to: CChar.self))
        let resolved = resolvePath(p, dirfd: dirfd)
        // AT_REMOVEDIR = 0x200
        if flags & 0x200 != 0 {
            if rmdir(resolved) < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
        } else {
            if unlink(resolved) < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
        }
        return 0
    }

    func sys_renameat(olddirfd: Int32, oldpath: VA, newdirfd: Int32, newpath: VA) -> Int64 {
        guard let oldPtr = addressSpace.hostPointer(for: oldpath, size: 1),
              let newPtr = addressSpace.hostPointer(for: newpath, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let old = String(cString: oldPtr.assumingMemoryBound(to: CChar.self))
        let new = String(cString: newPtr.assumingMemoryBound(to: CChar.self))
        let oldResolved = resolvePath(old, dirfd: olddirfd)
        let newResolved = resolvePath(new, dirfd: newdirfd)
        if rename(oldResolved, newResolved) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    func sys_symlinkat(target: VA, newdirfd: Int32, linkpath: VA) -> Int64 {
        guard let targetPtr = addressSpace.hostPointer(for: target, size: 1),
              let linkPtr = addressSpace.hostPointer(for: linkpath, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let target = String(cString: targetPtr.assumingMemoryBound(to: CChar.self))
        let link = String(cString: linkPtr.assumingMemoryBound(to: CChar.self))
        let linkResolved = resolvePath(link, dirfd: newdirfd)
        if symlink(target, linkResolved) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    func sys_linkat(olddirfd: Int32, oldpath: VA, newdirfd: Int32, newpath: VA, flags: Int32) -> Int64 {
        guard let oldPtr = addressSpace.hostPointer(for: oldpath, size: 1),
              let newPtr = addressSpace.hostPointer(for: newpath, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let old = String(cString: oldPtr.assumingMemoryBound(to: CChar.self))
        let new = String(cString: newPtr.assumingMemoryBound(to: CChar.self))
        let oldResolved = resolvePath(old, dirfd: olddirfd)
        let newResolved = resolvePath(new, dirfd: newdirfd)
        if link(oldResolved, newResolved) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    func sys_fchmodat(dirfd: Int32, pathname: VA, mode: UInt32) -> Int64 {
        guard let pathPtr = addressSpace.hostPointer(for: pathname, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let p = String(cString: pathPtr.assumingMemoryBound(to: CChar.self))
        let resolved = resolvePath(p, dirfd: dirfd)
        if chmod(resolved, mode_t(mode & 0o7777)) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    func sys_fchownat(dirfd: Int32, pathname: VA, uid: UInt32, gid: UInt32, flags: Int32) -> Int64 {
        // 简化: iOS 沙盒不允许 chown, 直接返回 0 (成功)
        return 0
    }

    func sys_fsync(fd: Int32) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        if fsync(h) < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
        return 0
    }

    // ---------- 进程/线程 (骨架) ----------
    func sys_clone(flags: UInt64, stack: UInt64, ptid: UInt64, ctid: UInt64, tls: UInt64) -> Int64 {
        // iOS 不能真正 fork. 简化: 返回 ENOSYS, 让 glibc 走单线程 fallback
        return Errno.enosys.asSyscallReturn
    }

    func sys_execve(pathname: VA, argv: VA, envp: VA) -> Int64 {
        // execve: 替换当前进程镜像. 简化: 返回 ENOSYS
        return Errno.enosys.asSyscallReturn
    }

    func sys_wait4(pid: Int32, statusVA: VA, options: Int32, rusageVA: VA) -> Int64 {
        // 无 fork, 无子进程
        return Errno.echild.asSyscallReturn
    }

    func sys_futex(uaddr: VA, op: Int32, val: UInt32, timeout: VA, uaddr2: VA, val3: UInt32) -> Int64 {
        // 简化: FUTEX_WAIT 立即返回, FUTEX_WAKE 返回 0
        return 0
    }
}

public extension SyscallDispatcher {
    func registerProcessSyscalls(process: LinuxProcess) {
        register(.ioctl) { _, fd, cmd, arg, _, _, _ in
            process.sys_ioctl(fd: Int32(fd), cmd: cmd, arg: arg)
        }
        register(.fcntl) { _, fd, cmd, arg, _, _, _ in
            process.sys_fcntl(fd: Int32(fd), cmd: Int32(cmd), arg: arg)
        }
        register(.getdents64) { _, fd, buf, count, _, _, _ in
            process.sys_getdents64(fd: Int32(fd), bufVA: VA(buf), count: Int(count))
        }
        register(.pipe2) { _, fds, flags, _, _, _, _ in
            process.sys_pipe2(fdsVA: VA(fds), flags: Int32(flags))
        }
        register(.eventfd2) { _, initval, flags, _, _, _, _ in
            process.sys_eventfd2(initval: UInt32(initval), flags: Int32(flags))
        }
        register(.mkdirat) { _, dirfd, path, mode, _, _, _ in
            process.sys_mkdirat(dirfd: Int32(dirfd), pathname: VA(path), mode: UInt32(mode))
        }
        register(.unlinkat) { _, dirfd, path, flags, _, _, _ in
            process.sys_unlinkat(dirfd: Int32(dirfd), pathname: VA(path), flags: Int32(flags))
        }
        register(.renameat) { _, olddirfd, oldpath, newdirfd, newpath, _, _ in
            process.sys_renameat(olddirfd: Int32(olddirfd), oldpath: VA(oldpath),
                                 newdirfd: Int32(newdirfd), newpath: VA(newpath))
        }
        register(.symlinkat) { _, target, newdirfd, linkpath, _, _, _ in
            process.sys_symlinkat(target: VA(target), newdirfd: Int32(newdirfd), linkpath: VA(linkpath))
        }
        register(.linkat) { _, olddirfd, oldpath, newdirfd, newpath, flags, _ in
            process.sys_linkat(olddirfd: Int32(olddirfd), oldpath: VA(oldpath),
                               newdirfd: Int32(newdirfd), newpath: VA(newpath), flags: Int32(flags))
        }
        register(.fchmodat) { _, dirfd, path, mode, _, _, _ in
            process.sys_fchmodat(dirfd: Int32(dirfd), pathname: VA(path), mode: UInt32(mode))
        }
        register(.fchownat) { _, dirfd, path, uid, gid, flags, _ in
            process.sys_fchownat(dirfd: Int32(dirfd), pathname: VA(path),
                                 uid: UInt32(uid), gid: UInt32(gid), flags: Int32(flags))
        }
        register(.fsync) { _, fd, _, _, _, _, _ in process.sys_fsync(fd: Int32(fd)) }
        register(.fdatasync) { _, fd, _, _, _, _, _ in process.sys_fsync(fd: Int32(fd)) }
        register(.clone) { _, flags, stack, ptid, ctid, tls, _ in
            process.sys_clone(flags: flags, stack: stack, ptid: ptid, ctid: ctid, tls: tls)
        }
        register(.execve) { _, path, argv, envp, _, _, _ in
            process.sys_execve(pathname: VA(path), argv: VA(argv), envp: VA(envp))
        }
        register(.wait4) { _, pid, status, options, rusage, _, _ in
            process.sys_wait4(pid: Int32(pid), statusVA: VA(status),
                              options: Int32(options), rusageVA: VA(rusage))
        }
        register(.futex) { _, uaddr, op, val, timeout, uaddr2, val3 in
            process.sys_futex(uaddr: VA(uaddr), op: Int32(op), val: UInt32(val),
                              timeout: VA(timeout), uaddr2: VA(uaddr2), val3: UInt32(val3))
        }
        // epoll/poll (简化返回 ENOSYS, 后续实现)
        register(.epoll_create1) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
        register(.epoll_ctl) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
        register(.epoll_pwait) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
        register(.poll) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
        register(.ppoll) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
        register(.pselect6) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
    }
}

/// Linux dirent 类型 (与 VirtualFS 共用)
public enum DT: UInt8 {
    case unknown = 0
    case fifo    = 1
    case chr     = 2
    case dir     = 4
    case blk     = 6
    case regular = 8
    case link    = 10
    case sock    = 12
    case wht     = 14
}
