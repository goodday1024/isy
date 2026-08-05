// SessionManager.swift - isy 终端会话管理
//
// 管理多个终端会话 (tab), 每个会话对应一个 TerminalModel.
// 在真实模式下, 每个会话对应一个 LinuxProcess (通过 fork/clone 派生).

#if canImport(SwiftUI)
import SwiftUI
import isyCore

@MainActor
public final class SessionManager: ObservableObject {
    @Published public var sessions: [TerminalModel] = []
    @Published public var activeIndex: Int = 0

    /// 全局 RootFS (所有会话共享)
    public var rootfs: RootFS?

    public init() {
        // 初始化 RootFS
        rootfs = RootFS()
        try? rootfs?.mount()

        // 启动时创建第一个会话 (真实模式)
        let initial = TerminalModel(demoMode: false, rootfs: rootfs)
        sessions.append(initial)
        bootRealMode(session: initial)
    }

    public var activeSession: TerminalModel? {
        guard sessions.indices.contains(activeIndex) else { return nil }
        return sessions[activeIndex]
    }

    /// 新建会话
    public func newSession() {
        let s = TerminalModel(demoMode: false, rootfs: rootfs)
        sessions.append(s)
        activeIndex = sessions.count - 1
        bootRealMode(session: s)
    }

    /// 关闭会话
    public func closeSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        sessions.remove(at: index)
        if sessions.isEmpty {
            let s = TerminalModel(demoMode: false, rootfs: rootfs)
            sessions.append(s)
            bootRealMode(session: s)
        }
        if activeIndex >= sessions.count {
            activeIndex = sessions.count - 1
        }
    }

    /// 切换会话
    public func switchTo(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        activeIndex = index
    }

    /// 启动真实模式: 加载 busybox 并执行 sh
    private func bootRealMode(session: TerminalModel) {
        guard let rfs = rootfs else {
            session.appendOutput("\u{1B}[31m错误: RootFS 未初始化\u{1B}[0m\n")
            return
        }

        // 查找 busybox 二进制
        guard let busyboxData = loadBusybox() else {
            // 找不到 busybox, 回退到 demo 模式
            session.demoMode = true
            session.builtinShell = BuiltinShell(rootfs: rfs)
            session.appendOutput("\u{1B}[33m未找到 busybox, 进入内置 Shell 模式\u{1B}[0m\n")
            session.prompt = "isy$ "
            return
        }

        // 创建 ProcessManager 并连接
        let pm = ProcessManager()
        session.connect(to: pm)

        // 启动 busybox sh
        let envp = [
            "PATH=/bin:/sbin:/usr/bin:/usr/local/bin",
            "HOME=/root",
            "TERM=xterm-256color",
            "SHELL=/bin/sh",
            "USER=root",
            "LANG=C.UTF-8",
            "PS1=\\w # "
        ]
        pm.start(
            elfData: busyboxData,
            argv: ["/bin/sh"],
            envp: envp,
            rootfs: rfs
        )
    }

    /// 查找 busybox 二进制
    private func loadBusybox() -> Data? {
        #if canImport(Darwin) && !os(Linux)
        // 从 App bundle 查找
        if let url = Bundle.main.url(forResource: "busybox", withExtension: nil) {
            return try? Data(contentsOf: url)
        }
        if let url = Bundle.main.url(forResource: "busybox", withExtension: "elf") {
            return try? Data(contentsOf: url)
        }
        #endif

        // 从沙盒目录查找
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let candidates = [
            caches + "/isy/busybox",
            caches + "/isy/rootfs/bin/busybox",
            docs + "/busybox",
            docs + "/rootfs/bin/busybox"
        ]
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) {
                return try? Data(contentsOf: URL(fileURLWithPath: p))
            }
        }
        return nil
    }
}
#endif // canImport(SwiftUI)
