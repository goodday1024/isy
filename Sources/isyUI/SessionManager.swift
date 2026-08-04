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

    public init() {
        // 启动时创建第一个会话
        let initial = TerminalModel(demoMode: true)
        sessions.append(initial)
    }

    public var activeSession: TerminalModel? {
        guard sessions.indices.contains(activeIndex) else { return nil }
        return sessions[activeIndex]
    }

    /// 新建会话
    public func newSession() {
        let s = TerminalModel(demoMode: true)
        sessions.append(s)
        activeIndex = sessions.count - 1
    }

    /// 关闭会话
    public func closeSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        sessions.remove(at: index)
        if sessions.isEmpty {
            // 至少保留一个会话
            sessions.append(TerminalModel(demoMode: true))
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
}
#endif // canImport(SwiftUI)
