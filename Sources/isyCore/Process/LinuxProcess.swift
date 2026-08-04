// LinuxProcess.swift - Linux 进程抽象
//
// 持有一个 Linux "进程" 的完整上下文:
//   - 地址空间 (mmap 的内存区域集合)
//   - CPU 状态 (主线程)
//   - 文件描述符表 (fd -> VirtualFD)
//   - 当前工作目录 / umask
//   - 信号处理表
//   - 子进程列表 (fork 出来的)
//
// iOS 上没有真正的 fork(), 我们用 GCD 创建新线程模拟 fork (共享内存的 CoW
// 副本). execve 是替换镜像重新加载.

import Foundation
import isyCHot

/// 虚拟文件描述符 (可能是真实 fd, 也可能是 isy 内部对象如 pipe/eventfd)
public enum VirtualFD {
    case host(Int32)              // 直接映射到宿主 (iOS) fd
    case pipe(PipeEnd)            // isy 内部管道
    case eventfd(EventFD)
    case socket(SocketFD)
    case timerfd(TimerFD)
    case epoll(EpollFD)
    case directory(DirectoryFD)
}

public final class PipeEnd {
    public let buffer: UnsafeMutablePointer<UInt8>
    public let capacity: Int
    public var count: Int = 0
    public var closed: Bool = false
    public init(capacity: Int = 65536) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
    }
    deinit { buffer.deallocate() }
}

public final class EventFD {
    public var count: UInt64 = 0
    public init(count: UInt64 = 0) { self.count = count }
}

public final class SocketFD {
    public var hostFd: Int32 = -1
    public var domain: Int32 = 0
    public var type: Int32 = 0
}

public final class TimerFD {
    public var nextExpiry: UInt64 = 0
    public var interval: UInt64 = 0
}

public final class EpollFD {
    public var events: [(fd: Int32, events: UInt32, data: UInt64)] = []
}

public final class DirectoryFD {
    public var path: String
    public var entries: [String] = []
    public var pos: Int = 0
    public init(path: String) { self.path = path }
}

/// Linux 进程
public final class LinuxProcess {
    public let pid: Int32
    public let parentPid: Int32
    public let addressSpace: LinuxAddressSpace
    public let cpu: CPUState

    /// fd 表 (Linux fd -> VirtualFD)
    public var fdTable: [Int32: VirtualFD] = [:]
    /// 下一个可用 fd
    public var nextFd: Int32 = 3

    /// 当前工作目录 (Linux 路径, 如 "/home/user")
    public var cwd: String = "/"

    /// umask
    public var umask: UInt32 = 0o022

    /// 信号处理表 (sig -> handler VA)
    public var signalHandlers: [Int32: UInt64] = [:]

    /// 退出码 (exit 后设置)
    public var exitCode: Int32 = 0
    public var exited: Bool = false

    /// TLS 区域地址
    public var tlsBase: UInt64 = 0

    /// 主线程栈顶
    public var stackTop: UInt64 = 0

    /// 主 ELF 镜像引用 (供 syscall handler 查询入口等信息)
    public var mainImage: ELFImage?

    public init(pid: Int32, parentPid: Int32 = 1) {
        self.pid = pid
        self.parentPid = parentPid
        self.addressSpace = LinuxAddressSpace()
        self.cpu = CPUState()
    }

    /// 分配一个 fd
    public func allocFd(_ vfd: VirtualFD) -> Int32 {
        let fd = nextFd
        fdTable[fd] = vfd
        nextFd += 1
        return fd
    }

    /// 释放 fd
    public func freeFd(_ fd: Int32) {
        if let vfd = fdTable.removeValue(forKey: fd) {
            switch vfd {
            case .host(let h): close(h)
            case .pipe: break  // PipeEnd 由 ARC 释放
            case .eventfd: break
            case .socket(let s): if s.hostFd >= 0 { close(s.hostFd) }
            case .timerfd: break
            case .epoll: break
            case .directory: break
            }
        }
    }
}
