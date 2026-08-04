// VirtualFS.swift - 虚拟文件系统: 路径解析 + fd 管理
//
// 在 RootFS 之上叠加文件描述符抽象, 处理:
//   - Linux 路径 -> 宿主路径转换 (AT_FDCWD / dirfd 相对路径)
//   - 目录 fd (DirectoryFD): getdents64 读取目录项
//   - 符号链接解析 (readlinkat)
//   - 权限检查 (faccessat)

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// AT_FDCWD: Linux 当前工作目录的特殊 fd
public let AT_FDCWD: Int32 = -100

/// Linux dirent64 结构 (getdents64 返回)
public struct LinuxDirent64 {
    public var d_ino: UInt64
    public var d_off: Int64
    public var d_reclen: UInt16
    public var d_type: UInt8
    public var d_name: [UInt8]  // 变长, 以 \0 结尾
}

/// 虚拟文件系统
public final class VirtualFS {
    public let rootfs: RootFS
    public var process: LinuxProcess

    public init(rootfs: RootFS, process: LinuxProcess) {
        self.rootfs = rootfs
        self.process = process
    }

    /// 解析 Linux 路径为宿主路径
    /// - Parameters:
    ///   - path: Linux 路径 (可能是绝对/相对)
    ///   - dirfd: AT_FDCWD 或目录 fd
    public func resolve(path: String, dirfd: Int32) -> String {
        if path.hasPrefix("/") {
            return rootfs.resolve(path)
        }
        // 相对路径
        let base: String
        if dirfd == AT_FDCWD {
            base = process.cwd
        } else if case .directory(let d)? = process.fdTable[dirfd] {
            base = d.path
        } else {
            base = process.cwd
        }
        let combined = base + "/" + path
        return rootfs.resolve(combined)
    }

    /// 打开目录并返回 fd
    public func openDirectory(_ hostPath: String) -> Int32 {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: hostPath) else {
            return -1
        }
        let dir = DirectoryFD(path: hostPath)
        dir.entries = entries
        return process.allocFd(.directory(dir))
    }

    /// getdents64: 读取目录项到缓冲
    public func getdents64(fd: Int32, buf: VA, count: Int) -> Int64 {
        guard case .directory(let dir)? = process.fdTable[fd] else {
            return Errno.ebadf.asSyscallReturn
        }
        guard let bufPtr = process.addressSpace.hostPointer(for: buf, size: count) else {
            return Errno.efault.asSyscallReturn
        }
        var written = 0
        while dir.pos < dir.entries.count {
            let name = dir.entries[dir.pos]
            let nameBytes = Array(name.utf8) + [0]
            // 对齐到 8 字节
            let reclen = UInt16((24 + nameBytes.count + 7) & ~7)
            if written + Int(reclen) > count { break }  // 缓冲不够

            // 写 dirent64
            let p = bufPtr.advanced(by: written)
            p.advanced(by: 0).assumingMemoryBound(to: UInt64.self).pointee = UInt64(dir.pos + 1)  // d_ino (简化)
            p.advanced(by: 8).assumingMemoryBound(to: Int64.self).pointee = Int64(dir.pos + 1)     // d_off
            p.advanced(by: 16).assumingMemoryBound(to: UInt16.self).pointee = reclen                // d_reclen
            // d_type
            var dType: UInt8 = DT.unknown.rawValue
            var st = stat()
            if stat(dir.path + "/" + name, &st) == 0 {
                let mode = st.st_mode
                if (mode & 0o170000) == 0o040000 { dType = DT.dir.rawValue }
                else if (mode & 0o170000) == 0o100000 { dType = DT.regular.rawValue }
                else if (mode & 0o170000) == 0o120000 { dType = DT.link.rawValue }
            }
            p.advanced(by: 18).assumingMemoryBound(to: UInt8.self).pointee = dType
            // d_name
            for (i, b) in nameBytes.enumerated() {
                p.advanced(by: 19 + i).assumingMemoryBound(to: UInt8.self).pointee = b
            }
            written += Int(reclen)
            dir.pos += 1
        }
        return Int64(written)
    }
}
