// TerminalView.swift - isy 终端视图
//
// 渲染策略:
//   - 使用 TerminalBuffer 的网格渲染, 支持 ANSI 颜色/粗体/斜体/下划线
//   - 等宽字体 (SF Mono / Menlo)
//   - 配色: 深色背景, ANSI 16/256 色
//   - 输入区: 透明 TextField 覆盖在光标行, 配合 prompt 显示
//   - 键盘: 支持 Cmd+Up/Down 历史导航, Ctrl+C/D 快捷键
//   - 手势: 长按复制, 双击选词, 三指粘贴
//   - 工具栏: 复制/粘贴/清屏/新建会话

#if canImport(SwiftUI)
import SwiftUI

public struct TerminalView: View {
    @ObservedObject var model: TerminalModel
    @FocusState private var inputFocused: Bool
    @State private var showToolbar: Bool = false
    @State private var selectedText: String = ""
    @State private var showCopyConfirmation: Bool = false

    public init(model: TerminalModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            if showToolbar {
                toolbarView
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.buffer.grid.enumerated()), id: \.offset) { rowIdx, row in
                            attributedRowView(row: row, rowIdx: rowIdx)
                                .id("row-\(rowIdx)")
                        }
                        // 当前输入行
                        HStack(spacing: 0) {
                            Text(model.prompt)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.green)
                            TextField("", text: $model.currentInput)
                                .focused($inputFocused)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onSubmit {
                                    model.submitInput()
                                }
                                .onKeyPress(.upArrow) {
                                    model.navigateHistory(.up)
                                    return .handled
                                }
                                .onKeyPress(.downArrow) {
                                    model.navigateHistory(.down)
                                    return .handled
                                }
                                .onKeyPress(.escape) {
                                    model.currentInput = ""
                                    return .handled
                                }
                                .onKeyPress(characters: CharacterSet(charactersIn: "cC")) { press in
                                    if press.modifiers.contains(.control) {
                                        model.sendInterrupt()
                                        return .handled
                                    }
                                    return .ignored
                                }
                                .onKeyPress(characters: CharacterSet(charactersIn: "dD")) { press in
                                    if press.modifiers.contains(.control) {
                                        model.sendEOF()
                                        return .handled
                                    }
                                    return .ignored
                                }
                        }
                        .id("input-line")
                        .padding(.horizontal, 8)
                    }
                    .padding(.vertical, 8)
                }
                .background(Color.black)
                .onChange(of: model.linesVersion) { _, _ in
                    withAnimation(.easeOut(duration: 0.05)) {
                        proxy.scrollTo("input-line", anchor: .bottom)
                    }
                }
                .onAppear {
                    inputFocused = true
                    proxy.scrollTo("input-line", anchor: .bottom)
                }
                // 手势
                .onTapGesture(count: 2) {
                    // 双击: 显示工具栏
                    withAnimation { showToolbar.toggle() }
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    // 长按: 复制最后一行
                    copyLastLine()
                }
                // 右键菜单 (iPad 外接鼠标)
                .contextMenu {
                    Button {
                        copyLastLine()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                    }
                    Divider()
                    Button {
                        model.clearScreen()
                    } label: {
                        Label("清屏", systemImage: "trash")
                    }
                    Button {
                        model.sendInterrupt()
                    } label: {
                        Label("Ctrl+C", systemImage: "stop.circle")
                    }
                }
            }
        }
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if showCopyConfirmation {
                Text("已复制")
                    .font(.caption)
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(6)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showCopyConfirmation = false }
                        }
                    }
            }
        }
    }

    // MARK: - 工具栏

    private var toolbarView: some View {
        HStack(spacing: 16) {
            Button {
                copyLastLine()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            Button {
                pasteFromClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            Divider().frame(height: 20)
            Button {
                model.clearScreen()
            } label: {
                Image(systemName: "trash")
            }
            Button {
                model.sendInterrupt()
            } label: {
                Image(systemName: "stop.circle")
            }
            Spacer()
            Button {
                withAnimation { showToolbar = false }
            } label: {
                Image(systemName: "xmark.circle")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.12))
        .foregroundColor(.gray)
    }

    // MARK: - 带属性的行渲染

    private func attributedRowView(row: [TerminalCell], rowIdx: Int) -> some View {
        let text = row.map { $0.char }
        if text.allSatisfy({ $0 == " " }) {
            // 空行
            return AnyView(
                Text(" ")
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 18)
            )
        }
        return AnyView(
            HStack(spacing: 0) {
                ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                    Text(String(cell.char))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(cell.attrs.bold ? .bold : .regular)
                        .italic(cell.attrs.italic)
                        .underline(cell.attrs.underline)
                        .strikethrough(cell.attrs.strikethrough)
                        .foregroundColor(cell.attrs.fg)
                        .background(cell.attrs.bg)
                }
            }
            .textSelection(.enabled)
        )
    }

    // MARK: - 复制/粘贴

    private func copyLastLine() {
        let allText = model.buffer.grid.map { row in
            String(row.map { $0.char })
        }.joined(separator: "\n")
        UIPasteboard.general.string = allText
        withAnimation { showCopyConfirmation = true }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string else { return }
        model.currentInput += text
    }
}

// 便捷预览
#Preview {
    TerminalView(model: TerminalModel(demoMode: true))
        .frame(width: 600, height: 400)
}

#endif // canImport(SwiftUI)