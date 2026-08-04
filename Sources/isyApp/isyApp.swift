// isyApp.swift - isy iOS App 入口
//
// 这是 iOS App 的主入口. 用法:
//   1. 在 Xcode 中新建 iOS App 项目 (SwiftUI, iOS 17+)
//   2. 把本文件拖入项目 (或引用 isy SPM package)
//   3. 把 isyCore + isyCHot + isyUI 作为依赖添加
//   4. Run on device
//
// 真实模式集成 (需要 rootfs):
//   1. 在 App bundle 中打包 Alpine/Debian ARM64 rootfs (squashfs)
//   2. 启动时挂载到沙盒目录
//   3. 加载 /bin/sh ELF 到 isyCore Emulator
//   4. 把 TerminalModel.connect(to: process) 接上
//   5. 调用 Emulator.run() 在后台线程执行

#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import isyUI
import isyCore

@main
struct isyApp: App {
    @StateObject private var sessionManager = SessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let session = sessionManager.activeSession {
                    TerminalView(model: session)
                }
            }
            .navigationTitle("isy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        sessionManager.newSession()
                    } label: {
                        Image(systemName: "plus")
                    }
                    Menu {
                        ForEach(sessionManager.sessions.indices, id: \.self) { i in
                            Button {
                                sessionManager.switchTo(i)
                            } label: {
                                Label("Session \(i + 1)", systemImage: i == sessionManager.activeIndex ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            sessionManager.closeSession(at: sessionManager.activeIndex)
                        } label: {
                            Label("Close", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
        }
    }
}
#endif // canImport(SwiftUI) && os(iOS)
