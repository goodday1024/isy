// TerminalView.swift - isy 终端视图
//
// 渲染策略:
//   - ScrollView + LazyVStack 渲染所有行 (虚拟化, 大量行也不卡)
//   - 用等宽字体 (SF Mono / Menlo)
//   - 配色: 深色背景 (ANSI 终端风格), 不同样式用不同前景色
//   - 输入区: 透明 TextField 覆盖在最后一行, 配合 prompt 显示
//   - 键盘: 支持 Cmd+Up/Down 历史导航 (iPad 外接键盘)

#if canImport(SwiftUI)
import SwiftUI

public struct TerminalView: View {
    @ObservedObject var model: TerminalModel
    @FocusState private var inputFocused: Bool

    public init(model: TerminalModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.lines) { line in
                            lineView(line)
                                .id(line.id)
                        }
                        // 当前输入行
                        HStack(spacing: 0) {
                            Text(model.prompt)
                                .foregroundColor(.green)
                            TextField("", text: $model.currentInput)
                                .focused($inputFocused)
                                .textFieldStyle(.plain)
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
                        }
                        .id("input-line")
                    }
                    .padding(8)
                }
                .background(Color.black)
                .onChange(of: model.lines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.05)) {
                        proxy.scrollTo("input-line", anchor: .bottom)
                    }
                }
                .onAppear {
                    inputFocused = true
                }
            }
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func lineView(_ line: TerminalLine) -> some View {
        Text(line.text)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(colorForStyle(line.style))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func colorForStyle(_ style: TerminalLineStyle) -> Color {
        switch style {
        case .normal:  return .white
        case .prompt:  return .green
        case .output:  return Color(white: 0.85)
        case .title:   return .cyan
        case .dim:     return Color(white: 0.5)
        case .error:   return .red
        case .success: return .green
        }
    }
}

// 便捷预览
#Preview {
    TerminalView(model: TerminalModel(demoMode: true))
        .frame(width: 600, height: 400)
}

#endif // canImport(SwiftUI)
