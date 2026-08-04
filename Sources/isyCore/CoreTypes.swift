// CoreTypes.swift - isy 核心类型定义
//
// 这里定义跨模块共享的基础类型, 全部为值类型或纯 Swift, 不依赖 iOS API,
// 可在 Linux/macOS/iOS 跨平台编译测试.

import Foundation

/// 虚拟地址 (Linux 进程地址空间内的地址)
public struct VA: Hashable, Equatable, CustomStringConvertible, Sendable {
    public let raw: UInt64
    @inlinable public init(_ raw: UInt64) { self.raw = raw }
    public var description: String { String(format: "0x%016llx", raw) }

    @inlinable public static func + (lhs: VA, rhs: UInt64) -> VA { VA(lhs.raw + rhs) }
    @inlinable public static func - (lhs: VA, rhs: UInt64) -> VA { VA(lhs.raw - rhs) }
    @inlinable public static func == (lhs: VA, rhs: UInt64) -> Bool { lhs.raw == rhs }
}

/// Linux 错误码 (与 <asm-generic/errno-base.h> 一致)
public enum Errno: Int32, Error {
    case none = 0
    case eperm = 1
    case enoent = 2
    case esrch = 3
    case eintr = 4
    case eio = 5
    case enxio = 6
    case e2big = 7
    case enoexec = 8
    case ebadf = 9
    case echild = 10
    case eagain = 11
    case enomem = 12
    case eacces = 13
    case efault = 14
    case ebusy = 16
    case eexist = 17
    case exdev = 18
    case enodev = 19
    case enotdir = 20
    case eisdir = 21
    case einval = 22
    case enfile = 23
    case emfile = 24
    case enotty = 25
    case enospc = 28
    case espipe = 29
    case erofs = 30
    case erange = 34
    case enosys = 38
    case enotempty = 39
    case eloop = 40
    case enomsg = 42
    case enotsup = 95
    case eoverflow = 75
    case econnreset = 104
    case econnrefused = 111
    case etimedout = 110

    /// 转为 Linux syscall 返回值 (负数)
    @inlinable public var asSyscallReturn: Int64 { -Int64(rawValue) }
}

/// Linux 信号编号 (与 <signal.h> 一致)
public enum Signal: Int32 {
    case sighup = 1
    case sigint = 2
    case sigquit = 3
    case sigill = 4
    case sigtrap = 5
    case sigabrt = 6
    case sigbus = 7
    case sigfpe = 8
    case sigkill = 9
    case sigusr1 = 10
    case sigsegv = 11
    case sigusr2 = 12
    case sigpipe = 13
    case sigalrm = 14
    case sigterm = 15
    case sigchld = 17
    case sigcont = 18
    case sigstop = 19
    case sigtstp = 20
    case sigttin = 21
    case sigttou = 22
    case sigurg = 23
    case sigxcpu = 24
    case sigxfsz = 25
    case sigvtalrm = 26
    case sigprof = 27
    case sigwinch = 28
    case sigio = 29
    case sigsys = 31
}

/// Linux open(2) 标志位 (与 <asm-generic/fcntl.h> 一致)
public struct OpenFlags: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    // O_RDONLY = 0, 用 [] 表示空 option set
    public static let wronly    = OpenFlags(rawValue: 0o1)
    public static let rdwr      = OpenFlags(rawValue: 0o2)
    public static let creat     = OpenFlags(rawValue: 0o100)
    public static let excl      = OpenFlags(rawValue: 0o200)
    public static let noctty    = OpenFlags(rawValue: 0o400)
    public static let trunc     = OpenFlags(rawValue: 0o1000)
    public static let append    = OpenFlags(rawValue: 0o2000)
    public static let nonblock  = OpenFlags(rawValue: 0o4000)
    public static let directory = OpenFlags(rawValue: 0o200000)
    public static let cloexec   = OpenFlags(rawValue: 0o2000000)
}

/// Linux protection 标志 (mmap)
public struct ProtFlags: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    // PROT_NONE = 0, 用 [] 表示
    public static let read  = ProtFlags(rawValue: 1)
    public static let write = ProtFlags(rawValue: 2)
    public static let exec  = ProtFlags(rawValue: 4)
}

/// Linux mmap 标志
public struct MapFlags: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let shared        = MapFlags(rawValue: 0x01)
    public static let private_      = MapFlags(rawValue: 0x02)
    public static let fixed         = MapFlags(rawValue: 0x10)
    public static let anonymous     = MapFlags(rawValue: 0x20)
    public static let stack         = MapFlags(rawValue: 0x20000)
    public static let hugetlb       = MapFlags(rawValue: 0x40000)
}

/// 文件模式 (权限位)
public struct FileMode: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let setuid = FileMode(rawValue: 0o4000)
    public static let setgid = FileMode(rawValue: 0o2000)
    public static let sticky = FileMode(rawValue: 0o1000)
    public static let rusr   = FileMode(rawValue: 0o400)
    public static let wusr   = FileMode(rawValue: 0o200)
    public static let xusr   = FileMode(rawValue: 0o100)
    public static let rgrp   = FileMode(rawValue: 0o040)
    public static let wgrp   = FileMode(rawValue: 0o020)
    public static let xgrp   = FileMode(rawValue: 0o010)
    public static let roth   = FileMode(rawValue: 0o004)
    public static let woth   = FileMode(rawValue: 0o002)
    public static let xoth   = FileMode(rawValue: 0o001)
}

/// Linux 文件类型 (st_mode 的高 4 位)
public enum FileType: UInt32 {
    case fifo    = 0o010000
    case chr     = 0o020000
    case dir     = 0o040000
    case blk     = 0o060000
    case regular = 0o100000
    case link    = 0o120000
    case sock    = 0o140000
}

/// 系统调用结果: 成功返回值, 失败返回 Errno
public typealias SyscallResult = Result<Int64, Errno>

@inlinable public func okResult(_ v: Int64) -> SyscallResult { .success(v) }
@inlinable public func errResult(_ e: Errno) -> SyscallResult { .failure(e) }
