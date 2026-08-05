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
    @State private var availableWidth: CGFloat = 0

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

    /// 等宽字体单字符宽度 (近似值, SF Mono 约为字号的 0.6 倍)
    private var charWidth: CGFloat {
        fontSize * 0.6
    }

    /// 根据屏幕实际宽度和字号计算列数
    private var dynamicCols: Int {
        let padding: CGFloat = 16  // 左右各 8pt
        let usable = max(availableWidth - padding, 100)
        return max(20, Int(usable / charWidth))
    }

    /// 只渲染有内容的行 + 光标行, 跳过尾部空行
    private var visibleRows: [([TerminalCell], Int)] {
        let grid = model.buffer.grid
        // 找到最后一个有内容的行
        var lastNonEmpty = -1
        for (i, row) in grid.enumerated() {
            if !row.allSatisfy({ $0.char == " " }) {
                lastNonEmpty = i
            }
        }
        // 渲染 0...lastNonEmpty 行 (至少渲染 0 行, 即输入行紧跟在 banner 后)
        let endIdx = max(lastNonEmpty + 1, 0)
        return (0..<endIdx).map { i in (grid[i], i) }
    }

    public var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // 工具栏
                if showToolbar {
                    toolbarView
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // 只渲染有内容的行
                            ForEach(visibleRows, id: \.1) { row, rowIdx in
                                rowView(row: row)
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
                            .frame(minHeight: lineHeight)
                        }
                        .padding(.vertical, 4)
                    }
                    .background(Color.black)
                    // 点击空白区域时重新聚焦 TextField (保持键盘)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        inputFocused = true
                    }
                    .onChange(of: model.linesVersion) { _, _ in
                        withAnimation(.easeOut(duration: 0.05)) {
                            proxy.scrollTo("input-line", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        availableWidth = geometry.size.width
                        // 延迟聚焦, 等布局完成
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            inputFocused = true
                            proxy.scrollTo("input-line", anchor: .bottom)
                        }
                    }
                    .onChange(of: geometry.size.width) { _, newWidth in
                        availableWidth = newWidth
                    }
                    // 双击显示工具栏 (用 simultaneousGesture 避免干扰 TextField)
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded {
                                withAnimation { showToolbar.toggle() }
                            }
                    )
                    // 长按复制
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.8)
                            .onEnded { _ in
                                copyLastLine()
                            }
                    )
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
            .onAppear {
                availableWidth = geometry.size.width
                model.buffer.resize(cols: dynamicCols, rows: model.buffer.rows)
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                availableWidth = newWidth
                model.buffer.resize(cols: dynamicCols, rows: model.buffer.rows)
            }
            .onChange(of: fontSize) { _, _ in
                model.buffer.resize(cols: dynamicCols, rows: model.buffer.rows)
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
    private func rowView(row: [TerminalCell]) -> some View {
        if row.allSatisfy({ $0.char == " " }) {
            // 空行: 占位
            Color.clear
                .frame(height: lineHeight)
                .padding(.horizontal, 8)
        } else {
            Text(buildAttributedLine(from: row))
                .font(terminalFont)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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

            // 粗体 + 斜体: 通过 font 设置
            if cell.attrs.bold || cell.attrs.italic {
                var font = Font.system(
                    size: fontSize,
                    weight: cell.attrs.bold ? .bold : .regular,
                    design: .monospaced
                )
                if cell.attrs.italic {
                    font = font.italic()
                }
                ch.font = font
            }

            // 下划线
            if cell.attrs.underline {
                ch.underlineStyle = Text.LineStyle(pattern: .solid)
            }

            // 删除线
            if cell.attrs.strikethrough {
                ch.strikethroughStyle = Text.LineStyle(pattern: .solid)
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
