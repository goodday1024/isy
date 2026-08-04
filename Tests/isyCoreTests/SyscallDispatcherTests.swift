// SyscallDispatcherTests.swift - 验证 syscall 分发逻辑

import XCTest
@testable import isyCore
import isyCHot

final class SyscallDispatcherTests: XCTestCase {

    func testDispatch_unimplementedReturnsENOSYS() {
        let proc = LinuxProcess(pid: 1)
        let disp = SyscallDispatcher(process: proc)
        // 不注册任何 handler, 调用 getpid (172) 应返回 -ENOSYS
        var cpu = isy_cpu_state_t(
            regs: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
            sp: 0, pc: 0, pstate: 0, syscall_nr: 172
        )
        let r = disp.dispatch(nr: 172, cpu: &cpu, args: (0,0,0,0,0,0))
        XCTAssertEqual(r, -38, "未实现 syscall 应返回 -ENOSYS (-38)")
    }

    func testRegisterAndDispatch_getpid() {
        let proc = LinuxProcess(pid: 42)
        let disp = SyscallDispatcher(process: proc)
        disp.registerCoreSyscalls(process: proc)

        var cpu = isy_cpu_state_t(
            regs: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
            sp: 0, pc: 0, pstate: 0, syscall_nr: 172
        )
        let r = disp.dispatch(nr: 172, cpu: &cpu, args: (0,0,0,0,0,0))
        XCTAssertEqual(r, 42, "getpid 应返回进程 pid")
    }

    func testRegisterAndDispatch_getuid() {
        let proc = LinuxProcess(pid: 1)
        let disp = SyscallDispatcher(process: proc)
        disp.registerCoreSyscalls(process: proc)

        var cpu = isy_cpu_state_t(
            regs: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
            sp: 0, pc: 0, pstate: 0, syscall_nr: 174
        )
        let r = disp.dispatch(nr: 174, cpu: &cpu, args: (0,0,0,0,0,0))
        XCTAssertEqual(r, 501, "getuid 应返回 iOS 沙盒 uid 501")
    }

    func testCallCountIncremented() {
        let proc = LinuxProcess(pid: 1)
        let disp = SyscallDispatcher(process: proc)
        disp.registerCoreSyscalls(process: proc)

        var cpu = isy_cpu_state_t(
            regs: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
            sp: 0, pc: 0, pstate: 0, syscall_nr: 172
        )
        _ = disp.dispatch(nr: 172, cpu: &cpu, args: (0,0,0,0,0,0))
        _ = disp.dispatch(nr: 172, cpu: &cpu, args: (0,0,0,0,0,0))
        _ = disp.dispatch(nr: 172, cpu: &cpu, args: (0,0,0,0,0,0))
        XCTAssertEqual(disp.callCounts[172], 3, "getpid 应被调用 3 次")
    }

    func testSyscallName() {
        XCTAssertEqual(SyscallName.name(for: 56), "openat")
        XCTAssertEqual(SyscallName.name(for: 63), "read")
        XCTAssertEqual(SyscallName.name(for: 64), "write")
        XCTAssertEqual(SyscallName.name(for: 999), "syscall_999")
    }

    func testErrnoConversion() {
        XCTAssertEqual(Errno.enosys.asSyscallReturn, -38)
        XCTAssertEqual(Errno.eperm.asSyscallReturn, -1)
        XCTAssertEqual(Errno.enoent.asSyscallReturn, -2)
        XCTAssertEqual(Errno.einval.asSyscallReturn, -22)
    }

    func testErrnoFromHost() {
        XCTAssertEqual(Errno.fromHost(2), .enoent)
        XCTAssertEqual(Errno.fromHost(13), .eacces)
        XCTAssertEqual(Errno.fromHost(9999), .eio)  // 未知映射到 EIO
    }
}
