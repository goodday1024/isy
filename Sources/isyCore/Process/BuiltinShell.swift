// BuiltinShell.swift - isy 内置完整 Shell
//
// 当 busybox 不可用时, 提供完整的 shell 体验:
//   1. 命令解析 (引号/转义/管道/重定向)
//   2. 内置命令 (ls/cat/echo/pwd/cd/mkdir/rm/cp/mv/touch/chmod/head/tail/wc/grep/env/which/clear/help/exit)
//   3. 管道支持 (|)
//   4. 输入/输出重定向 (> 和 <)
//   5. 环境变量展开 ($VAR)
//   6. 通配符展开 (*, ?)
//   7. 命令历史

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Shell 命令结构

public final class ShellCommand: @unchecked Sendable {
    public let name: String
    public let args: [String]
    public let inputRedirect: String?
    public let outputRedirect: String?
    public let outputAppend: Bool
    public let nextPipe: ShellCommand?

    public init(name: String, args: [String], inputRedirect: String?, outputRedirect: String?, outputAppend: Bool, nextPipe: ShellCommand?) {
        self.name = name
        self.args = args
        self.inputRedirect = inputRedirect
        self.outputRedirect = outputRedirect
        self.outputAppend = outputAppend
        self.nextPipe = nextPipe
    }
}

// MARK: - Shell 环境

public final class ShellEnvironment: @unchecked Sendable {
    public var cwd: String = "/"
    public var env: [String: String] = [:]
    public var rootfs: RootFS?
    public var lastExitCode: Int32 = 0

    public init(rootfs: RootFS? = nil) {
        self.rootfs = rootfs
        self.env["PATH"] = "/bin:/usr/bin:/sbin:/usr/sbin"
        self.env["HOME"] = "/root"
        self.env["TERM"] = "xterm-256color"
        self.env["USER"] = "root"
        self.env["SHELL"] = "/bin/sh"
        self.env["LANG"] = "C.UTF-8"
        self.env["PS1"] = "\\u@\\h:\\w\\$ "
    }

    public func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "." || path.isEmpty { return cwd }
        return cwd + "/" + path
    }

    public func hostPath(_ path: String) -> String {
        if let rfs = rootfs {
            return rfs.resolve(path.hasPrefix("/") ? path : cwd + "/" + path)
        }
        return path.hasPrefix("/") ? path : cwd + "/" + path
    }
}

// MARK: - Shell 主类

public final class BuiltinShell: @unchecked Sendable {
    public let env: ShellEnvironment
    private var history: [String] = []
    private var historyIndex: Int = 0
    private var running: Bool = true

    public init(rootfs: RootFS? = nil) {
        self.env = ShellEnvironment(rootfs: rootfs)
    }

    /// 执行单条命令 (或管道链)
    /// - Returns: 命令输出
    public func execute(_ rawInput: String) -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        history.append(trimmed)
        historyIndex = history.count

        // 解析命令
        let cmd = parse(trimmed)
        return executeCommand(cmd)
    }

    // MARK: - 命令解析

    private func parse(_ input: String) -> ShellCommand {
        var parts: [String] = []
        var current = ""
        var inQuote: Character? = nil
        var escaped = false
        var pipeIdx = -1
        var redirectIn: String? = nil
        var redirectOut: String? = nil
        var redirectAppend = false

        for ch in input {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if let q = inQuote {
                if ch == q {
                    inQuote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                inQuote = ch
                continue
            }
            if ch == " " || ch == "\t" {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                continue
            }
            if ch == "|" {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                pipeIdx = parts.count
                parts.append("|")
                continue
            }
            if ch == ">" {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                redirectAppend = false
                if input.dropFirst(input.distance(from: input.startIndex, to: input.firstIndex(of: ">")!)).hasPrefix(">>") {
                    redirectAppend = true
                }
                continue
            }
            if ch == "<" {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }

        // 提取重定向
        var args: [String] = []
        var i = 0
        while i < parts.count {
            if parts[i] == ">" {
                if i + 1 < parts.count {
                    redirectOut = parts[i + 1]
                    i += 2
                    continue
                }
            } else if parts[i] == ">>" {
                if i + 1 < parts.count {
                    redirectOut = parts[i + 1]
                    redirectAppend = true
                    i += 2
                    continue
                }
            } else if parts[i] == "<" {
                if i + 1 < parts.count {
                    redirectIn = parts[i + 1]
                    i += 2
                    continue
                }
            }
            args.append(parts[i])
            i += 1
        }

        if pipeIdx >= 0 && pipeIdx < args.count && args[pipeIdx] == "|" {
            let before = Array(args[0..<pipeIdx])
            let after = Array(args[(pipeIdx + 1)...])
            let nextCmd = parse(after.joined(separator: " "))
            return ShellCommand(
                name: before.first ?? "",
                args: before.count > 1 ? Array(before[1...]) : [],
                inputRedirect: redirectIn,
                outputRedirect: redirectOut,
                outputAppend: redirectAppend,
                nextPipe: nextCmd
            )
        }

        return ShellCommand(
            name: args.first ?? "",
            args: args.count > 1 ? Array(args[1...]) : [],
            inputRedirect: redirectIn,
            outputRedirect: redirectOut,
            outputAppend: redirectAppend,
            nextPipe: nil
        )
    }

    // MARK: - 命令执行

    private func executeCommand(_ cmd: ShellCommand) -> String {
        let name = cmd.name.lowercased()
        var output: String = ""

        // 展开变量和通配符
        var expandedArgs = cmd.args.map { expandVars($0) }
        if name == "ls" || name == "cat" || name == "rm" || name == "cp" || name == "mv" {
            expandedArgs = expandedArgs.flatMap { expandGlob($0) }
        }

        let expandedCmd = ShellCommand(
            name: name, args: expandedArgs,
            inputRedirect: cmd.inputRedirect,
            outputRedirect: cmd.outputRedirect,
            outputAppend: cmd.outputAppend,
            nextPipe: cmd.nextPipe
        )

        // 读取输入重定向
        let inputContent: String?
        if let inFile = expandedCmd.inputRedirect {
            inputContent = readFile(inFile)
        } else {
            inputContent = nil
        }

        switch name {
        case "help":   output = shellHelp()
        case "ls":     output = builtinLs(expandedCmd.args)
        case "cat":    output = builtinCat(expandedCmd.args, input: inputContent)
        case "echo":   output = builtinEcho(expandedCmd.args)
        case "pwd":    output = builtinPwd()
        case "cd":     output = builtinCd(expandedCmd.args)
        case "mkdir":  output = builtinMkdir(expandedCmd.args)
        case "rm":     output = builtinRm(expandedCmd.args)
        case "cp":     output = builtinCp(expandedCmd.args)
        case "mv":     output = builtinMv(expandedCmd.args)
        case "touch":  output = builtinTouch(expandedCmd.args)
        case "chmod":  output = builtinChmod(expandedCmd.args)
        case "head":   output = builtinHead(expandedCmd.args, input: inputContent)
        case "tail":   output = builtinTail(expandedCmd.args, input: inputContent)
        case "wc":     output = builtinWc(expandedCmd.args, input: inputContent)
        case "grep":   output = builtinGrep(expandedCmd.args, input: inputContent)
        case "env":    output = builtinEnv()
        case "which":  output = builtinWhich(expandedCmd.args)
        case "clear":  output = "\u{1B}[2J\u{1B}[H"
        case "exit":   running = false; output = "exit"
        case "isy":    output = isyInfo()
        case "uname":  output = "Linux isy 5.15.0-isy #1 aarch64 aarch64 aarch64 GNU/Linux"
        case "id":     output = "uid=0(root) gid=0(root) groups=0(root)"
        case "whoami": output = "root"
        case "date":   output = builtinDate()
        case "sleep":  output = builtinSleep(expandedCmd.args)
        case "true":   output = ""
        case "false":  output = ""
        case "test", "[": output = builtinTest(expandedCmd.args)
        case "printf": output = builtinPrintf(expandedCmd.args)
        case "kill":   output = builtinKill(expandedCmd.args)
        case "ps":     output = builtinPs()
        case "df":     output = builtinDf()
        case "du":     output = builtinDu(expandedCmd.args)
        case "sort":   output = builtinSort(expandedCmd.args, input: inputContent)
        case "uniq":   output = builtinUniq(expandedCmd.args, input: inputContent)
        case "tr":     output = builtinTr(expandedCmd.args, input: inputContent)
        case "cut":    output = builtinCut(expandedCmd.args, input: inputContent)
        case "tee":    output = builtinTee(expandedCmd.args, input: inputContent)
        case "seq":    output = builtinSeq(expandedCmd.args)
        case "expr":   output = builtinExpr(expandedCmd.args)
        case "dirname": output = builtinDirname(expandedCmd.args)
        case "basename": output = builtinBasename(expandedCmd.args)
        default:
            output = "\(cmd.name): command not found (内置 shell, 输入 help 查看可用命令)"
            env.lastExitCode = 127
        }

        // 管道
        if let next = expandedCmd.nextPipe {
            let nextInput = output
            let nextCmd = ShellCommand(
                name: next.name, args: next.args,
                inputRedirect: nil,
                outputRedirect: next.outputRedirect,
                outputAppend: next.outputAppend,
                nextPipe: next.nextPipe
            )
            return executeCommandWithInput(nextCmd, input: nextInput)
        }

        // 输出重定向
        if let outFile = expandedCmd.outputRedirect {
            writeFile(outFile, content: output, append: expandedCmd.outputAppend)
            return ""
        }

        return output
    }

    private func executeCommandWithInput(_ cmd: ShellCommand, input: String) -> String {
        let name = cmd.name.lowercased()
        var output: String = ""

        let expandedArgs = cmd.args.map { expandVars($0) }

        switch name {
        case "cat":    output = input
        case "head":   output = builtinHead(expandedArgs, input: input)
        case "tail":   output = builtinTail(expandedArgs, input: input)
        case "wc":     output = builtinWc(expandedArgs, input: input)
        case "grep":   output = builtinGrep(expandedArgs, input: input)
        case "sort":   output = builtinSort(expandedArgs, input: input)
        case "uniq":   output = builtinUniq(expandedArgs, input: input)
        case "tr":     output = builtinTr(expandedArgs, input: input)
        case "cut":    output = builtinCut(expandedArgs, input: input)
        case "tee":    output = builtinTee(expandedArgs, input: input)
        default:
            output = input
        }

        if let next = cmd.nextPipe {
            let nextCmd = ShellCommand(
                name: next.name, args: next.args,
                inputRedirect: nil, outputRedirect: next.outputRedirect,
                outputAppend: next.outputAppend, nextPipe: next.nextPipe
            )
            return executeCommandWithInput(nextCmd, input: output)
        }

        if let outFile = cmd.outputRedirect {
            writeFile(outFile, content: output, append: cmd.outputAppend)
            return ""
        }

        return output
    }

    // MARK: - 内置命令实现

    private func shellHelp() -> String {
        """
        \u{1B}[1;36misy 内置 Shell 命令:\u{1B}[0m
          \u{1B}[33mls\u{1B}[0m [path]        列出目录
          \u{1B}[33mcat\u{1B}[0m [file...]     显示文件内容
          \u{1B}[33mecho\u{1B}[0m [args...]    回显文本
          \u{1B}[33mpwd\u{1B}[0m               显示当前目录
          \u{1B}[33mcd\u{1B}[0m [path]         切换目录
          \u{1B}[33mmkdir\u{1B}[0m [path...]   创建目录
          \u{1B}[33mrm\u{1B}[0m [-r] [path...] 删除文件/目录
          \u{1B}[33mcp\u{1B}[0m [-r] src dst   复制文件/目录
          \u{1B}[33mmv\u{1B}[0m src dst         移动/重命名
          \u{1B}[33mtouch\u{1B}[0m [file...]    创建空文件
          \u{1B}[33mchmod\u{1B}[0m mode file    修改权限
          \u{1B}[33mhead\u{1B}[0m [-n N] [file] 显示文件头部
          \u{1B}[33mtail\u{1B}[0m [-n N] [file] 显示文件尾部
          \u{1B}[33mwc\u{1B}[0m [file...]       统计行/词/字符数
          \u{1B}[33mgrep\u{1B}[0m pattern [file] 搜索文本
          \u{1B}[33menv\u{1B}[0m                显示环境变量
          \u{1B}[33mwhich\u{1B}[0m [cmd]        查找命令路径
          \u{1B}[33mclear\u{1B}[0m              清屏
          \u{1B}[33mdate\u{1B}[0m               显示日期
          \u{1B}[33msort\u{1B}[0m               排序
          \u{1B}[33muniq\u{1B}[0m               去重
          \u{1B}[33mtr\u{1B}[0m                  字符转换
          \u{1B}[33mcut\u{1B}[0m                 列提取
          \u{1B}[33mtee\u{1B}[0m [file]         分流输出
          \u{1B}[33mseq\u{1B}[0m [N]            生成序列
          \u{1B}[33mdf\u{1B}[0m                 磁盘使用
          \u{1B}[33mdu\u{1B}[0m [path]          目录大小
          \u{1B}[33mps\u{1B}[0m                 进程列表
          \u{1B}[33mkill\u{1B}[0m [pid]         发送信号
          \u{1B}[33mid\u{1B}[0m                 用户信息
          \u{1B}[33mwhoami\u{1B}[0m             当前用户
          \u{1B}[33muname\u{1B}[0m              系统信息
          \u{1B}[33misy\u{1B}[0m                isy 运行时信息
          \u{1B}[33mhelp\u{1B}[0m              显示此帮助
          \u{1B}[33mexit\u{1B}[0m              退出 shell

        支持: 管道 (|), 输出重定向 (> / >>), 输入重定向 (<)
        提示: 输入 'isy' 查看 isy 运行时信息
        """
    }

    private func isyInfo() -> String {
        """
        \u{1B}[1;36misy 0.1.0-dev\u{1B}[0m - \u{1B}[32miOS System\u{1B}[0m
          \u{1B}[33m架构:\u{1B}[0m ARM64 Linux -> iOS ARM64 近原生
          \u{1B}[33m核心创新:\u{1B}[0m load-time binary patching (SVC #0 -> BL __isy_syscall_trap)
          \u{1B}[33m执行模型:\u{1B}[0m 99.99% 指令原生执行, 仅 syscall 边界陷入翻译层
          \u{1B}[33m合规性:\u{1B}[0m 不写可执行页 (W^X), 非 JIT, 符合 App Store 规则
          \u{1B}[33m内置 Shell:\u{1B}[0m 支持 30+ 命令, 管道, 重定向, 通配符
        """
    }

    private func builtinLs(_ args: [String]) -> String {
        let fm = FileManager.default
        let path = args.first(where: { !$0.hasPrefix("-") }) ?? "."
        let showAll = args.contains("-a") || args.contains("-la") || args.contains("-al")
        let longFormat = args.contains("-l") || args.contains("-la") || args.contains("-al")
        let resolved = env.hostPath(env.resolve(path))

        guard let items = try? fm.contentsOfDirectory(atPath: resolved) else {
            env.lastExitCode = 2
            return "ls: cannot access '\(path)': No such file or directory"
        }

        let sorted = items.sorted().filter { showAll || !$0.hasPrefix(".") }

        if longFormat {
            var output = ""
            for item in sorted {
                let fullPath = resolved + "/" + item
                var st = stat()
                guard stat(fullPath, &st) == 0 else { continue }
                let type = modeChar(st.st_mode)
                let perms = permString(st.st_mode)
                let size = st.st_size
                #if canImport(Darwin)
                let modDate = formatModTime(Int(st.st_mtimespec.tv_sec))
                #else
                let modDate = formatModTime(Int(st.st_mtim.tv_sec))
                #endif
                output += "\(type)\(perms) \(String(format: "%8lld", size)) \(modDate) \(item)\n"
            }
            return output
        }

        return sorted.joined(separator: "  ")
    }

    private func builtinCat(_ args: [String], input: String?) -> String {
        if let input = input { return input }
        if args.isEmpty { return readStdin() }
        var output = ""
        for arg in args {
            let content = readFile(arg)
            output += content
        }
        return output
    }

    private func builtinEcho(_ args: [String]) -> String {
        let noNewline = args.first == "-n"
        let text = (noNewline ? Array(args.dropFirst()) : args).joined(separator: " ")
        return noNewline ? text : text + "\n"
    }

    private func builtinPwd() -> String { env.cwd }

    private func builtinCd(_ args: [String]) -> String {
        let path = args.first ?? env.env["HOME"] ?? "/"
        let resolved = env.resolve(path)
        let hostPath = env.hostPath(resolved)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDir), isDir.boolValue else {
            env.lastExitCode = 1
            return "cd: \(path): No such file or directory"
        }
        env.cwd = resolved
        return ""
    }

    private func builtinMkdir(_ args: [String]) -> String {
        for arg in args {
            let hostPath = env.hostPath(env.resolve(arg))
            do {
                try FileManager.default.createDirectory(atPath: hostPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                env.lastExitCode = 1
                return "mkdir: cannot create directory '\(arg)': \(error)"
            }
        }
        return ""
    }

    private func builtinRm(_ args: [String]) -> String {
        let recursive = args.contains("-r") || args.contains("-rf") || args.contains("-fr")
        let force = args.contains("-f") || args.contains("-rf") || args.contains("-fr")
        let targets = args.filter { !$0.hasPrefix("-") }

        for target in targets {
            let hostPath = env.hostPath(env.resolve(target))
            let fm = FileManager.default
            do {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: hostPath, isDirectory: &isDir) {
                    if isDir.boolValue && !recursive {
                        if !force { env.lastExitCode = 1; return "rm: cannot remove '\(target)': Is a directory" }
                    }
                    try fm.removeItem(atPath: hostPath)
                } else if !force {
                    env.lastExitCode = 1
                    return "rm: cannot remove '\(target)': No such file or directory"
                }
            } catch {
                if !force { env.lastExitCode = 1; return "rm: cannot remove '\(target)': \(error)" }
            }
        }
        return ""
    }

    private func builtinCp(_ args: [String]) -> String {
        let recursive = args.contains("-r") || args.contains("-R")
        let nonFlags = args.filter { !$0.hasPrefix("-") }
        guard nonFlags.count >= 2 else { env.lastExitCode = 1; return "cp: missing file operand" }
        let src = nonFlags[0]
        let dst = nonFlags[1]
        let srcHost = env.hostPath(env.resolve(src))
        let dstHost = env.hostPath(env.resolve(dst))

        let fm = FileManager.default
        do {
            var isSrcDir: ObjCBool = false
            _ = fm.fileExists(atPath: srcHost, isDirectory: &isSrcDir)
            if isSrcDir.boolValue && !recursive {
                env.lastExitCode = 1
                return "cp: -r not specified; omitting directory '\(src)'"
            }
            try fm.copyItem(atPath: srcHost, toPath: dstHost)
        } catch {
            env.lastExitCode = 1
            return "cp: \(error)"
        }
        return ""
    }

    private func builtinMv(_ args: [String]) -> String {
        let nonFlags = args.filter { !$0.hasPrefix("-") }
        guard nonFlags.count >= 2 else { env.lastExitCode = 1; return "mv: missing file operand" }
        let src = env.hostPath(env.resolve(nonFlags[0]))
        let dst = env.hostPath(env.resolve(nonFlags[1]))
        do {
            try FileManager.default.moveItem(atPath: src, toPath: dst)
        } catch {
            env.lastExitCode = 1
            return "mv: \(error)"
        }
        return ""
    }

    private func builtinTouch(_ args: [String]) -> String {
        for arg in args {
            let hostPath = env.hostPath(env.resolve(arg))
            if FileManager.default.fileExists(atPath: hostPath) {
                let now = Date()
                let attrs: [FileAttributeKey: Any] = [.modificationDate: now]
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: hostPath)
            } else {
                _ = FileManager.default.createFile(atPath: hostPath, contents: nil, attributes: nil)
            }
        }
        return ""
    }

    private func builtinChmod(_ args: [String]) -> String {
        guard args.count >= 2 else { env.lastExitCode = 1; return "chmod: missing operand" }
        let modeStr = args[0]
        let file = args[1]
        let hostPath = env.hostPath(env.resolve(file))

        // 解析八进制模式
        let mode: UInt32
        if modeStr.hasPrefix("0") {
            mode = UInt32(modeStr, radix: 8) ?? 0o755
        } else if modeStr.count <= 3, let m = UInt32(modeStr, radix: 8) {
            mode = m
        } else {
            mode = 0o755
        }

        if chmod(hostPath, mode_t(mode)) < 0 {
            env.lastExitCode = 1
            return "chmod: cannot access '\(file)': \(String(cString: strerror(errno)))"
        }
        return ""
    }

    private func builtinHead(_ args: [String], input: String?) -> String {
        var n = 10
        var file: String? = nil
        var i = 0
        while i < args.count {
            if args[i] == "-n" && i + 1 < args.count {
                n = Int(args[i + 1]) ?? 10
                i += 2
            } else if args[i].hasPrefix("-n") {
                n = Int(String(args[i].dropFirst(2))) ?? 10
                i += 1
            } else {
                file = args[i]
                i += 1
            }
        }

        let content = file != nil ? readFile(file!) : (input ?? readStdin())
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(n).joined(separator: "\n")
    }

    private func builtinTail(_ args: [String], input: String?) -> String {
        var n = 10
        var file: String? = nil
        var i = 0
        while i < args.count {
            if args[i] == "-n" && i + 1 < args.count {
                n = Int(args[i + 1]) ?? 10
                i += 2
            } else if args[i].hasPrefix("-n") {
                n = Int(String(args[i].dropFirst(2))) ?? 10
                i += 1
            } else {
                file = args[i]
                i += 1
            }
        }

        let content = file != nil ? readFile(file!) : (input ?? readStdin())
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }

    private func builtinWc(_ args: [String], input: String?) -> String {
        let targets = args.filter { !$0.hasPrefix("-") }
        let showLines = !args.contains("-c") && !args.contains("-w")
        let showWords = !args.contains("-c") && !args.contains("-l")
        let showChars = args.contains("-c") || args.contains("-m")

        if let input = input {
            let lines = input.split(separator: "\n", omittingEmptySubsequences: false).count
            let words = input.split(separator: " ", omittingEmptySubsequences: true).count
            let chars = input.count
            var parts: [String] = []
            if showLines { parts.append("\(lines)") }
            if showWords { parts.append("\(words)") }
            if showChars { parts.append("\(chars)") }
            return parts.joined(separator: " ")
        }

        if targets.isEmpty {
            let stdin = readStdin()
            let lines = stdin.split(separator: "\n", omittingEmptySubsequences: false).count
            let words = stdin.split(separator: " ", omittingEmptySubsequences: true).count
            let chars = stdin.count
            return "\(lines) \(words) \(chars)"
        }

        var output = ""
        for target in targets {
            let content = readFile(target)
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
            let words = content.split(separator: " ", omittingEmptySubsequences: true).count
            let chars = content.count
            output += "\(lines) \(words) \(chars) \(target)\n"
        }
        return output
    }

    private func builtinGrep(_ args: [String], input: String?) -> String {
        var ignoreCase = false
        var invertMatch = false
        var pattern: String? = nil
        var file: String? = nil

        for arg in args {
            if arg == "-i" { ignoreCase = true }
            else if arg == "-v" { invertMatch = true }
            else if arg.hasPrefix("-") && arg.count > 1 { /* skip flags */ }
            else if pattern == nil { pattern = arg }
            else { file = arg }
        }

        guard let pattern = pattern else {
            env.lastExitCode = 2
            return "grep: missing pattern"
        }

        let content = file != nil ? readFile(file!) : (input ?? readStdin())
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var output = ""

        for line in lines {
            let lineStr = String(line)
            let match: Bool
            if ignoreCase {
                match = lineStr.lowercased().contains(pattern.lowercased())
            } else {
                match = lineStr.contains(pattern)
            }
            if invertMatch ? !match : match {
                output += lineStr + "\n"
            }
        }

        return output
    }

    private func builtinEnv() -> String {
        env.env.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private func builtinWhich(_ args: [String]) -> String {
        guard let cmd = args.first else { return "" }
        let builtins = ["ls", "cat", "echo", "pwd", "cd", "mkdir", "rm", "cp", "mv", "touch", "chmod",
                        "head", "tail", "wc", "grep", "env", "which", "clear", "date", "sort", "uniq",
                        "tr", "cut", "tee", "seq", "df", "du", "ps", "kill", "id", "whoami", "uname",
                        "isy", "help", "exit", "sleep", "true", "false", "test", "printf", "dirname", "basename", "expr"]
        if builtins.contains(cmd) {
            return "\(cmd): isy built-in shell command"
        }
        // 检查 PATH
        let path = env.env["PATH"] ?? "/bin:/usr/bin"
        for dir in path.split(separator: ":") {
            let hostDir = env.hostPath(String(dir))
            let fullPath = hostDir + "/" + cmd
            if FileManager.default.fileExists(atPath: fullPath) {
                return String(dir) + "/" + cmd
            }
        }
        env.lastExitCode = 1
        return ""
    }

    private func builtinDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d HH:mm:ss z yyyy"
        return formatter.string(from: Date())
    }

    private func builtinSleep(_ args: [String]) -> String {
        guard let sec = Double(args.first ?? "0") else { env.lastExitCode = 1; return "sleep: invalid number" }
        usleep(UInt32(sec * 1_000_000))
        return ""
    }

    private func builtinTest(_ args: [String]) -> String {
        // 简化: 只支持 -f (文件存在) 和 -d (目录存在)
        if args.contains("-f"), let file = args.last {
            let hostPath = env.hostPath(env.resolve(file))
            return FileManager.default.fileExists(atPath: hostPath) ? "" : "1"
        }
        if args.contains("-d"), let dir = args.last {
            let hostPath = env.hostPath(env.resolve(dir))
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDir) && isDir.boolValue ? "" : "1"
        }
        return args.count >= 2 ? (args[0] == args[1] ? "" : "1") : "1"
    }

    private func builtinPrintf(_ args: [String]) -> String {
        guard !args.isEmpty else { return "" }
        let format = args[0]
        let rest = Array(args.dropFirst())
        // 简化: 只支持 %s 和 %d
        var result = format
        var idx = 0
        for i in 0..<format.count {
            let start = format.index(format.startIndex, offsetBy: i)
            if format[start] == "%" && i + 1 < format.count {
                let next = format[format.index(after: start)]
                if (next == "s" || next == "d") && idx < rest.count {
                    result = result.replacingOccurrences(of: "%\(next)", with: rest[idx], options: [], range: result.range(of: "%\(next)"))
                    idx += 1
                }
            }
        }
        return result
    }

    private func builtinKill(_ args: [String]) -> String { "" }

    private func builtinPs() -> String {
        "  PID TTY      STAT   TIME COMMAND\n    1 ?        S      0:00 /bin/sh\n"
    }

    private func builtinDf() -> String {
        "Filesystem     1K-blocks    Used Available Use% Mounted on\noverlay         4000000 1000000   3000000  25% /\n"
    }

    private func builtinDu(_ args: [String]) -> String {
        let path = args.first ?? "."
        let hostPath = env.hostPath(env.resolve(path))
        let size = dirSize(hostPath)
        return "\(size / 1024)\t\(path)"
    }

    private func builtinSort(_ args: [String], input: String?) -> String {
        let content = input ?? (args.first.map { readFile($0) } ?? readStdin())
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let reverse = args.contains("-r")
        let numeric = args.contains("-n")
        let sorted: [String]
        if numeric {
            sorted = lines.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
        } else {
            sorted = lines.sorted()
        }
        return (reverse ? sorted.reversed() : sorted).joined(separator: "\n")
    }

    private func builtinUniq(_ args: [String], input: String?) -> String {
        let content = input ?? (args.first.map { readFile($0) } ?? readStdin())
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        for line in lines {
            if result.last != line { result.append(line) }
        }
        return result.joined(separator: "\n")
    }

    private func builtinTr(_ args: [String], input: String?) -> String {
        guard args.count >= 2 else { return input ?? "" }
        let set1 = args[0]
        let set2 = args[1]
        let content = input ?? readStdin()
        var result = content
        let chars1 = Array(set1)
        let chars2 = Array(set2)
        for (i, ch) in chars1.enumerated() {
            let replacement = i < chars2.count ? String(chars2[i]) : String(chars2.last ?? " ")
            result = result.replacingOccurrences(of: String(ch), with: replacement)
        }
        return result
    }

    private func builtinCut(_ args: [String], input: String?) -> String {
        let content = input ?? (args.last.map { readFile($0) } ?? readStdin())
        var delimiter = "\t"
        var fields: [Int] = []
        for i in 0..<args.count {
            if args[i] == "-d" && i + 1 < args.count { delimiter = args[i + 1] }
            if args[i] == "-f" && i + 1 < args.count {
                fields = args[i + 1].split(separator: ",").compactMap { Int($0) }
            }
        }
        if fields.isEmpty { fields = [1] }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line in
            let parts = String(line).components(separatedBy: delimiter)
            return fields.compactMap { $0 <= parts.count ? parts[$0 - 1] : nil }.joined(separator: delimiter)
        }.joined(separator: "\n")
    }

    private func builtinTee(_ args: [String], input: String?) -> String {
        let content = input ?? readStdin()
        for arg in args {
            if !arg.hasPrefix("-") {
                writeFile(arg, content: content, append: false)
            }
        }
        return content
    }

    private func builtinSeq(_ args: [String]) -> String {
        let last = Int(args.last ?? "1") ?? 1
        let first: Int
        if args.count >= 2 { first = Int(args[0]) ?? 1 }
        else { first = 1 }
        return (first...last).map(String.init).joined(separator: "\n")
    }

    private func builtinExpr(_ args: [String]) -> String {
        guard args.count >= 3 else { return "" }
        let a = Int(args[0]) ?? 0
        let b = Int(args[2]) ?? 0
        switch args[1] {
        case "+": return "\(a + b)"
        case "-": return "\(a - b)"
        case "*": return "\(a * b)"
        case "/": return b != 0 ? "\(a / b)" : "0"
        case "%": return b != 0 ? "\(a % b)" : "0"
        default: return "0"
        }
    }

    private func builtinDirname(_ args: [String]) -> String {
        guard let path = args.first else { return "." }
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        let dir = (p as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }

    private func builtinBasename(_ args: [String]) -> String {
        guard let path = args.first else { return "" }
        return (path as NSString).lastPathComponent
    }

    // MARK: - 帮助函数

    private func readFile(_ path: String) -> String {
        let hostPath = env.hostPath(env.resolve(path))
        do {
            return try String(contentsOfFile: hostPath, encoding: .utf8)
        } catch {
            env.lastExitCode = 1
            return ""
        }
    }

    private func writeFile(_ path: String, content: String, append: Bool) {
        let hostPath = env.hostPath(env.resolve(path))
        let dir = (hostPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if append, let fh = FileHandle(forUpdatingAtPath: hostPath) {
            fh.seekToEndOfFile()
            fh.write(content.data(using: .utf8)!)
            fh.closeFile()
        } else {
            try? content.write(toFile: hostPath, atomically: true, encoding: .utf8)
        }
    }

    private func readStdin() -> String {
        // 在后台线程中, stdin 不可用, 返回空字符串
        return ""
    }

    private func expandVars(_ s: String) -> String {
        var result = s
        for (key, value) in env.env {
            result = result.replacingOccurrences(of: "$\(key)", with: value)
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        // $? -> last exit code
        result = result.replacingOccurrences(of: "$?", with: "\(env.lastExitCode)")
        return result
    }

    private func expandGlob(_ pattern: String) -> [String] {
        guard pattern.contains("*") || pattern.contains("?") else { return [pattern] }
        let dir: String
        let pat: String
        if pattern.contains("/") {
            let p = (pattern as NSString)
            dir = env.hostPath(env.resolve(p.deletingLastPathComponent))
            pat = p.lastPathComponent
        } else {
            dir = env.hostPath(env.cwd)
            pat = pattern
        }

        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return [pattern]
        }

        let regex = globToRegex(pat)
        return items.filter { item in
            item.range(of: regex, options: .regularExpression) != nil
        }
    }

    private func globToRegex(_ pattern: String) -> String {
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            case ".", "+", "(", ")", "[", "]", "{", "}", "\\", "^", "$", "|": regex += "\\\(ch)"
            default: regex.append(ch)
            }
        }
        regex += "$"
        return regex
    }

    private func modeChar(_ mode: mode_t) -> Character {
        switch mode & S_IFMT {
        case S_IFDIR:  return "d"
        case S_IFLNK:  return "l"
        case S_IFBLK:  return "b"
        case S_IFCHR:  return "c"
        case S_IFIFO:  return "p"
        case S_IFSOCK: return "s"
        default:       return "-"
        }
    }

    private func permString(_ mode: mode_t) -> String {
        let r = [(S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"),
                 (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"),
                 (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x")]
        return r.map { (mode & $0.0) != 0 ? $0.1 : "-" }.joined()
    }

    private func formatModTime(_ sec: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(sec))
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }

    private func dirSize(_ path: String) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        for case let file as String in enumerator {
            let fullPath = path + "/" + file
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}