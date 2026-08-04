// NetworkSyscalls.swift - 网络 syscall (POSIX socket 透传)
//
// 策略: 直接转发到宿主 BSD socket. iOS 允许 App 用 BSD socket,
// 只是后台网络受限 (需 background mode). 前台完全可用.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public extension LinuxProcess {

    func sys_socket(domain: Int32, type: Int32, protocol_: Int32) -> Int64 {
        let fd = socket(domain, type, protocol_)
        if fd < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
        return Int64(allocFd(.host(fd)))
    }

    func sys_socketpair(domain: Int32, type: Int32, protocol_: Int32, svVA: VA) -> Int64 {
        guard let ptr = addressSpace.hostPointer(for: svVA, size: 8) else {
            return Errno.efault.asSyscallReturn
        }
        var fds = [Int32](repeating: 0, count: 2)
        let r = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            socketpair(domain, type, protocol_, buf.baseAddress)
        }
        if r < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
        let fd0 = allocFd(.host(fds[0]))
        let fd1 = allocFd(.host(fds[1]))
        ptr.assumingMemoryBound(to: Int32.self).pointee = Int32(fd0)
        ptr.advanced(by: 4).assumingMemoryBound(to: Int32.self).pointee = Int32(fd1)
        return 0
    }

    func sys_bind(fd: Int32, addrVA: VA, addrlen: Int32) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        guard let ptr = addressSpace.hostPointer(for: addrVA, size: Int(addrlen)) else {
            return Errno.efault.asSyscallReturn
        }
        if bind(h, ptr.sockaddrCast, socklen_t(addrlen)) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    func sys_listen(fd: Int32, backlog: Int32) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        if listen(h, backlog) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    func sys_accept(fd: Int32, addrVA: VA, addrlenVA: VA) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        var len: socklen_t = 0
        if addrlenVA.raw != 0,
           let lenPtr = addressSpace.hostPointer(for: addrlenVA, size: 4) {
            len = socklen_t(lenPtr.assumingMemoryBound(to: UInt32.self).pointee)
        }
        var addr = sockaddr_storage()
        let newFd = withUnsafeMutablePointer(to: &addr) { p -> Int32 in
            accept(h, p.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }, &len)
        }
        if newFd < 0 { return Errno.fromHost(Int32(errno)).asSyscallReturn }
        // 写回 addr (简化: 不拷贝)
        return Int64(allocFd(.host(newFd)))
    }

    func sys_connect(fd: Int32, addrVA: VA, addrlen: Int32) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        guard let ptr = addressSpace.hostPointer(for: addrVA, size: Int(addrlen)) else {
            return Errno.efault.asSyscallReturn
        }
        if connect(h, ptr.sockaddrCast, socklen_t(addrlen)) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    func sys_sendto(fd: Int32, bufVA: VA, len: Int, flags: Int32, addrVA: VA, addrlen: Int32) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        guard let buf = addressSpace.hostPointer(for: bufVA, size: len) else {
            return Errno.efault.asSyscallReturn
        }
        let addrPtr: UnsafePointer<sockaddr>? = (addrVA.raw != 0)
            ? addressSpace.hostPointer(for: addrVA, size: Int(addrlen))?.sockaddrCast
            : nil
        let n = sendto(h, buf, len, flags, addrPtr, socklen_t(addrlen))
        return n >= 0 ? Int64(n) : Errno.fromHost(Int32(errno)).asSyscallReturn
    }

    func sys_recvfrom(fd: Int32, bufVA: VA, len: Int, flags: Int32, addrVA: VA, addrlenVA: VA) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        guard let buf = addressSpace.hostPointer(for: bufVA, size: len) else {
            return Errno.efault.asSyscallReturn
        }
        var lenIn: socklen_t = 0
        if addrlenVA.raw != 0,
           let lenPtr = addressSpace.hostPointer(for: addrlenVA, size: 4) {
            lenIn = socklen_t(lenPtr.assumingMemoryBound(to: UInt32.self).pointee)
        }
        let addrPtr: UnsafeMutablePointer<sockaddr>? = (addrVA.raw != 0)
            ? addressSpace.hostPointer(for: addrVA, size: Int(lenIn))?.sockaddrMutableCast
            : nil
        var lenMut = lenIn
        let n = recvfrom(h, buf, len, flags, addrPtr, &lenMut)
        return n >= 0 ? Int64(n) : Errno.fromHost(Int32(errno)).asSyscallReturn
    }

    func sys_setsockopt(fd: Int32, level: Int32, name: Int32, valVA: VA, len: Int32) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        guard let ptr = addressSpace.hostPointer(for: valVA, size: Int(len)) else {
            return Errno.efault.asSyscallReturn
        }
        if setsockopt(h, level, name, ptr, socklen_t(len)) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }

    func sys_getsockopt(fd: Int32, level: Int32, name: Int32, valVA: VA, lenVA: VA) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        guard let valPtr = addressSpace.hostPointer(for: valVA, size: 64),
              let lenPtr = addressSpace.hostPointer(for: lenVA, size: 4) else {
            return Errno.efault.asSyscallReturn
        }
        var len = socklen_t(lenPtr.assumingMemoryBound(to: UInt32.self).pointee)
        if getsockopt(h, level, name, valPtr, &len) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        lenPtr.assumingMemoryBound(to: UInt32.self).pointee = UInt32(len)
        return 0
    }

    func sys_shutdown(fd: Int32, how: Int32) -> Int64 {
        guard case .host(let h)? = fdTable[fd] else { return Errno.ebadf.asSyscallReturn }
        if shutdown(h, how) < 0 {
            return Errno.fromHost(Int32(errno)).asSyscallReturn
        }
        return 0
    }
}

// UnsafeMutableRawPointer -> sockaddr 转换 helper
fileprivate extension UnsafeMutableRawPointer {
    var sockaddrCast: UnsafePointer<sockaddr> {
        UnsafePointer(assumingMemoryBound(to: sockaddr.self))
    }
    var sockaddrMutableCast: UnsafeMutablePointer<sockaddr> {
        assumingMemoryBound(to: sockaddr.self)
    }
}

public extension SyscallDispatcher {
    func registerNetworkSyscalls(process: LinuxProcess) {
        register(.socket) { _, domain, type, proto, _, _, _ in
            process.sys_socket(domain: Int32(domain), type: Int32(type), protocol_: Int32(proto))
        }
        register(.socketpair) { _, domain, type, proto, sv, _, _ in
            process.sys_socketpair(domain: Int32(domain), type: Int32(type), protocol_: Int32(proto), svVA: VA(sv))
        }
        register(.bind) { _, fd, addr, addrlen, _, _, _ in
            process.sys_bind(fd: Int32(fd), addrVA: VA(addr), addrlen: Int32(addrlen))
        }
        register(.listen) { _, fd, backlog, _, _, _, _ in
            process.sys_listen(fd: Int32(fd), backlog: Int32(backlog))
        }
        register(.accept) { _, fd, addr, addrlen, _, _, _ in
            process.sys_accept(fd: Int32(fd), addrVA: VA(addr), addrlenVA: VA(addrlen))
        }
        register(.connect) { _, fd, addr, addrlen, _, _, _ in
            process.sys_connect(fd: Int32(fd), addrVA: VA(addr), addrlen: Int32(addrlen))
        }
        register(.sendto) { _, fd, buf, len, flags, addr, addrlen in
            process.sys_sendto(fd: Int32(fd), bufVA: VA(buf), len: Int(len), flags: Int32(flags),
                               addrVA: VA(addr), addrlen: Int32(addrlen))
        }
        register(.recvfrom) { _, fd, buf, len, flags, addr, addrlen in
            process.sys_recvfrom(fd: Int32(fd), bufVA: VA(buf), len: Int(len), flags: Int32(flags),
                                 addrVA: VA(addr), addrlenVA: VA(addrlen))
        }
        register(.setsockopt) { _, fd, level, name, val, len, _ in
            process.sys_setsockopt(fd: Int32(fd), level: Int32(level), name: Int32(name),
                                   valVA: VA(val), len: Int32(len))
        }
        register(.getsockopt) { _, fd, level, name, val, len, _ in
            process.sys_getsockopt(fd: Int32(fd), level: Int32(level), name: Int32(name),
                                   valVA: VA(val), lenVA: VA(len))
        }
        register(.shutdown) { _, fd, how, _, _, _, _ in
            process.sys_shutdown(fd: Int32(fd), how: Int32(how))
        }
    }
}
