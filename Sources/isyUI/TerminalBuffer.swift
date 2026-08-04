// TerminalBuffer.swift - isy 终端缓冲与 ANSI 解析器
//
// 完整 VT100/xterm 兼容终端模拟器:
//   1. 字符网格 (rows × cols)
//   2. ANSI 转义序列解析 (状态机)
//   3. 光标管理 (移动/保存/恢复)
//   4. 回滚缓冲 (scrollback)
//   5. SGR 属性 (颜色/粗体/斜体/下划线)
//   6. 清除屏幕/行
//   7. 滚动区域
//   8. 制表符

#if canImport(SwiftUI)
import Foundation
import SwiftUI

// MARK: - SGR 属性

public struct TerminalCellAttrs: Hashable, Sendable {
    public var fg: Color = .white
    public var bg: Color = .clear
    public var bold: Bool = false
    public var italic: Bool = false
    public var underline: Bool = false
    public var strikethrough: Bool = false
    public var blink: Bool = false
    public var inverse: Bool = false
    public var dim: Bool = false

    public static let `default` = TerminalCellAttrs()
}

// MARK: - 终端字符单元

public struct TerminalCell: Hashable, Sendable {
    public var char: Character
    public var attrs: TerminalCellAttrs

    public init(char: Character = " ", attrs: TerminalCellAttrs = .default) {
        self.char = char
        self.attrs = attrs
    }
}

// MARK: - 终端缓冲

public final class TerminalBuffer {
    /// 列数
    public var cols: Int
    /// 行数
    public var rows: Int
    /// 网格: [row][col]
    public private(set) var grid: [[TerminalCell]]
    /// 当前光标行 (0-based)
    public var cursorRow: Int = 0
    /// 当前光标列 (0-based)
    public var cursorCol: Int = 0
    /// 当前属性
    public var currentAttrs: TerminalCellAttrs = .default
    /// 光标是否可见
    public var cursorVisible: Bool = true
    /// 是否自动换行
    public var autoWrap: Bool = true
    /// 滚动区域 (顶部/底部, 0-based, inclusive)
    public var scrollTop: Int = 0
    public var scrollBottom: Int = 0

    /// 回滚缓冲
    public var scrollback: [[TerminalCell]] = []
    public var scrollbackLimit: Int = 10000

    /// 输出回调 (每行完成时通知)
    public var onLineOutput: ((String) -> Void)?

    /// 保存的光标状态
    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0
    private var savedAttrs: TerminalCellAttrs = .default

    public init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        self.scrollBottom = rows - 1
        self.grid = Array(repeating: Array(repeating: TerminalCell(), count: cols), count: rows)
    }

    /// 调整终端大小
    public func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.scrollBottom = rows - 1
        let newGrid = Array(repeating: Array(repeating: TerminalCell(), count: cols), count: rows)
        for r in 0..<min(rows, grid.count) {
            for c in 0..<min(cols, grid[r].count) {
                newGrid[r][c] = grid[r][c]
            }
        }
        grid = newGrid
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
    }

    /// 获取可见行 (用于渲染)
    public func visibleLines() -> [TerminalLine] {
        grid.map { row in
            TerminalLine(text: String(row.map { $0.char }), style: .normal)
        }
    }

    /// 获取带样式的行 (用于 AttributedString 渲染)
    public func attributedLines() -> [[AttributedCharacter]] {
        grid.map { row in
            row.map { cell in
                AttributedCharacter(char: cell.char, attrs: cell.attrs)
            }
        }
    }

    // MARK: - 写入字符

    /// 写入一段文本 (可能包含 ANSI 转义序列)
    public func write(_ text: String) {
        var parser = ANSIParser(buffer: self)
        for ch in text {
            parser.feed(ch)
        }
        parser.flush()
    }

    /// 写入单个普通字符
    func putChar(_ ch: Character) {
        if ch == "\n" {
            newline()
            return
        }
        if ch == "\r" {
            cursorCol = 0
            return
        }
        if ch == "\t" {
            cursorCol = ((cursorCol / 8) + 1) * 8
            if cursorCol >= cols {
                cursorCol = cols - 1
            }
            return
        }
        if ch == "\u{7}" {  // BEL - 响铃, 忽略
            return
        }
        if ch == "\u{8}" {  // BS - 退格
            if cursorCol > 0 { cursorCol -= 1 }
            return
        }

        // 自动换行
        if cursorCol >= cols {
            if autoWrap {
                newline()
                cursorCol = 0
            } else {
                cursorCol = cols - 1
            }
        }

        grid[cursorRow][cursorCol] = TerminalCell(char: ch, attrs: currentAttrs)
        cursorCol += 1
    }

    func newline() {
        if cursorRow >= scrollBottom {
            scrollUp()
        } else {
            cursorRow += 1
        }
    }

    // MARK: - 光标控制

    func cursorUp(_ n: Int) {
        let count = max(1, n)
        cursorRow = max(scrollTop, cursorRow - count)
    }

    func cursorDown(_ n: Int) {
        let count = max(1, n)
        cursorRow = min(scrollBottom, cursorRow + count)
    }

    func cursorForward(_ n: Int) {
        let count = max(1, n)
        cursorCol = min(cols - 1, cursorCol + count)
    }

    func cursorBackward(_ n: Int) {
        let count = max(1, n)
        cursorCol = max(0, cursorCol - count)
    }

    func cursorPosition(row: Int, col: Int) {
        cursorRow = min(max(1, row), rows) - 1
        cursorCol = min(max(1, col), cols) - 1
    }

    func cursorNextLine(_ n: Int) {
        cursorCol = 0
        cursorDown(n)
    }

    func cursorPrevLine(_ n: Int) {
        cursorCol = 0
        cursorUp(n)
    }

    func cursorHorizontalAbsolute(_ n: Int) {
        cursorCol = min(max(1, n), cols) - 1
    }

    func saveCursor() {
        savedCursorRow = cursorRow
        savedCursorCol = cursorCol
        savedAttrs = currentAttrs
    }

    func restoreCursor() {
        cursorRow = savedCursorRow
        cursorCol = savedCursorCol
        currentAttrs = savedAttrs
    }

    // MARK: - 清除

    func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:  // 光标到屏幕末尾
            for c in cursorCol..<cols { grid[cursorRow][c] = TerminalCell() }
            for r in (cursorRow + 1)..<rows {
                for c in 0..<cols { grid[r][c] = TerminalCell() }
            }
        case 1:  // 屏幕开头到光标
            for r in 0..<cursorRow {
                for c in 0..<cols { grid[r][c] = TerminalCell() }
            }
            for c in 0...cursorCol { grid[cursorRow][c] = TerminalCell() }
        case 2, 3:  // 整个屏幕
            for r in 0..<rows {
                for c in 0..<cols { grid[r][c] = TerminalCell() }
            }
            cursorRow = 0
            cursorCol = 0
        default: break
        }
    }

    func eraseLine(_ mode: Int) {
        switch mode {
        case 0:  // 光标到行尾
            for c in cursorCol..<cols { grid[cursorRow][c] = TerminalCell() }
        case 1:  // 行首到光标
            for c in 0...cursorCol { grid[cursorRow][c] = TerminalCell() }
        case 2:  // 整行
            for c in 0..<cols { grid[cursorRow][c] = TerminalCell() }
        default: break
        }
    }

    func eraseChars(_ n: Int) {
        let count = max(1, n)
        for c in cursorCol..<min(cursorCol + count, cols) {
            grid[cursorRow][c] = TerminalCell()
        }
    }

    // MARK: - 滚动

    func scrollUp(_ n: Int = 1) {
        let count = min(n, scrollBottom - scrollTop + 1)
        let region = scrollTop...scrollBottom
        // 保存到回滚缓冲
        for _ in 0..<count {
            let line = grid[scrollTop]
            scrollback.append(line)
            if scrollback.count > scrollbackLimit {
                scrollback.removeFirst()
            }
            // 触发行输出回调
            let text = String(line.map { $0.char }).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            if !text.isEmpty {
                onLineOutput?(text)
            }
        }
        // 滚动
        for r in scrollTop...(scrollBottom - count) {
            grid[r] = grid[r + count]
        }
        for r in (scrollBottom - count + 1)...scrollBottom {
            grid[r] = Array(repeating: TerminalCell(), count: cols)
        }
    }

    func scrollDown(_ n: Int = 1) {
        let count = min(n, scrollBottom - scrollTop + 1)
        for r in stride(from: scrollBottom, through: scrollTop + count, by: -1) {
            grid[r] = grid[r - count]
        }
        for r in scrollTop..<(scrollTop + count) {
            grid[r] = Array(repeating: TerminalCell(), count: cols)
        }
    }

    // MARK: - 插入/删除

    func insertLines(_ n: Int) {
        let count = max(1, n)
        for r in stride(from: scrollBottom, through: cursorRow + count, by: -1) {
            grid[r] = grid[r - count]
        }
        for r in cursorRow..<min(cursorRow + count, scrollBottom + 1) {
            grid[r] = Array(repeating: TerminalCell(), count: cols)
        }
    }

    func deleteLines(_ n: Int) {
        let count = max(1, n)
        for r in cursorRow..<(scrollBottom - count + 1) {
            grid[r] = grid[r + count]
        }
        for r in (scrollBottom - count + 1)...scrollBottom {
            grid[r] = Array(repeating: TerminalCell(), count: cols)
        }
    }

    func insertChars(_ n: Int) {
        let count = max(1, min(n, cols - cursorCol))
        for c in stride(from: cols - 1, through: cursorCol + count, by: -1) {
            grid[cursorRow][c] = grid[cursorRow][c - count]
        }
        for c in cursorCol..<(cursorCol + count) {
            grid[cursorRow][c] = TerminalCell()
        }
    }

    func deleteChars(_ n: Int) {
        let count = max(1, n)
        for c in cursorCol..<(cols - count) {
            grid[cursorRow][c] = grid[cursorRow][c + count]
        }
        for c in (cols - count)..<cols {
            grid[cursorRow][c] = TerminalCell()
        }
    }

    // MARK: - SGR 属性设置

    func setSGR(_ params: [Int]) {
        if params.isEmpty {
            currentAttrs = .default
            return
        }
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:  currentAttrs = .default
            case 1:  currentAttrs.bold = true
            case 2:  currentAttrs.dim = true
            case 3:  currentAttrs.italic = true
            case 4:  currentAttrs.underline = true
            case 5, 6: currentAttrs.blink = true
            case 7:  currentAttrs.inverse = true
            case 9:  currentAttrs.strikethrough = true
            case 22: currentAttrs.bold = false; currentAttrs.dim = false
            case 23: currentAttrs.italic = false
            case 24: currentAttrs.underline = false
            case 25: currentAttrs.blink = false
            case 27: currentAttrs.inverse = false
            case 29: currentAttrs.strikethrough = false
            case 30...37:  // 标准前景色
                currentAttrs.fg = ansiColor(p - 30, bright: false)
            case 38:  // 扩展前景色
                if i + 1 < params.count {
                    i += 1
                    if params[i] == 5, i + 1 < params.count {  // 256 色
                        i += 1
                        currentAttrs.fg = color256(params[i])
                    } else if params[i] == 2, i + 3 < params.count {  // 真彩色
                        currentAttrs.fg = Color(red: Double(params[i+1])/255, green: Double(params[i+2])/255, blue: Double(params[i+3])/255)
                        i += 3
                    }
                }
            case 39: currentAttrs.fg = .white
            case 40...47:  // 标准背景色
                currentAttrs.bg = ansiColor(p - 40, bright: false)
            case 48:  // 扩展背景色
                if i + 1 < params.count {
                    i += 1
                    if params[i] == 5, i + 1 < params.count {
                        i += 1
                        currentAttrs.bg = color256(params[i])
                    } else if params[i] == 2, i + 3 < params.count {
                        currentAttrs.bg = Color(red: Double(params[i+1])/255, green: Double(params[i+2])/255, blue: Double(params[i+3])/255)
                        i += 3
                    }
                }
            case 49: currentAttrs.bg = .clear
            case 90...97:  // 亮前景色
                currentAttrs.fg = ansiColor(p - 90, bright: true)
            case 100...107:  // 亮背景色
                currentAttrs.bg = ansiColor(p - 100, bright: true)
            default: break
            }
            i += 1
        }
    }

    private func ansiColor(_ idx: Int, bright: Bool) -> Color {
        let base: [Color] = [
            Color(red: 0, green: 0, blue: 0),          // 0: Black
            Color(red: 0.8, green: 0, blue: 0),        // 1: Red
            Color(red: 0, green: 0.8, blue: 0),        // 2: Green
            Color(red: 0.8, green: 0.8, blue: 0),      // 3: Yellow
            Color(red: 0, green: 0, blue: 0.8),        // 4: Blue
            Color(red: 0.8, green: 0, blue: 0.8),      // 5: Magenta
            Color(red: 0, green: 0.8, blue: 0.8),      // 6: Cyan
            Color(red: 0.75, green: 0.75, blue: 0.75), // 7: White
        ]
        if idx < 0 || idx >= base.count { return .white }
        if bright {
            return base[idx].opacity(0.85)
        }
        return base[idx]
    }

    private func color256(_ idx: Int) -> Color {
        if idx < 16 {
            return ansiColor(idx % 8, bright: idx >= 8)
        }
        if idx < 232 {
            let i = idx - 16
            let r = Double((i / 36) % 6) / 5.0
            let g = Double((i / 6) % 6) / 5.0
            let b = Double(i % 6) / 5.0
            return Color(red: r, green: g, blue: b)
        }
        let gray = Double(idx - 232) / 23.0
        return Color(red: gray, green: gray, blue: gray)
    }

    /// 重置终端
    func reset() {
        currentAttrs = .default
        cursorRow = 0
        cursorCol = 0
        scrollTop = 0
        scrollBottom = rows - 1
        autoWrap = true
        for r in 0..<rows {
            for c in 0..<cols { grid[r][c] = TerminalCell() }
        }
    }
}

// MARK: - 带属性的字符 (用于渲染)

public struct AttributedCharacter: Hashable {
    public let char: Character
    public let attrs: TerminalCellAttrs

    public init(char: Character, attrs: TerminalCellAttrs) {
        self.char = char
        self.attrs = attrs
    }
}

// MARK: - ANSI 转义序列解析器 (状态机)

private struct ANSIParser {
    let buffer: TerminalBuffer

    enum State {
        case normal
        case escape
        case csi
        case osc
        case oscString
        case csiQuestion
    }

    private var state: State = .normal
    private var params: String = ""
    private var oscString: String = ""
    private var privateMarker: Character = "\0"

    init(buffer: TerminalBuffer) {
        self.buffer = buffer
    }

    mutating func feed(_ ch: Character) {
        switch state {
        case .normal:
            if ch == "\u{1B}" {  // ESC
                state = .escape
            } else {
                buffer.putChar(ch)
            }

        case .escape:
            switch ch {
            case "[":
                state = .csi
                params = ""
            case "]":
                state = .osc
                oscString = ""
            case "7":
                buffer.saveCursor()
                state = .normal
            case "8":
                buffer.restoreCursor()
                state = .normal
            case "D":
                buffer.cursorDown(1)
                state = .normal
            case "M":
                buffer.cursorUp(1)
                state = .normal
            case "E":
                buffer.cursorNextLine(1)
                state = .normal
            case "c":
                buffer.reset()
                state = .normal
            case "H":
                // 设置制表位, 忽略
                state = .normal
            default:
                state = .normal
            }

        case .csi:
            switch ch {
            case "0"..."9", ";":
                params.append(ch)
            case "?":
                state = .csiQuestion
            case "A":  // CUU
                let n = parseInt(params, default: 1)
                buffer.cursorUp(n)
                state = .normal
            case "B":  // CUD
                let n = parseInt(params, default: 1)
                buffer.cursorDown(n)
                state = .normal
            case "C":  // CUF
                let n = parseInt(params, default: 1)
                buffer.cursorForward(n)
                state = .normal
            case "D":  // CUB
                let n = parseInt(params, default: 1)
                buffer.cursorBackward(n)
                state = .normal
            case "E":  // CNL
                let n = parseInt(params, default: 1)
                buffer.cursorNextLine(n)
                state = .normal
            case "F":  // CPL
                let n = parseInt(params, default: 1)
                buffer.cursorPrevLine(n)
                state = .normal
            case "G":  // CHA
                let n = parseInt(params, default: 1)
                buffer.cursorHorizontalAbsolute(n)
                state = .normal
            case "H", "f":  // CUP / HVP
                let vals = parseTwoInts(params)
                buffer.cursorPosition(row: vals.0, col: vals.1)
                state = .normal
            case "J":  // ED
                let n = parseInt(params, default: 0)
                buffer.eraseDisplay(n)
                state = .normal
            case "K":  // EL
                let n = parseInt(params, default: 0)
                buffer.eraseLine(n)
                state = .normal
            case "X":  // ECH
                let n = parseInt(params, default: 1)
                buffer.eraseChars(n)
                state = .normal
            case "L":  // IL
                let n = parseInt(params, default: 1)
                buffer.insertLines(n)
                state = .normal
            case "M":  // DL
                let n = parseInt(params, default: 1)
                buffer.deleteLines(n)
                state = .normal
            case "@":  // ICH
                let n = parseInt(params, default: 1)
                buffer.insertChars(n)
                state = .normal
            case "P":  // DCH
                let n = parseInt(params, default: 1)
                buffer.deleteChars(n)
                state = .normal
            case "S":  // SU
                let n = parseInt(params, default: 1)
                buffer.scrollUp(n)
                state = .normal
            case "T":  // SD
                let n = parseInt(params, default: 1)
                buffer.scrollDown(n)
                state = .normal
            case "m":  // SGR
                let vals = parseSGRParams(params)
                buffer.setSGR(vals)
                state = .normal
            case "s":  // 保存光标
                buffer.saveCursor()
                state = .normal
            case "u":  // 恢复光标
                buffer.restoreCursor()
                state = .normal
            case "r":  // 设置滚动区域
                let vals = parseTwoInts(params)
                buffer.scrollTop = max(0, vals.0 - 1)
                buffer.scrollBottom = max(0, vals.1 - 1)
                if buffer.scrollBottom >= buffer.rows {
                    buffer.scrollBottom = buffer.rows - 1
                }
                state = .normal
            case "h":  // 设置模式
                setMode(true)
                state = .normal
            case "l":  // 重置模式
                setMode(false)
                state = .normal
            default: break
            }

        case .csiQuestion:
            switch ch {
            case "0"..."9", ";":
                params.append(ch)
            case "h":  // DECSET
                setDECMode(true)
                state = .normal
            case "l":  // DECRST
                setDECMode(false)
                state = .normal
            default: break
            }

        case .osc:
            if ch == ";" {
                // OSC P s ; Pt ST
                state = .oscString
            } else {
                state = .normal
            }

        case .oscString:
            if ch == "\u{7}" || ch == "\u{1B}" {
                // 忽略 OSC 字符串 (窗口标题等)
                state = .normal
                if ch == "\u{1B}" {
                    state = .escape
                }
            } else {
                oscString.append(ch)
            }
        }
    }

    func flush() {
        // 忽略未完成的序列
    }

    private func parseInt(_ s: String, default: Int) -> Int {
        if s.isEmpty { return `default` }
        return Int(s) ?? `default`
    }

    private func parseTwoInts(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: ";", maxSplits: 1).map { Int($0) ?? 1 }
        return (parts.first ?? 1, parts.count > 1 ? parts[1] : 1)
    }

    private func parseSGRParams(_ s: String) -> [Int] {
        if s.isEmpty { return [0] }
        return s.split(separator: ";").map { Int($0) ?? 0 }
    }

    private func setMode(_ enable: Bool) {
        // CSI ? Pm h/l: 忽略大部分模式
        // CSI 4 h: 插入模式 -> 忽略
        // CSI 20 h: 自动换行
        let p = parseInt(params, default: 0)
        if p == 20 { buffer.autoWrap = enable }
    }

    private func setDECMode(_ enable: Bool) {
        let p = parseInt(params, default: 0)
        switch p {
        case 25: buffer.cursorVisible = enable
        case 1049:  // 交替屏幕缓冲
            if enable { buffer.saveCursor() }
            else { buffer.restoreCursor() }
        default: break
        }
    }
}
#endif