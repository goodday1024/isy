// LinuxProcess.swift - Linux 进程抽象 (完整实现)
//
// 持有一个 Linux "进程" 的完整上下文:
//   - 地址空间 (mmap 的内存区域集合)
//   - CPU 状态 (主线程)
//   - 文件描述符表 (fd -> VirtualFD)
//   - 当前工作目录 / umask
//   - 信号处理表 / 待处理信号
//   - 子进程列表 (fork 出来的)
//   - RootFS 引用
//   - 终端大小

import Foundation
import isyCHot

// MARK: - 虚拟文件描述符

public enum VirtualFD {
    case host(Int32)              // 直接映射到宿主 (iOS) fd
    case pipe(PipeEnd)            // isy 内部管道
    case eventfd(EventFD)
    case socket(SocketFD)
    case timerfd(TimerFD)
    case epoll(EpollFD)
    case directory(DirectoryFD)
    case signalfd(SignalfdFD)
}

public final class PipeEnd {
    public let buffer: UnsafeMutablePointer<UInt8>
    public let capacity: Int
    public var count: Int = 0
    public var closed: Bool = false
    /// 对端 PipeEnd (用于阻塞读写)
    public weak var peer: PipeEnd?
    /// 读取等待信号量 (用于阻塞 read)
    public let readSemaphore = DispatchSemaphore(value: 0)
    public init(capacity: Int = 65536) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
    }
    deinit { buffer.deallocate() }
}

public final class EventFD {
    public var count: UInt64 = 0
    public var flags: Int32 = 0
    public init(count: UInt64 = 0) { self.count = count }
}

public final class SocketFD {
    public var hostFd: Int32 = -1
    public var domain: Int32 = 0
    public var type: Int32 = 0
}

public final class TimerFD {
    public var hostFd: Int32 = -1
    public var nextExpiry: UInt64 = 0
    public var interval: UInt64 = 0
    public var clockId: Int32 = 0
}

public final class EpollFD {
    public var hostFd: Int32 = -1
    public var events: [(fd: Int32, events: UInt32, data: UInt64)] = []
    public var maxEvents: Int = 64
    public func add(fd: Int32, events: UInt32, data: UInt64) {
        // 移除已存在的相同 fd
        self.events.removeAll { $0.fd == fd }
        self.events.append((fd, events, data))
    }
    public func modify(fd: Int32, events: UInt32, data: UInt64) {
        if let idx = self.events.firstIndex(where: { $0.fd == fd }) {
            self.events[idx] = (fd, events, data)
        }
    }
    public func remove(fd: Int32) {
        self.events.removeAll { $0.fd == fd }
    }
}

public final class DirectoryFD {
    public var path: String
    public var entries: [String] = []
    public var pos: Int = 0
    public init(path: String) { self.path = path }
}

public final class SignalfdFD {
    public var sigset: UInt64 = 0  // 等待的信号掩码
    public var flags: Int32 = 0
}

// MARK: - Linux 进程

public final class LinuxProcess: @unchecked Sendable {
    public let pid: Int32
    public let parentPid: Int32
    public let addressSpace: LinuxAddressSpace
    public let cpu: CPUState

    /// fd 表 (Linux fd -> VirtualFD)
    public var fdTable: [Int32: VirtualFD] = [:]
    public var nextFd: Int32 = 3

    /// 当前工作目录 (Linux 路径)
    public var cwd: String = "/"
    public var umask: UInt32 = 0o022

    /// 信号处理表 (sig -> handler VA)
    public var signalHandlers: [Int32: UInt64] = [:]
    public var signalMasks: UInt64 = 0

    /// 退出码 / 状态
    public var exitCode: Int32 = 0
    public var exited: Bool = false
    public var suspended: Bool = false

    /// 待处理信号 (由 ProcessManager 设置, 在 syscall 返回时检查)
    public var pendingSignal: Int32 = 0

    /// TLS 区域地址
    public var tlsBase: UInt64 = 0
    public var stackTop: UInt64 = 0

    /// 主 ELF 镜像
    public var mainImage: ELFImage?

    /// RootFS 引用
    public var rootfs: RootFS?

    /// 终端大小
    public var terminalRows: UInt16 = 24
    public var terminalCols: UInt16 = 80

    /// 堆顶 (brk)
    public var brkEnd: UInt64 = 0x100000000

    /// 动态链接器
    public var dynamicLinker: DynamicLinker?

    /// 子进程列表 (用于 wait4)
    public var childProcesses: [ChildProcess] = []
    /// 下一个子进程 PID
    public var nextChildPid: Int32 = 2

    public init(pid: Int32, parentPid: Int32 = 1) {
        self.pid = pid
        self.parentPid = parentPid
        self.addressSpace = LinuxAddressSpace()
        self.cpu = CPUState()
    }

    public func allocFd(_ vfd: VirtualFD) -> Int32 {
        let fd = nextFd
        fdTable[fd] = vfd
        nextFd += 1
        return fd
    }

    public func freeFd(_ fd: Int32) {
        if let vfd = fdTable.removeValue(forKey: fd) {
            switch vfd {
            case .host(let h): close(h)
            case .pipe: break
            case .eventfd: break
            case .socket(let s): if s.hostFd >= 0 { close(s.hostFd) }
            case .timerfd(let t): if t.hostFd >= 0 { close(t.hostFd) }
            case .epoll(let e): if e.hostFd >= 0 { close(e.hostFd) }
            case .directory: break
            case .signalfd: break
            }
        }
    }
}

// MARK: - 子进程追踪

/// 子进程记录 (用于 clone/fork + wait4)
public final class ChildProcess: @unchecked Sendable {
    public let pid: Int32
    public let process: LinuxProcess
    public var exited: Bool = false
    public var exitCode: Int32 = 0
    public var exitSignal: Int32 = 0
    /// 等待该子进程的信号量
    public let waitSemaphore = DispatchSemaphore(value: 0)
    /// 子进程执行队列
    public let execQueue = DispatchQueue(label: "isy.process.child", qos: .userInitiated)

    public init(pid: Int32, process: LinuxProcess) {
        self.pid = pid
        self.process = process
    }
}