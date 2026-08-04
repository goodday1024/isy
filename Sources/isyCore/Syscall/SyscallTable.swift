// SyscallTable.swift - Linux ARM64 syscall 号定义
//
// ARM64 Linux 使用 <asm-generic/unistd.h> 的统一 syscall 编号
// (与 x86_64 不同, ARM64 没有 arch-specific syscall 表)
//
// 这里列出 isy 第一版需要支持的核心 syscall 子集. 完整 ~330 个 syscall
// 后续按需添加. 每个新 syscall 都在 SyscallDispatcher 中注册一个 handler.

import Foundation

public enum LinuxSyscall: Int32 {
    // 进程/线程
    case exit = 93
    case exitGroup = 94
    case set_tid_address = 96
    case set_robust_list = 99
    case get_robust_list = 100
    case nanosleep = 101
    case getitimer = 102
    case setitimer = 103
    case kill = 129
    case tkill = 130
    case tgkill = 131
    case sigaltstack = 132
    case rt_sigsuspend = 133
    case rt_sigaction = 134
    case rt_sigprocmask = 135
    case rt_sigpending = 136
    case rt_sigtimedwait = 137
    case rt_sigqueueinfo = 138
    case rt_sigreturn = 139
    case setpriority = 140
    case getpriority = 141
    case restart_syscall = 128
    case sched_yield = 124

    case clone = 220
    case execve = 221
    case wait4 = 260

    // 内存
    case brk = 214
    case munmap = 215
    case mmap = 222
    case mprotect = 226
    case mremap = 216
    case ftruncate = 46
    case mincore = 232
    case madvise = 233

    // 文件系统
    case openat = 56
    case close = 57
    case read = 63
    case write = 64
    case readv = 65
    case writev = 66
    case pread64 = 67
    case pwrite64 = 68
    case preadv = 69
    case pwritev = 70
    case lseek = 62
    case fstat = 80
    case newfstatat = 79
    case statfs = 43
    case fstatfs = 44
    case fcntl = 25
    case ioctl = 29
    case fsync = 82
    case fdatasync = 83
    case getdents64 = 61
    case readlinkat = 78
    case faccessat = 48
    case faccessat2 = 439
    case linkat = 37
    case unlinkat = 35
    case symlinkat = 36
    case renameat = 38
    case mkdirat = 34
    case fchmodat = 53
    case fchmod = 52
    case fchownat = 54
    case fchown = 55
    case umask = 166
    case mount = 165
    case umount2 = 39
    case getcwd = 17
    case chdir = 49
    case fchdir = 50

    // 网络
    case socket = 198
    case socketpair = 199
    case bind = 200
    case listen = 201
    case accept = 202
    case connect = 203
    case getsockname = 204
    case getpeername = 205
    case sendto = 206
    case recvfrom = 207
    case setsockopt = 208
    case getsockopt = 209
    case shutdown = 210
    case sendmsg = 211
    case recvmsg = 212

    // 时间
    case clock_gettime = 113
    case clock_nanosleep = 115
    case clock_getres = 114
    case gettimeofday = 169
    case settimeofday = 170
    case time = 106

    // IPC
    case pipe2 = 59
    case eventfd2 = 19
    case signalfd4 = 74
    case timerfd_create = 85
    case timerfd_settime = 86
    case timerfd_gettime = 87
    case epoll_create1 = 20
    case epoll_ctl = 21
    case epoll_pwait = 22
    case poll = 73
    case ppoll = 168
    case pselect6 = 72

    // 用户/组
    case getuid = 174
    case geteuid = 175
    case getgid = 176
    case getegid = 177
    case getpid = 172
    case getppid = 173
    case gettid = 178
    case getpgrp = 155
    case setsid = 157
    case setuid = 146
    case setgid = 144
    case setreuid = 145
    case setregid = 143

    // 杂项
    case uname = 160
    case getrandom = 278
    case sysinfo = 179
    case futex = 98

    /// syscall 名字 (调试用)
    public var name: String { String(describing: self) }
}

/// Linux ARM64 通用 syscall 号表 (完整版, 用于未实现 syscall 的诊断)
public enum SyscallName {
    public static let names: [Int32: String] = [
        0: "io_setup", 1: "io_destroy", 2: "open_tree", 3: "move_mount",
        4: "fsopen", 5: "fspick", 6: "fsconfig", 7: "fsmount",
        56: "openat", 57: "close", 62: "lseek", 63: "read", 64: "write",
        93: "exit", 94: "exit_group", 96: "set_tid_address", 98: "futex",
        113: "clock_gettime", 114: "clock_getres", 115: "clock_nanosleep",
        160: "uname", 161: "sethostname", 169: "gettimeofday",
        172: "getpid", 173: "getppid", 174: "getuid", 175: "geteuid",
        176: "getgid", 177: "getegid", 178: "gettid", 198: "socket",
        199: "socketpair", 200: "bind", 201: "listen", 202: "accept",
        203: "connect", 206: "sendto", 207: "recvfrom", 208: "setsockopt",
        209: "getsockopt", 210: "shutdown", 211: "sendmsg", 212: "recvmsg",
        215: "munmap", 220: "clone", 221: "execve", 222: "mmap",
        226: "mprotect", 260: "wait4", 278: "getrandom",
    ]

    public static func name(for nr: Int32) -> String {
        names[nr] ?? "syscall_\(nr)"
    }
}
