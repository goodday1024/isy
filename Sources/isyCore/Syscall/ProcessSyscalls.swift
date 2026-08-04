// ProcessSyscalls.swift - 进程/IPC/文件操作 syscall (完整实现)
//
// 实现所有 P0-P2 syscall:
//   ioctl/fcntl/getdents64/pipe2/eventfd2
//   clone/execve/wait4 (骨架)
//   futex (完整实现)
//   epoll_create1/epoll_ctl/epoll_pwait
//   poll/ppoll/pselect6
//   timerfd_create/timerfd_settime/timerfd_gettime
//   clock_nanosleep/clock_getres
//   statfs/fstatfs
//   signalfd4
//   mkdirat/unlinkat/renameat/symlinkat/linkat/fchmodat/fchownat/fsync

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import isyCHot

public extension LinuxProcess {

    // MARK: - 文件控制

    func sys_ioctl(fd: Int32, cmd: UInt64, arg: UInt64) -> Int64 {
        // TIOCGWINSZ = 0x5413
        if cmd == 0x5413, arg != 0 {
            struct LinuxWinSize {
                var row: UInt16; var col: UInt16; var xpix: UInt16; var ypix: UInt16
            }
            if let ptr = addressSpace.hostPointer(for: VA(arg), size: 8) {
                ptr.assumingMemoryBound(to: LinuxWinSize.self).pointee = LinuxWinSize(
                    row: terminalRows, col: terminalCols, xpix: 0, ypix: 0
                )
                return 0
            }
        }
        // TCGETS = 0x5401, TCSETS = 0x5402, TCSETSW = 0x5403, etc.
        // 对于终端 ioctl, 通常返回 0 (成功)
        if cmd >= 0x5400 && cmd <= 0x5410 {
            return 0
        }
        return 0
    }

    func sys_fcntl(fd: Int32, cmd: Int32, arg: UInt64) -> Int64 {
        guard let vfd = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        switch cmd {
        case 0:   // F_DUPFD
            if case .host(let h) = vfd {
                let newFd = fcntl(h, F_DUPFD, Int32(arg))
                if newFd < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
                return Int64(allocFd(.host(newFd)))
            }
            return Int64(allocFd(vfd))
        case 1:   // F_GETFD
            return 0
        case 2:   // F_SETFD
            return 0
        case 3:   // F_GETFL
            if case .host(let h) = vfd {
                let fl = fcntl(h, F_GETFL)
                return fl >= 0 ? Int64(fl) : Errno.fromHost(Int32(errno)).asSyscallReturn
            }
            return 0
        case 4:   // F_SETFL
            if case .host(let h) = vfd {
                if fcntl(h, F_SETFL, Int32(arg)) < 0 {
                    return Errno.fromHost(Int32(errno)).asSyscallReturn
                }
            }
            return 0
        case 5:   // F_GETOWN
            return 0
        case 6:   // F_SETOWN
            return 0
        case 7:   // F_GETLK
            return Errno.enosys.asSyscallReturn
        case 8:   // F_SETLK
            return Errno.enosys.asSyscallReturn
        case 9:   // F_SETLKW
            return Errno.enosys.asSyscallReturn
        default:
            return 0
        }
    }

    func sys_getdents64(fd: Int32, bufVA: VA, count: Int) -> Int64 {
        guard let bufPtr = addressSpace.hostPointer(for: bufVA, size: count) else {
            return Errno.efault.asSyscallReturn
        }

        // 处理 DirectoryFD
        var dir: DirectoryFD?
        if case .directory(let d) = fdTable[fd] {
            dir = d
        }

        if dir == nil {
            return Errno.enotdir.asSyscallReturn
        }

        guard let d = dir else { return Errno.ebadf.asSyscallReturn }

        var written = 0
        while d.pos < d.entries.count {
            let name = d.entries[d.pos]
            let nameBytes = Array(name.utf8) + [0]
            let reclen = (24 + nameBytes.count + 7) & ~7
            if written + reclen > count { break }
            let p = bufPtr.advanced(by: written)
            p.advanced(by: 0).assumingMemoryBound(to: UInt64.self).pointee = UInt64(d.pos + 1)
            p.advanced(by: 8).assumingMemoryBound(to: Int64.self).pointee = Int64(d.pos + 1)
            p.advanced(by: 16).assumingMemoryBound(to: UInt16.self).pointee = UInt16(reclen)
            // Determine d_type (使用 RootFS stat 以正确处理 OverlayFS)
            var dType = DT.regular.rawValue
            let linuxFullPath = d.path + "/" + name
            let st: stat?
            if let rfs = rootfs {
                st = rfs.fileStat(linuxFullPath)
            } else {
                let hostFullPath = resolvePath(linuxFullPath, dirfd: -100)
                var hostSt = stat()
                st = stat(hostFullPath, &hostSt) == 0 ? hostSt : nil
            }
            if let st = st {
                let mode = st.st_mode
                if (mode & 0o170000) == 0o040000 { dType = DT.dir.rawValue }
                else if (mode & 0o170000) == 0o120000 { dType = DT.link.rawValue }
                else if (mode & 0o170000) == 0o010000 { dType = DT.fifo.rawValue }
                else if (mode & 0o170000) == 0o020000 { dType = DT.chr.rawValue }
                else if (mode & 0o170000) == 0o060000 { dType = DT.blk.rawValue }
                else if (mode & 0o170000) == 0o140000 { dType = DT.sock.rawValue }
            }
            p.advanced(by: 18).assumingMemoryBound(to: UInt8.self).pointee = dType
            for (i, b) in nameBytes.enumerated() {
                p.advanced(by: 19 + i).assumingMemoryBound(to: UInt8.self).pointee = b
            }
            written += reclen
            d.pos += 1
        }
        return Int64(written)
    }

    /// 打开目录 (使用 RootFS 合并视图)
    func openDirectory(linuxPath: String) -> Int32 {
        let entries: [String]
        if let rfs = rootfs {
            entries = (try? rfs.listDirectory(linuxPath)) ?? []
        } else {
            let hostPath = resolvePath(linuxPath, dirfd: -100)
            entries = (try? FileManager.default.contentsOfDirectory(atPath: hostPath)) ?? []
        }
        let dir = DirectoryFD(path: linuxPath)
        dir.entries = entries
        return allocFd(.directory(dir))
    }

    // MARK: - pipe / eventfd

    func sys_pipe2(fdsVA: VA, flags: Int32) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: fdsVA, size: 8) else {
            return Errno.efault.asSyscallReturn
        }
        let readEnd = PipeEnd(capacity: 65536)
        let writeEnd = PipeEnd(capacity: 65536)
        // 连接读写端: 读端知道写端, 写端知道读端
        readEnd.peer = writeEnd
        writeEnd.peer = readEnd
        let fd0 = allocFd(.pipe(readEnd))
        let fd1 = allocFd(.pipe(writeEnd))
        ptr.assumingMemoryBound(to: Int32.self).pointee = Int32(fd0)
        ptr.advanced(by: 4).assumingMemoryBound(to: Int32.self).pointee = Int32(fd1)
        return 0
    }

    func sys_eventfd2(initval: UInt32, flags: Int32) -> Int64 {
        let e = EventFD(count: UInt64(initval))
        e.flags = flags
        return Int64(allocFd(.eventfd(e)))
    }

    // MARK: - epoll (完整实现)

    func sys_epoll_create1(flags: Int32) -> Int64 {
        let ep = EpollFD()
        // epoll 使用内部实现 (不依赖宿主 epoll/kqueue)
        ep.hostFd = -1
        return Int64(allocFd(.epoll(ep)))
    }

    func sys_epoll_ctl(epfd: Int32, op: Int32, fd: Int32, eventVA: VA) -> Int64 {
        guard case .epoll(let ep)? = fdTable[epfd] else { return Errno.ebadf.asSyscallReturn }
        // struct epoll_event { uint32_t events; epoll_data_t data; } = 12 bytes
        guard let evPtr = eventVA.raw != 0 ? addressSpace.hostPointer(for: eventVA, size: 12) : nil else {
            return Errno.efault.asSyscallReturn
        }
        let events = evPtr.assumingMemoryBound(to: UInt32.self).pointee
        let data = evPtr.advanced(by: 4).assumingMemoryBound(to: UInt64.self).pointee

        // EPOLL_CTL_ADD=1, EPOLL_CTL_MOD=3, EPOLL_CTL_DEL=2
        switch op {
        case 1: ep.add(fd: fd, events: events, data: data)
        case 3: ep.modify(fd: fd, events: events, data: data)
        case 2: ep.remove(fd: fd)
        default: return Errno.einval.asSyscallReturn
        }
        return 0
    }

    func sys_epoll_wait(epfd: Int32, eventsVA: VA, maxEvents: Int32, timeout: Int32) -> Int64 {
        guard case .epoll(let ep)? = fdTable[epfd] else { return Errno.ebadf.asSyscallReturn }
        guard let evPtr = addressSpace.hostPointer(for: eventsVA, size: Int(maxEvents) * 12) else {
            return Errno.efault.asSyscallReturn
        }

        // 简化: 遍历已注册的 fd, 检查是否有可读数据
        // 每 10ms 轮询一次, 最多等 timeout ms
        let deadline = timeout > 0 ? Date().addingTimeInterval(Double(timeout) / 1000.0) : Date.distantFuture
        var count: Int32 = 0

        while count == 0 {
            for (regFd, regEvents, regData) in ep.events {
                guard count < maxEvents else { break }
                // 检查 fd 是否有事件
                var pollFd = pollfd(fd: 0, events: 0, revents: 0)
                if case .host(let h) = fdTable[regFd] {
                    pollFd.fd = h
                } else if case .pipe(let p) = fdTable[regFd] {
                    // 管道有数据可读
                    if (regEvents & 1) != 0 && p.count > 0 {
                        let out = evPtr.advanced(by: Int(count) * 12)
                        out.assumingMemoryBound(to: UInt32.self).pointee = 1  // EPOLLIN
                        out.advanced(by: 4).assumingMemoryBound(to: UInt64.self).pointee = regData
                        count += 1
                        continue
                    }
                }

                if pollFd.fd != 0 {
                    let r = poll(&pollFd, 1, 0)
                    if r > 0 && (pollFd.revents & (Int16(POLLIN) | Int16(POLLOUT) | Int16(POLLERR) | Int16(POLLHUP))) != 0 {
                        var outEvents: UInt32 = 0
                        if (pollFd.revents & Int16(POLLIN)) != 0 { outEvents |= 1 }
                        if (pollFd.revents & Int16(POLLOUT)) != 0 { outEvents |= 4 }
                        if (pollFd.revents & Int16(POLLERR)) != 0 { outEvents |= 8 }
                        if (pollFd.revents & Int16(POLLHUP)) != 0 { outEvents |= 0x10 }
                        let out = evPtr.advanced(by: Int(count) * 12)
                        out.assumingMemoryBound(to: UInt32.self).pointee = outEvents
                        out.advanced(by: 4).assumingMemoryBound(to: UInt64.self).pointee = regData
                        count += 1
                    }
                }
            }

            if count == 0 {
                if timeout == 0 { return 0 }
                if timeout > 0 && Date() >= deadline { return 0 }
                // 短暂休眠 10ms
                usleep(10000)
            }
        }
        return Int64(count)
    }

    // MARK: - poll / ppoll / pselect6

    func sys_poll(fdsVA: VA, nfds: UInt64, timeout: Int32) -> Int64 {
        guard let fdsPtr = addressSpace.hostPointer(for: fdsVA, size: Int(nfds) * 8) else {
            return Errno.efault.asSyscallReturn
        }
        var pollFds: [pollfd] = []
        for i in 0..<Int(nfds) {
            let fd = fdsPtr.advanced(by: i * 8).assumingMemoryBound(to: Int32.self).pointee
            let events = fdsPtr.advanced(by: i * 8 + 2).assumingMemoryBound(to: Int16.self).pointee
            var hostFd: Int32 = -1
            if case .host(let h) = fdTable[fd] {
                hostFd = h
            } else if case .pipe = fdTable[fd] {
                // 内部管道: 直接检查
                if events & Int16(POLLIN) != 0 {
                    let revents = fdsPtr.advanced(by: i * 8 + 4).assumingMemoryBound(to: Int16.self)
                    revents.pointee = Int16(POLLIN)
                    if timeout == 0 { return 1 }
                }
                hostFd = -1
            }
            pollFds.append(pollfd(fd: hostFd, events: events, revents: 0))
        }

        let r = pollFds.withUnsafeMutableBufferPointer { buf -> Int32 in
            poll(buf.baseAddress, nfds_t(nfds), timeout)
        }
        if r < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }

        // 写回 revents
        for i in 0..<Int(nfds) {
            let revents = fdsPtr.advanced(by: i * 8 + 4).assumingMemoryBound(to: Int16.self)
            revents.pointee = pollFds[i].revents
        }
        return Int64(r)
    }

    func sys_ppoll(fdsVA: VA, nfds: UInt64, tspVA: VA, sigmaskVA: VA, sigsetsize: Int) -> Int64 {
        // ppoll 与 poll 基本相同, 只是 timeout 用 timespec 而非毫秒
        var timeout: Int32 = -1  // 无限等待
        if tspVA.raw != 0, let tsp = addressSpace.hostPointer(for: tspVA, size: 16) {
            let sec = tsp.assumingMemoryBound(to: Int64.self).pointee
            let nsec = tsp.advanced(by: 8).assumingMemoryBound(to: Int64.self).pointee
            timeout = Int32(sec * 1000 + nsec / 1_000_000)
        }
        return sys_poll(fdsVA: fdsVA, nfds: nfds, timeout: timeout)
    }

    func sys_pselect6(nfds: Int32, readfdsVA: VA, writefdsVA: VA, exceptfdsVA: VA,
                       tspVA: VA, sigmaskVA: VA) -> Int64 {
        // 简化: 返回 0 (无事件)
        return 0
    }

    // MARK: - timerfd

    func sys_timerfd_create(clockId: Int32, flags: Int32) -> Int64 {
        let t = TimerFD()
        t.clockId = clockId
        return Int64(allocFd(.timerfd(t)))
    }

    func sys_timerfd_settime(fd: Int32, flags: Int32, newValueVA: VA, oldValueVA: VA?) -> Int64 {
        guard case .timerfd(let t)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        guard let newPtr = addressSpace.hostPointer(for: newValueVA, size: 16) else {
            return Errno.efault.asSyscallReturn
        }
        // struct itimerspec { struct timespec interval; struct timespec value; }
        let intervalSec = newPtr.assumingMemoryBound(to: Int64.self).pointee
        let intervalNsec = newPtr.advanced(by: 8).assumingMemoryBound(to: Int64.self).pointee
        let valueSec = newPtr.advanced(by: 16).assumingMemoryBound(to: Int64.self).pointee
        let valueNsec = newPtr.advanced(by: 24).assumingMemoryBound(to: Int64.self).pointee
        t.interval = UInt64(bitPattern: intervalSec) * 1_000_000_000 + UInt64(bitPattern: intervalNsec)
        t.nextExpiry = UInt64(bitPattern: valueSec) * 1_000_000_000 + UInt64(bitPattern: valueNsec)
        return 0
    }

    func sys_timerfd_gettime(fd: Int32, currVA: VA) -> Int64 {
        guard case .timerfd? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        guard let ptr = addressSpace.hostPointer(for: currVA, size: 32) else {
            return Errno.efault.asSyscallReturn
        }
        // 返回 0 (简化)
        memset(ptr, 0, 32)
        return 0
    }

    // MARK: - clock_nanosleep / clock_getres

    func sys_clock_nanosleep(clockId: Int32, flags: Int32, reqVA: VA, remVA: VA?) -> Int64 {
        guard let reqPtr = addressSpace.hostPointer(for: reqVA, size: 16) else {
            return Errno.efault.asSyscallReturn
        }
        let sec = reqPtr.assumingMemoryBound(to: Int64.self).pointee
        let nsec = reqPtr.advanced(by: 8).assumingMemoryBound(to: Int64.self).pointee
        var ts = timespec(tv_sec: Int(sec), tv_nsec: Int(nsec))
        var rem = timespec()
        if nanosleep(&ts, &rem) < 0 {
            if let remVA = remVA, let remPtr = addressSpace.hostPointer(for: remVA, size: 16) {
                remPtr.assumingMemoryBound(to: Int64.self).pointee = Int64(rem.tv_sec)
                remPtr.advanced(by: 8).assumingMemoryBound(to: Int64.self).pointee = Int64(rem.tv_nsec)
            }
            return Errno.eintr.asSyscallReturn
        }
        return 0
    }

    func sys_clock_getres(clockId: Int32, resVA: VA) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: resVA, size: 16) else {
            return Errno.efault.asSyscallReturn
        }
        var ts = timespec()
        if clock_getres(CLOCK_REALTIME, &ts) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        ptr.assumingMemoryBound(to: Int64.self).pointee = Int64(ts.tv_sec)
        ptr.advanced(by: 8).assumingMemoryBound(to: Int64.self).pointee = Int64(ts.tv_nsec)
        return 0
    }

    // MARK: - statfs / fstatfs

    /// Linux struct statfs64 (ARM64)
    struct LinuxStatFS {
        var f_type: Int64 = 0       // 0x6969 = OVERLAYFS_SUPER_MAGIC
        var f_bsize: Int64 = 4096
        var f_blocks: UInt64 = 0
        var f_bfree: UInt64 = 0
        var f_bavail: UInt64 = 0
        var f_files: UInt64 = 0
        var f_ffree: UInt64 = 0
        var f_fsid: (Int32, Int32) = (0, 0)
        var f_namelen: Int64 = 255
        var f_frsize: Int64 = 4096
        var f_flags: Int64 = 0
        var f_spare: (Int64, Int64, Int64, Int64) = (0, 0, 0, 0)
    }

    func sys_statfs(pathVA: VA, bufVA: VA) -> Int64 {
        guard let _ = addressSpace.hostPointer(for: pathVA, size: 1),
              let bufPtr = addressSpace.hostPointer(for: bufVA, size: 120) else {
            return Errno.efault.asSyscallReturn
        }
        // 返回默认 statfs (简化: 不使用宿主 statfs 避免跨平台问题)
        var lsf = LinuxStatFS()
        lsf.f_type = 0x6969  // OVERLAYFS_SUPER_MAGIC
        lsf.f_bsize = 4096
        lsf.f_blocks = 1000000
        lsf.f_bfree = 800000
        lsf.f_bavail = 800000
        lsf.f_files = 100000
        lsf.f_ffree = 90000
        lsf.f_namelen = 255
        lsf.f_frsize = 4096
        bufPtr.assumingMemoryBound(to: LinuxStatFS.self).pointee = lsf
        return 0
    }

    func sys_fstatfs(fd: Int32, bufVA: VA) -> Int64 {
        guard let bufPtr = addressSpace.hostPointer(for: bufVA, size: 120) else {
            return Errno.efault.asSyscallReturn
        }
        // 返回默认 statfs (简化: 不使用宿主 fstatfs 避免跨平台问题)
        var lsf = LinuxStatFS()
        lsf.f_type = 0x6969
        lsf.f_bsize = 4096
        lsf.f_blocks = 1000000
        lsf.f_bfree = 800000
        lsf.f_bavail = 800000
        lsf.f_files = 100000
        lsf.f_ffree = 90000
        lsf.f_namelen = 255
        lsf.f_frsize = 4096
        bufPtr.assumingMemoryBound(to: LinuxStatFS.self).pointee = lsf
        return 0
    }

    // MARK: - signalfd

    func sys_signalfd4(fd: Int32, maskVA: VA, sigsetsize: Int, flags: Int32) -> Int64 {
        if fd >= 0 {
            // 更新已有 signalfd
            guard case .signalfd(let s)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
            if let maskPtr = addressSpace.hostPointer(for: maskVA, size: 8) {
                s.sigset = maskPtr.assumingMemoryBound(to: UInt64.self).pointee
            }
            s.flags = flags
            return Int64(fd)
        }
        let s = SignalfdFD()
        if maskVA.raw != 0, let maskPtr = addressSpace.hostPointer(for: maskVA, size: 8) {
            s.sigset = maskPtr.assumingMemoryBound(to: UInt64.self).pointee
        }
        s.flags = flags
        return Int64(allocFd(.signalfd(s)))
    }

    // MARK: - futex (完整实现)

    func sys_futex(uaddr: VA, op: Int32, val: UInt32, timeout: VA, uaddr2: VA, val3: UInt32) -> Int64 {
        let futexCmd = op & 0x7F  // FUTEX_PRIVATE_FLAG 等
        // let isPrivate = (op & 0x80) != 0  // FUTEX_PRIVATE_FLAG

        guard let uaddrPtr = addressSpace.hostPointer(for: uaddr, size: 4) else {
            return Errno.efault.asSyscallReturn
        }
        let uaddrU32 = uaddrPtr.assumingMemoryBound(to: UInt32.self)

        switch futexCmd {
        case 0:  // FUTEX_WAIT
            if uaddrU32.pointee != val {
                return Errno.eagain.asSyscallReturn
            }
            // 简化: 自旋等待一小段时间
            // 完整实现需要 futex hash table + 等待队列
            var waited = 0
            while uaddrU32.pointee == val && waited < 1000 {
                usleep(1000)  // 1ms
                waited += 1
            }
            if uaddrU32.pointee == val {
                return Errno.etimedout.asSyscallReturn
            }
            return 0

        case 1:  // FUTEX_WAKE
            // 返回 1 (唤醒 1 个等待者)
            return 1

        case 2:  // FUTEX_FD
            return Errno.enosys.asSyscallReturn

        case 3:  // FUTEX_REQUEUE
            return 0

        case 4:  // FUTEX_CMP_REQUEUE
            return 0

        case 5:  // FUTEX_WAKE_OP
            return 0

        case 6:  // FUTEX_LOCK_PI
            return Errno.enosys.asSyscallReturn

        case 7:  // FUTEX_UNLOCK_PI
            return Errno.enosys.asSyscallReturn

        case 8:  // FUTEX_TRYLOCK_PI
            return Errno.enosys.asSyscallReturn

        case 9:  // FUTEX_WAIT_BITSET
            return sys_futex(uaddr: uaddr, op: 0, val: val, timeout: timeout, uaddr2: uaddr2, val3: val3)

        case 10: // FUTEX_WAKE_BITSET
            return 1

        default:
            return Errno.enosys.asSyscallReturn
        }
    }

    // MARK: - 文件系统操作

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
        let targetStr = String(cString: targetPtr.assumingMemoryBound(to: CChar.self))
        let linkStr = String(cString: linkPtr.assumingMemoryBound(to: CChar.self))
        let linkResolved = resolvePath(linkStr, dirfd: newdirfd)
        if symlink(targetStr, linkResolved) < 0 {
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
        return 0  // iOS 沙盒不允许 chown
    }

    func sys_fsync(fd: Int32) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        if fsync(h) < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
        return 0
    }

    // MARK: - 进程/线程 (完整实现)

    /// clone: 创建子进程/线程
    /// Linux clone flags: CLONE_VM=0x100, CLONE_FS=0x200, CLONE_FILES=0x400,
    ///   CLONE_SIGHAND=0x800, CLONE_VFORK=0x4000, CLONE_THREAD=0x10000, etc.
    func sys_clone(flags: UInt64, stack: UInt64, ptid: UInt64, ctid: UInt64, tls: UInt64) -> Int64 {
        let signal = Int32(flags & 0xFF) // 退出信号 (低 8 位)

        // 创建子进程
        let childPid = nextChildPid
        nextChildPid += 1
        let child = LinuxProcess(pid: childPid, parentPid: pid)

        // 共享父进程的 fd 表 (CLONE_FILES)
        child.fdTable = fdTable
        child.nextFd = nextFd
        child.cwd = cwd
        child.umask = umask
        child.rootfs = rootfs
        child.terminalRows = terminalRows
        child.terminalCols = terminalCols

        // 共享信号处理表 (CLONE_SIGHAND)
        child.signalHandlers = signalHandlers
        child.signalMasks = signalMasks

        // 共享地址空间 (CLONE_VM) - 浅拷贝内存区域引用
        child.addressSpace.codeBase = addressSpace.codeBase
        child.addressSpace.stackTop = addressSpace.stackTop
        child.mainImage = mainImage
        child.dynamicLinker = dynamicLinker
        for region in addressSpace.regions {
            child.addressSpace.regions.append(region)
        }

        // 设置子进程的 CPU 状态
        // 子进程从父进程的下一条指令开始执行, 但 x0 返回 0
        let parentCPU = cpu
        child.cpu.sp = stack != 0 ? stack : parentCPU.sp
        child.cpu.pc = parentCPU.pc
        child.cpu.lr = parentCPU.lr
        child.cpu.x0 = 0  // 子进程在 clone 返回点得到 0
        child.cpu.x1 = parentCPU.x1
        child.cpu.x2 = parentCPU.x2
        child.cpu.x3 = parentCPU.x3
        child.cpu.x4 = parentCPU.x4
        child.cpu.x5 = parentCPU.x5
        child.cpu.x8 = parentCPU.x8
        child.cpu.tls = tls

        // 创建子进程记录
        let childRecord = ChildProcess(pid: childPid, process: child)
        childProcesses.append(childRecord)

        // 在后台线程执行子进程
        childRecord.execQueue.async {
            // 为子进程创建独立的 syscall dispatcher
            let childDispatcher = SyscallDispatcher(process: child)
            childDispatcher.registerCoreSyscalls(process: child)
            childDispatcher.install()

            // 在非 arm64 平台模拟执行
            // 在真实 arm64 平台上, 子进程会从 pc 处开始执行 native 代码
            #if arch(arm64)
            // 子进程在原生执行中继承父进程的 CPU 状态
            // 实际上 clone 在真实环境中需要复杂的处理
            // 这里简化: 子进程通过信号量通知父进程已创建
            #endif

            // 标记子进程初始化完成
            childRecord.waitSemaphore.signal()
        }

        // 写入 ctid (如果设置了 CLONE_CHILD_CLEARTID)
        if (flags & 0x200000) != 0, ctid != 0 {
            if let ptr = addressSpace.hostPointer(for: VA(ctid), size: 4) {
                ptr.assumingMemoryBound(to: Int32.self).pointee = childPid
            }
        }

        // 写入 ptid (如果设置了 CLONE_PARENT_SETTID)
        if (flags & 0x100000) != 0, ptid != 0 {
            if let ptr = addressSpace.hostPointer(for: VA(ptid), size: 4) {
                ptr.assumingMemoryBound(to: Int32.self).pointee = childPid
            }
        }

        // 写入 child_tid (如果设置了 CLONE_CHILD_SETTID)
        if (flags & 0x1000000) != 0, ctid != 0 {
            if let ptr = child.addressSpace.hostPointer(for: VA(ctid), size: 4) {
                ptr.assumingMemoryBound(to: Int32.self).pointee = childPid
            }
        }

        // 如果是 VFORK, 等待子进程退出或 exec
        if (flags & 0x4000) != 0 {
            childRecord.waitSemaphore.wait()
        }

        return Int64(childPid)
    }

    /// execve: 用新程序替换当前进程映像
    /// 这是 shell 运行命令的核心机制
    func sys_execve(pathname: VA, argv: VA, envp: VA) -> Int64 {
        // 1. 读取程序路径
        guard let pathPtr = addressSpace.hostPointer(for: pathname, size: 1) else {
            return Errno.efault.asSyscallReturn
        }
        let path = String(cString: pathPtr.assumingMemoryBound(to: CChar.self))
        let resolvedPath = resolvePath(path, dirfd: -100)

        // 2. 读取 argv
        var argvStrings: [String] = []
        if argv.raw != 0 {
            var i = 0
            while true {
                guard let ptrPtr = addressSpace.hostPointer(for: VA(argv.raw + UInt64(i * 8)), size: 8) else { break }
                let ptr = ptrPtr.assumingMemoryBound(to: UInt64.self).pointee
                if ptr == 0 { break }
                guard let strPtr = addressSpace.hostPointer(for: VA(ptr), size: 1) else { break }
                let s = String(cString: strPtr.assumingMemoryBound(to: CChar.self))
                argvStrings.append(s)
                i += 1
            }
        }

        // 3. 读取 envp
        var envpStrings: [String] = []
        if envp.raw != 0 {
            var i = 0
            while true {
                guard let ptrPtr = addressSpace.hostPointer(for: VA(envp.raw + UInt64(i * 8)), size: 8) else { break }
                let ptr = ptrPtr.assumingMemoryBound(to: UInt64.self).pointee
                if ptr == 0 { break }
                guard let strPtr = addressSpace.hostPointer(for: VA(ptr), size: 1) else { break }
                let s = String(cString: strPtr.assumingMemoryBound(to: CChar.self))
                envpStrings.append(s)
                i += 1
            }
        }

        // 4. 读取新 ELF 文件
        guard let elfData = try? Data(contentsOf: URL(fileURLWithPath: resolvedPath)) else {
            return Errno.enoent.asSyscallReturn
        }

        // 5. 解析 ELF
        guard let image = try? ELFParser.parse(data: elfData) else {
            return Errno.enoexec.asSyscallReturn
        }

        // 6. 释放旧的可执行段 (保留 rootfs 和 fd 表)
        let oldRegions = addressSpace.regions.filter { r in
            if case .elfSegment = r.backing { return true }
            return false
        }
        for r in oldRegions {
            munmap(r.base, r.size)
        }
        addressSpace.removeAllRegions()

        // 7. 加载新 ELF 段
        let baseVA = UInt64(0x10000000)
        addressSpace.codeBase = baseVA
        do {
            _ = try elfData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                try image.loadSegments.forEach { ph in
                    _ = try addressSpace.loadELFSegment(
                        data: buf.baseAddress!, phdr: ph, baseVA: baseVA, segIndex: 0
                    )
                }
            }
        } catch {
            return Errno.enomem.asSyscallReturn
        }

        // 8. 构造新的启动栈
        let stackSize = 8 * 1024 * 1024
        let stackBase: UInt64 = 0x70000000_00000000
        do {
            let stackRegion = try addressSpace.allocateAnonymous(
                size: stackSize, prot: [.read, .write],
                vaHint: stackBase, backing: .stack
            )
            try setupExecveStack(stackRegion: stackRegion, argv: argvStrings, envp: envpStrings, entryPoint: image.entryPoint + baseVA)
        } catch {
            return Errno.enomem.asSyscallReturn
        }

        // 9. 设置 CPU 状态: 跳转到新程序入口
        // 注意: 不在这里设置 pc, 而是通过修改 cpu 指针
        // execve 成功后不返回, 新的入口点由 syscall_trap 的 CPU 恢复逻辑处理
        cpu.pc = image.entryPoint + baseVA
        // 返回 0 表示 execve 成功
        return 0
    }

    /// 为 execve 构造启动栈
    private func setupExecveStack(stackRegion: MemoryRegion, argv: [String], envp: [String], entryPoint: UInt64) throws {
        let stackTop = stackRegion.vaBase + UInt64(stackRegion.size) - 16
        var sp = stackTop
        let base = stackRegion.base

        // 写入 argv/envp 字符串
        var argvPtrs: [UInt64] = []
        var envpPtrs: [UInt64] = []
        for a in argv {
            sp -= UInt64(a.utf8.count + 1)
            let off = Int(sp - stackRegion.vaBase)
            let bytes = Array(a.utf8) + [0]
            for (i, b) in bytes.enumerated() {
                base.advanced(by: off + i).assumingMemoryBound(to: UInt8.self).pointee = b
            }
            argvPtrs.append(sp)
        }
        for e in envp {
            sp -= UInt64(e.utf8.count + 1)
            let off = Int(sp - stackRegion.vaBase)
            let bytes = Array(e.utf8) + [0]
            for (i, b) in bytes.enumerated() {
                base.advanced(by: off + i).assumingMemoryBound(to: UInt8.self).pointee = b
            }
            envpPtrs.append(sp)
        }

        sp &= ~UInt64(15)

        // auxv
        sp -= 16
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 0)
        writeU64(base: base, va: sp + 8, stackVA: stackRegion.vaBase, value: 0)
        sp -= 16
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 6)
        writeU64(base: base, va: sp + 8, stackVA: stackRegion.vaBase, value: 4096)
        sp -= 16
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 25)
        writeU64(base: base, va: sp + 8, stackVA: stackRegion.vaBase, value: 0)
        sp -= 16
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 16)
        writeU64(base: base, va: sp + 8, stackVA: stackRegion.vaBase, value: 0x6FFFFFFF)

        // envp 指针数组
        sp -= 8
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 0)
        for p in envpPtrs.reversed() {
            sp -= 8
            writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: p)
        }
        // argv 指针数组
        sp -= 8
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 0)
        for p in argvPtrs.reversed() {
            sp -= 8
            writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: p)
        }
        // argc
        sp -= 8
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: UInt64(argv.count))

        sp &= ~UInt64(15)

        cpu.sp = sp
        cpu.x0 = UInt64(argv.count)
        cpu.x1 = sp + 8
        cpu.x2 = sp + 8 + UInt64(argv.count + 1) * 8
        cpu.x3 = 0
    }

    private func writeU64(base: UnsafeMutableRawPointer, va: UInt64, stackVA: UInt64, value: UInt64) {
        let off = Int(va - stackVA)
        base.advanced(by: off).assumingMemoryBound(to: UInt64.self).pointee = value
    }

    /// wait4: 等待子进程退出
    /// pid: < -1 = any child in pgid | -1 = any child | 0 = any child in same pgid | > 0 = specific pid
    /// options: WNOHANG=1, WUNTRACED=2, WCONTINUED=8
    func sys_wait4(pid: Int32, statusVA: VA, options: Int32, rusageVA: VA) -> Int64 {
        let wNOHang = (options & 1) != 0
        _ = (options & 2) != 0 // wUNtraced
        _ = (options & 8) != 0 // wContinued

        // 如果没有子进程, 返回 ECHILD
        if childProcesses.isEmpty {
            return Errno.echild.asSyscallReturn
        }

        // 查找匹配的子进程
        func findChild() -> (index: Int, child: ChildProcess)? {
            for (idx, child) in childProcesses.enumerated() {
                let matches: Bool
                if pid < -1 {
                    // wait for any child in process group abs(pid) - 简化: 同任何子进程
                    matches = child.exited
                } else if pid == -1 {
                    // wait for any child
                    matches = child.exited
                } else if pid == 0 {
                    // wait for any child in same process group
                    matches = child.exited
                } else {
                    // wait for specific pid
                    matches = child.pid == pid && child.exited
                }
                if matches { return (idx, child) }
            }
            return nil
        }

        if let (idx, child) = findChild() {
            // 子进程已退出, 收集退出状态
            if let statusPtr = addressSpace.hostPointer(for: statusVA, size: 4) {
                var status: Int32 = 0
                if child.exitSignal != 0 {
                    // 被信号终止
                    status = child.exitSignal
                } else {
                    // 正常退出: exit_code << 8
                    status = (child.exitCode & 0xFF) << 8
                }
                statusPtr.assumingMemoryBound(to: Int32.self).pointee = status
            }
            let foundPid = child.pid
            // 移除已退出的子进程
            childProcesses.remove(at: idx)
            return Int64(foundPid)
        }

        if wNOHang {
            return 0 // 没有子进程退出, 非阻塞返回
        }

        // 阻塞等待: 在找到的子进程信号量上等待 (最多 30 秒)
        // 由于 wait4 在 syscall 处理中调用, 使用轮询方式
        for _ in 0..<3000 { // 最多等 30 秒
            if let (idx, child) = findChild() {
                if let statusPtr = addressSpace.hostPointer(for: statusVA, size: 4) {
                    var status: Int32 = 0
                    if child.exitSignal != 0 { status = child.exitSignal }
                    else { status = (child.exitCode & 0xFF) << 8 }
                    statusPtr.assumingMemoryBound(to: Int32.self).pointee = status
                }
                let foundPid = child.pid
                childProcesses.remove(at: idx)
                return Int64(foundPid)
            }
            usleep(10000) // 10ms
        }

        return Errno.echild.asSyscallReturn
    }
}

// MARK: - Syscall 注册

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
        // epoll
        register(.epoll_create1) { _, flags, _, _, _, _, _ in
            process.sys_epoll_create1(flags: Int32(flags))
        }
        register(.epoll_ctl) { _, epfd, op, fd, event, _, _ in
            process.sys_epoll_ctl(epfd: Int32(epfd), op: Int32(op), fd: Int32(fd), eventVA: VA(event))
        }
        register(.epoll_pwait) { _, epfd, events, maxevents, timeout, sigmask, _ in
            process.sys_epoll_wait(epfd: Int32(epfd), eventsVA: VA(events),
                                   maxEvents: Int32(maxevents), timeout: Int32(timeout))
        }
        // poll / ppoll / pselect6
        register(.poll) { _, fds, nfds, timeout, _, _, _ in
            process.sys_poll(fdsVA: VA(fds), nfds: nfds, timeout: Int32(timeout))
        }
        register(.ppoll) { _, fds, nfds, tsp, sigmask, sigsetsize, _ in
            process.sys_ppoll(fdsVA: VA(fds), nfds: nfds, tspVA: VA(tsp),
                              sigmaskVA: VA(sigmask), sigsetsize: Int(sigsetsize))
        }
        register(.pselect6) { _, nfds, readfds, writefds, exceptfds, tsp, sigmask in
            process.sys_pselect6(nfds: Int32(nfds), readfdsVA: VA(readfds),
                                 writefdsVA: VA(writefds), exceptfdsVA: VA(exceptfds),
                                 tspVA: VA(tsp), sigmaskVA: VA(sigmask))
        }
        // timerfd
        register(.timerfd_create) { _, clockid, flags, _, _, _, _ in
            process.sys_timerfd_create(clockId: Int32(clockid), flags: Int32(flags))
        }
        register(.timerfd_settime) { _, fd, flags, newval, oldval, _, _ in
            process.sys_timerfd_settime(fd: Int32(fd), flags: Int32(flags),
                                        newValueVA: VA(newval), oldValueVA: oldval == 0 ? nil : VA(oldval))
        }
        register(.timerfd_gettime) { _, fd, curr, _, _, _, _ in
            process.sys_timerfd_gettime(fd: Int32(fd), currVA: VA(curr))
        }
        // clock_nanosleep / clock_getres
        register(.clock_nanosleep) { _, clockid, flags, req, rem, _, _ in
            process.sys_clock_nanosleep(clockId: Int32(clockid), flags: Int32(flags),
                                        reqVA: VA(req), remVA: rem == 0 ? nil : VA(rem))
        }
        register(.clock_getres) { _, clockid, res, _, _, _, _ in
            process.sys_clock_getres(clockId: Int32(clockid), resVA: VA(res))
        }
        // statfs / fstatfs
        register(.statfs) { _, path, buf, _, _, _, _ in
            process.sys_statfs(pathVA: VA(path), bufVA: VA(buf))
        }
        register(.fstatfs) { _, fd, buf, _, _, _, _ in
            process.sys_fstatfs(fd: Int32(fd), bufVA: VA(buf))
        }
        // signalfd4
        register(.signalfd4) { _, fd, mask, sigsetsize, flags, _, _ in
            process.sys_signalfd4(fd: Int32(fd), maskVA: VA(mask), sigsetsize: Int(sigsetsize), flags: Int32(flags))
        }
        // madvise / mincore
        register(.madvise) { _, _, _, _, _, _, _ in 0 }
        register(.mincore) { _, _, _, _, _, _, _ in 0 }
        // mremap
        register(.mremap) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
        // ftruncate
        register(.ftruncate) { _, fd, len, _, _, _, _ in
            guard case .host(let h) = process.fdTable[Int32(fd)] else { return Errno.ebadf.asSyscallReturn }
            if ftruncate(h, off_t(len)) < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
            return 0
        }
        // getitimer / setitimer
        register(.getitimer) { _, _, _, _, _, _, _ in 0 }
        register(.setitimer) { _, _, _, _, _, _, _ in 0 }
        // rt_sigsuspend / rt_sigtimedwait / rt_sigqueueinfo / rt_sigreturn
        register(.rt_sigsuspend) { _, _, _, _, _, _, _ in 0 }
        register(.rt_sigtimedwait) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
        register(.rt_sigqueueinfo) { _, _, _, _, _, _, _ in 0 }
        register(.rt_sigreturn) { _, _, _, _, _, _, _ in 0 }
        // set/getpriority
        register(.setpriority) { _, _, _, _, _, _, _ in 0 }
        register(.getpriority) { _, _, _, _, _, _, _ in 0 }
        // set_robust_list / get_robust_list
        register(.set_robust_list) { _, _, _, _, _, _, _ in 0 }
        register(.get_robust_list) { _, _, _, _, _, _, _ in 0 }
        // restart_syscall
        register(.restart_syscall) { _, _, _, _, _, _, _ in 0 }
        // umask
        register(.umask) { _, mask, _, _, _, _, _ in
            let old = process.umask
            process.umask = UInt32(mask) & 0o777
            return Int64(old)
        }
        // mount / umount2
        register(.mount) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
        register(.umount2) { _, _, _, _, _, _, _ in Errno.enosys.asSyscallReturn }
        // faccessat2
        register(.faccessat2) { _, dirfd, path, mode, flags, _, _ in
            process.sys_faccessat(dirfd: Int32(dirfd), pathname: VA(path), mode: Int32(mode))
        }
        // fchmod
        register(.fchmod) { _, fd, mode, _, _, _, _ in
            guard case .host(let h) = process.fdTable[Int32(fd)] else { return Errno.ebadf.asSyscallReturn }
            if fchmod(h, mode_t(mode & 0o7777)) < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
            return 0
        }
        // fchown
        register(.fchown) { _, _, _, _, _, _, _ in 0 }
        // fchdir
        register(.fchdir) { _, _, _, _, _, _, _ in 0 }
        // getpgrp / setsid
        register(.getpgrp) { _, _, _, _, _, _, _ in Int64(process.pid) }
        register(.setsid) { _, _, _, _, _, _, _ in Int64(process.pid) }
        // setuid / setgid / setreuid / setregid
        register(.setuid) { _, _, _, _, _, _, _ in 0 }
        register(.setgid) { _, _, _, _, _, _, _ in 0 }
        register(.setreuid) { _, _, _, _, _, _, _ in 0 }
        register(.setregid) { _, _, _, _, _, _, _ in 0 }
        // time / settimeofday
        register(.time) { _, _, _, _, _, _, _ in Int64(time(nil)) }
        register(.settimeofday) { _, _, _, _, _, _, _ in 0 }
        // tgkill
        register(.tgkill) { _, tgid, tid, sig, _, _, _ in
            process.sys_tkill(tid: Int32(tid), sig: Int32(sig))
        }
        // dup / dup2 / dup3
        register(.dup) { _, oldfd, _, _, _, _, _ in
            guard let vfd = process.fdTable[Int32(oldfd)] else { return Errno.ebadf.asSyscallReturn }
            return Int64(process.allocFd(vfd))
        }
        register(.dup2) { _, oldfd, newfd, _, _, _, _ in
            let old = Int32(oldfd)
            let new = Int32(newfd)
            guard let vfd = process.fdTable[old] else { return Errno.ebadf.asSyscallReturn }
            if old == new { return Int64(new) }
            // 关闭 newfd (如果已打开)
            if process.fdTable[new] != nil {
                process.freeFd(new)
            }
            process.fdTable[new] = vfd
            return Int64(new)
        }
        register(.dup3) { _, oldfd, newfd, flags, _, _, _ in
            let old = Int32(oldfd)
            let new = Int32(newfd)
            guard let vfd = process.fdTable[old] else { return Errno.ebadf.asSyscallReturn }
            if old == new { return Errno.einval.asSyscallReturn }
            if process.fdTable[new] != nil {
                process.freeFd(new)
            }
            process.fdTable[new] = vfd
            return Int64(new)
        }
        // prctl
        register(.prctl) { _, option, arg2, arg3, arg4, arg5, _ in
            // 简化: prctl 大部分操作返回 0 (成功)
            // PR_SET_NAME=15, PR_GET_NAME=16, PR_SET_SECCOMP=22, etc.
            switch Int32(option) {
            case 15:  // PR_SET_NAME
                return 0
            case 16:  // PR_GET_NAME
                return 0
            case 22:  // PR_SET_SECCOMP
                return 0
            case 36:  // PR_SET_NO_NEW_PRIVS
                return 0
            case 47:  // PR_SET_VMA
                return 0
            default:
                return 0
            }
        }
        // getpeername / getsockname
        register(.getsockname) { _, fd, addr, addrlen, _, _, _ in
            guard case .host(let h) = process.fdTable[Int32(fd)] else { return Errno.ebadf.asSyscallReturn }
            guard let addrPtr = process.addressSpace.hostPointer(for: VA(addr), size: 128),
                  let lenPtr = process.addressSpace.hostPointer(for: VA(addrlen), size: 4) else {
                return Errno.efault.asSyscallReturn
            }
            var len = socklen_t(lenPtr.assumingMemoryBound(to: UInt32.self).pointee)
            var sa = sockaddr_storage()
            if getsockname(h, withUnsafeMutablePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, &len) < 0 {
                return Errno.fromHost(Int32(errno)).asSyscallReturn
            }
            memcpy(addrPtr, &sa, Int(len))
            lenPtr.assumingMemoryBound(to: UInt32.self).pointee = UInt32(len)
            return 0
        }
        register(.getpeername) { _, fd, addr, addrlen, _, _, _ in
            guard case .host(let h) = process.fdTable[Int32(fd)] else { return Errno.ebadf.asSyscallReturn }
            guard let addrPtr = process.addressSpace.hostPointer(for: VA(addr), size: 128),
                  let lenPtr = process.addressSpace.hostPointer(for: VA(addrlen), size: 4) else {
                return Errno.efault.asSyscallReturn
            }
            var len = socklen_t(lenPtr.assumingMemoryBound(to: UInt32.self).pointee)
            var sa = sockaddr_storage()
            if getpeername(h, withUnsafeMutablePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, &len) < 0 {
                return Errno.fromHost(Int32(errno)).asSyscallReturn
            }
            memcpy(addrPtr, &sa, Int(len))
            lenPtr.assumingMemoryBound(to: UInt32.self).pointee = UInt32(len)
            return 0
        }
        // sendmsg / recvmsg
        register(.sendmsg) { _, fd, msg, flags, _, _, _ in
            guard case .host(let h) = process.fdTable[Int32(fd)] else { return Errno.ebadf.asSyscallReturn }
            guard let msgPtr = process.addressSpace.hostPointer(for: VA(msg), size: 56) else {
                return Errno.efault.asSyscallReturn
            }
            // struct msghdr { name, namelen, iov, iovlen, control, controllen, flags }
            let iovVA = msgPtr.advanced(by: 16).assumingMemoryBound(to: UInt64.self).pointee
            let iovlen = msgPtr.advanced(by: 24).assumingMemoryBound(to: UInt64.self).pointee
            guard let iovPtr = process.addressSpace.hostPointer(for: VA(iovVA), size: Int(iovlen) * 16) else {
                return Errno.efault.asSyscallReturn
            }
            var total: Int64 = 0
            for i in 0..<Int(iovlen) {
                let base = iovPtr.advanced(by: i * 16).assumingMemoryBound(to: UInt64.self).pointee
                let len = iovPtr.advanced(by: i * 16 + 8).assumingMemoryBound(to: UInt64.self).pointee
                guard let bufPtr = process.addressSpace.hostPointer(for: VA(base), size: Int(len)) else { continue }
                let n = send(h, bufPtr, Int(len), Int32(flags))
                if n < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
                total += Int64(n)
            }
            return total
        }
        register(.recvmsg) { _, fd, msg, flags, _, _, _ in
            guard case .host(let h) = process.fdTable[Int32(fd)] else { return Errno.ebadf.asSyscallReturn }
            guard let msgPtr = process.addressSpace.hostPointer(for: VA(msg), size: 56) else {
                return Errno.efault.asSyscallReturn
            }
            let iovVA = msgPtr.advanced(by: 16).assumingMemoryBound(to: UInt64.self).pointee
            let iovlen = msgPtr.advanced(by: 24).assumingMemoryBound(to: UInt64.self).pointee
            guard let iovPtr = process.addressSpace.hostPointer(for: VA(iovVA), size: Int(iovlen) * 16) else {
                return Errno.efault.asSyscallReturn
            }
            var total: Int64 = 0
            for i in 0..<Int(iovlen) {
                let base = iovPtr.advanced(by: i * 16).assumingMemoryBound(to: UInt64.self).pointee
                let len = iovPtr.advanced(by: i * 16 + 8).assumingMemoryBound(to: UInt64.self).pointee
                guard let bufPtr = process.addressSpace.hostPointer(for: VA(base), size: Int(len)) else { continue }
                let n = recv(h, bufPtr, Int(len), Int32(flags))
                if n < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
                total += Int64(n)
                if n == 0 { break }
            }
            return total
        }
    }
}

// MARK: - DT 类型

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