// isyApp.swift - isy iOS App 入口
//
// 用法:
//   1. 在 Xcode 中新建 iOS App 项目 (SwiftUI, iOS 17+)
//   2. 把 isy SPM package 添加为依赖
//   3. Run on device
//
// 真实模式集成:
//   1. 首次启动时自动创建最小 rootfs (busybox 兼容)
//   2. 在 App bundle 中可选打包 ARM64 Linux rootfs (Alpine/Debian)
//   3. 加载 /bin/sh 或 busybox ELF 到 isyCore Emulator
//   4. ProcessManager 在后台线程调用 Emulator.run()

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
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var showKeyboardBar = true
    @State private var fontSize: CGFloat = 14
    @State private var terminalRows: Int = 24
    @State private var terminalCols: Int = 80

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let session = sessionManager.activeSession {
                    TerminalView(model: session, fontSize: fontSize)
                        .overlay(alignment: .topTrailing) {
                            if !session.demoMode {
                                statusBadge(session: session)
                            }
                        }
                }

                // 键盘辅助工具栏
                if showKeyboardBar {
                    keyboardToolbar
                }
            }
            .navigationTitle("isy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    // 新建会话
                    Button {
                        sessionManager.newSession()
                    } label: {
                        Image(systemName: "plus")
                    }

                    // 重启会话
                    if let session = sessionManager.activeSession {
                        Button {
                            sessionManager.newSession()
                        } label: {
                            Image(systemName: "arrow.clockwise.circle")
                        }
                    }

                    // 会话切换
                    Menu {
                        ForEach(sessionManager.sessions.indices, id: \.self) { i in
                            Button {
                                sessionManager.switchTo(i)
                            } label: {
                                Label(
                                    "Session \(i + 1)\(sessionManager.sessions[i].demoMode ? " (内置)" : " (真实)")",
                                    systemImage: i == sessionManager.activeIndex ? "checkmark.circle.fill" : "circle"
                                )
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            sessionManager.closeSession(at: sessionManager.activeIndex)
                        } label: {
                            Label("关闭会话", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }

                    // 关于
                    Button {
                        showAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    fontSize: $fontSize,
                    showKeyboardBar: $showKeyboardBar,
                    terminalRows: $terminalRows,
                    terminalCols: $terminalCols
                )
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
        }
    }

    private func statusBadge(session: TerminalModel) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(session.processState)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(4)
    }

    // MARK: - 键盘辅助工具栏

    private var keyboardToolbar: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color(white: 0.3))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    KeyboardButton("Tab") { sendKey("\t") }
                    KeyboardButton("Esc") { sendKey("\u{1B}") }
                    KeyboardButton("Ctrl") { /* modifier */ }
                    KeyboardButton("↑") { navigateHistory(.up) }
                    KeyboardButton("↓") { navigateHistory(.down) }
                    KeyboardButton("←") { sendKey("\u{1B}[D") }
                    KeyboardButton("→") { sendKey("\u{1B}[C") }
                    KeyboardButton("|") { insertText("|") }
                    KeyboardButton(">") { insertText(">") }
                    KeyboardButton("<") { insertText("<") }
                    KeyboardButton("&") { insertText("&") }
                    KeyboardButton(";") { insertText(";") }
                    KeyboardButton("/") { insertText("/") }
                    KeyboardButton("$") { insertText("$") }
                    KeyboardButton("-") { insertText("-") }
                    Spacer().frame(width: 8)
                    KeyboardButton("Home", color: .orange) { sendKey("\u{1B}[H") }
                    KeyboardButton("End", color: .orange) { sendKey("\u{1B}[F") }
                    KeyboardButton("PgUp", color: .orange) { sendKey("\u{1B}[5~") }
                    KeyboardButton("PgDn", color: .orange) { sendKey("\u{1B}[6~") }
                    Spacer().frame(width: 8)
                    KeyboardButton("C", color: .red) { sendInterrupt() }
                    KeyboardButton("D", color: .red) { sendEOF() }
                    KeyboardButton("Clear", color: .gray) { clearScreen() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(Color(white: 0.08))
        }
        .frame(height: 44)
    }

    private func sendKey(_ key: String) {
        sessionManager.activeSession?.sendSpecialChar(key)
    }

    private func insertText(_ text: String) {
        sessionManager.activeSession?.insertText(text)
    }

    private func navigateHistory(_ direction: HistoryDirection) {
        sessionManager.activeSession?.navigateHistory(direction)
    }

    private func sendInterrupt() {
        sessionManager.activeSession?.sendInterrupt()
    }

    private func sendEOF() {
        sessionManager.activeSession?.sendEOF()
    }

    private func clearScreen() {
        sessionManager.activeSession?.clearScreen()
    }
}

// MARK: - 键盘按钮

struct KeyboardButton: View {
    let label: String
    let color: Color
    let action: () -> Void

    init(_ label: String, color: Color = .white, action: @escaping () -> Void) {
        self.label = label
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(white: 0.2))
                .cornerRadius(4)
        }
    }
}

// MARK: - 设置页面

struct SettingsView: View {
    @Binding var fontSize: CGFloat
    @Binding var showKeyboardBar: Bool
    @Binding var terminalRows: Int
    @Binding var terminalCols: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("终端外观") {
                    HStack {
                        Text("字号")
                        Slider(value: $fontSize, in: 10...24, step: 1) {
                            Text("字号")
                        }
                        Text("\(Int(fontSize))pt")
                            .foregroundColor(.gray)
                            .frame(width: 40)
                    }

                    HStack {
                        Text("列数")
                        Picker("", selection: $terminalCols) {
                            Text("60").tag(60)
                            Text("80").tag(80)
                            Text("100").tag(100)
                            Text("120").tag(120)
                        }
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Text("行数")
                        Picker("", selection: $terminalRows) {
                            Text("20").tag(20)
                            Text("24").tag(24)
                            Text("30").tag(30)
                            Text("40").tag(40)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("键盘") {
                    Toggle("显示键盘辅助工具栏", isOn: $showKeyboardBar)
                }

                Section("关于 isy") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("0.1.0-dev")
                            .foregroundColor(.gray)
                    }
                    HStack {
                        Text("架构")
                        Spacer()
                        Text("ARM64")
                            .foregroundColor(.gray)
                    }
                    HStack {
                        Text("构建")
                        Spacer()
                        Text("Swift Package Manager")
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 关于页面

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 图标
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(LinearGradient(
                                colors: [Color.cyan, Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 80, height: 80)
                        Text("isy")
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.top, 30)

                    Text("isy")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("iOS System")
                        .font(.title3)
                        .foregroundColor(.cyan)

                    Text("v0.1.0-dev")
                        .font(.caption)
                        .foregroundColor(.gray)

                    Divider()
                        .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 12) {
                        infoRow("核心创新", "load-time binary patching\nSVC #0 → BL __isy_syscall_trap")
                        infoRow("执行模型", "99.99% 指令原生执行\n仅 syscall 边界陷入翻译层")
                        infoRow("合规性", "W^X 内存模型\n非 JIT, 符合 App Store 规则")
                        infoRow("性能", "patch 吞吐 ~300 MB/s\nsyscall 开销 < 内核切换")
                        infoRow("内置 Shell", "30+ 命令\n管道/重定向/通配符")
                        infoRow("平台", "iOS 17+ / macOS 13+")
                        infoRow("语言", "Swift 6 + C (ARM64 asm)")
                    }
                    .padding(.horizontal)

                    Divider()
                        .padding(.horizontal)

                    VStack(spacing: 8) {
                        Text("基于开源项目创新")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("算法优化 + 硬件加速\n不违反 Apple 相关规定")
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundColor(.cyan)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.white)
        }
    }
}
#endif // canImport(SwiftUI) && os(iOS)