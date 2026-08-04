// ProcessManagerTests.swift - 验证进程管理功能

import XCTest
@testable import isyCore
import Foundation

/// 线程安全的事件收集器
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ProcessEvent] = []

    var events: [ProcessEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func append(_ event: ProcessEvent) {
        lock.lock()
        defer { lock.unlock() }
        _events.append(event)
    }
}

final class ProcessManagerTests: XCTestCase {

    var pm: ProcessManager!

    override func setUp() {
        super.setUp()
        pm = ProcessManager()
    }

    override func tearDown() {
        pm = nil
        super.tearDown()
    }

    // MARK: - 初始状态

    func testInitialState() {
        XCTAssertEqual(pm.state, .idle)
        XCTAssertNil(pm.process)
        XCTAssertNil(pm.emulator)
    }

    func testChildProcessesEmpty() {
        XCTAssertTrue(pm.childProcesses.isEmpty)
    }

    // MARK: - 子进程管理

    func testForkChild() {
        let child = pm.forkChild()
        XCTAssertNotNil(child)
        XCTAssertEqual(pm.childProcesses.count, 1)
    }

    func testWaitForChild() {
        let child = pm.forkChild()
        // 创建模拟进程
        let proc = LinuxProcess(pid: 2, parentPid: 1)
        proc.exited = true
        proc.exitCode = 42
        child.process = proc
        child.emulator = nil

        let code = pm.waitForChild(pid: 2)
        XCTAssertEqual(code, 42)
    }

    func testWaitForChildNotFound() {
        let code = pm.waitForChild(pid: 99)
        XCTAssertNil(code)
    }

    // MARK: - 信号发送

    func testSendSignal() {
        let proc = LinuxProcess(pid: 1)
        pm.process = proc
        pm.sendSignal(Signal.sigint.rawValue)
        XCTAssertEqual(proc.pendingSignal, Signal.sigint.rawValue)
    }

    func testSendInterrupt() {
        let proc = LinuxProcess(pid: 1)
        pm.process = proc
        pm.sendInterrupt()
        XCTAssertEqual(proc.pendingSignal, Signal.sigint.rawValue)
    }

    func testSendTerminate() {
        let proc = LinuxProcess(pid: 1)
        pm.process = proc
        pm.sendTerminate()
        XCTAssertEqual(proc.pendingSignal, Signal.sigterm.rawValue)
    }

    func testSendKill() {
        let proc = LinuxProcess(pid: 1)
        pm.process = proc
        pm.sendKill()
        XCTAssertEqual(proc.pendingSignal, Signal.sigkill.rawValue)
    }

    // MARK: - 窗口大小变更

    func testSendWindowChange() {
        let proc = LinuxProcess(pid: 1)
        pm.process = proc
        pm.sendWindowChange(rows: 40, cols: 120)
        XCTAssertEqual(proc.terminalRows, 40)
        XCTAssertEqual(proc.terminalCols, 120)
        XCTAssertEqual(proc.pendingSignal, Signal.sigwinch.rawValue)
    }

    // MARK: - 事件回调

    func testEventHandler() {
        let events = EventCollector()
        pm.eventHandler = { @Sendable event in
            events.append(event)
        }
        pm.sendSignal(Signal.sigint.rawValue)
        // 等待主线程处理
        let expectation = self.expectation(description: "event delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let captured = events.events
            XCTAssertTrue(captured.contains(where: {
                if case .signalDelivered(let sig) = $0 { return sig == Signal.sigint.rawValue }
                return false
            }))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - 状态检查

    func testStateValues() {
        // 验证所有 ProcessState 枚举值
        let states: [ProcessState] = [.idle, .loading, .running, .exited(code: 0), .exited(code: 1), .failed("test")]
        for state in states {
            switch state {
            case .idle: XCTAssertEqual(state, .idle)
            case .loading: XCTAssertEqual(state, .loading)
            case .running: XCTAssertEqual(state, .running)
            case .exited(let code): XCTAssertTrue(code >= -1)
            case .failed: XCTAssertTrue(true)
            }
        }
    }

    func testStateEquality() {
        XCTAssertEqual(ProcessState.idle, ProcessState.idle)
        XCTAssertEqual(ProcessState.exited(code: 42), ProcessState.exited(code: 42))
        XCTAssertNotEqual(ProcessState.exited(code: 0), ProcessState.exited(code: 1))
    }
}