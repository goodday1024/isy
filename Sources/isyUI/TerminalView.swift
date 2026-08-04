// TerminalView.swift - isy 终端视图
//
// 渲染策略:
//   - 使用 TerminalBuffer 的网格渲染, 支持 ANSI 颜色/粗体/斜体/下划线
//   - 等宽字体 (SF Mono), 动态字号 (由设置页控制)
//   - 整行 AttributedString 渲染 (而非逐字符 Text, 大幅提升性能)
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
    @State private var showCopyConfirmation: Bool = false

    public var fontSize: CGFloat

    public init(model: TerminalModel, fontSize: CGFloat = 14) {
        self.model = model
        self.fontSize = fontSize
    }

    private var terminalFont: Font {
        .system(size: fontSize, weight: .regular, design: .monospaced)
    }

    private var lineHeight: CGFloat {
        fontSize * 1.35
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
                            rowView(row: row, rowIdx: rowIdx)
                                .id("row-\(rowIdx)")
                        }
                        // 当前输入行
                        HStack(spacing: 0) {
                            Text(model.prompt)
                                .font(terminalFont)
                                .foregroundColor(.green)
                            TextField("", text: $model.currentInput)
                                .focused($inputFocused)
                                .textFieldStyle(.plain)
                                .font(terminalFont)
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
                        .frame(height: lineHeight)
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

    // MARK: - 整行渲染 (AttributedString)

    @ViewBuilder
    private func rowView(row: [TerminalCell], rowIdx: Int) -> some View {
        let attributed = buildAttributedLine(from: row)
        if attributed.string.allSatisfy({ $0 == " " || $0 == "\0" }) {
            // 空行: 占位
            Color.clear
                .frame(height: lineHeight)
                .padding(.horizontal, 8)
        } else {
            Text(attributed)
                .font(terminalFont)
                .frame(height: lineHeight)
                .padding(.horizontal, 8)
                .textSelection(.enabled)
        }
    }

    /// 将一行 TerminalCell 转换为 AttributedString
    private func buildAttributedLine(from row: [TerminalCell]) -> AttributedString {
        // 找到最后一个非空格字符, 截断尾部空格
        var lastNonSpace = -1
        for (i, cell) in row.enumerated() where cell.char != " " {
            lastNonSpace = i
        }
        let endIdx = max(lastNonSpace + 1, 1)

        var result = AttributedString()
        for i in 0..<endIdx {
            let cell = row[i]
            var ch = AttributedString(String(cell.char))

            // 前景色
            if cell.attrs.inverse {
                ch.foregroundColor = cell.attrs.bg == .clear ? Color.black : cell.attrs.bg
                ch.backgroundColor = cell.attrs.fg
            } else {
                ch.foregroundColor = cell.attrs.fg
                if cell.attrs.bg != .clear {
                    ch.backgroundColor = cell.attrs.bg
                }
            }

            // 粗体
            if cell.attrs.bold {
                ch.font = .system(size: fontSize, weight: .bold, design: .monospaced)
            }
            // 斜体
            if cell.attrs.italic {
                ch.inlinePresentationIntent = .italic
            }
            // 下划线
            if cell.attrs.underline {
                ch.inlinePresentationIntent = (ch.inlinePresentationIntent ?? []).union(.lineThrough)
            }

            result += ch
        }
        return result
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
