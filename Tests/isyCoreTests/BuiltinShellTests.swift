// BuiltinShellTests.swift - 验证内置 Shell 命令的正确性

import XCTest
@testable import isyCore

final class BuiltinShellTests: XCTestCase {

    var shell: BuiltinShell!
    var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "isy_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        shell = BuiltinShell()
        shell.env.cwd = tempDir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        shell = nil
        super.tearDown()
    }

    // MARK: - 环境变量展开

    func testExpandVars() {
        shell.env.env["FOO"] = "bar"
        let result = shell.execute("echo $FOO")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "bar")
    }

    func testExpandVarsBraces() {
        shell.env.env["FOO"] = "bar"
        let result = shell.execute("echo ${FOO}")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "bar")
    }

    // MARK: - echo

    func testEchoSimple() {
        let result = shell.execute("echo hello world")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testEchoNoNewline() {
        let result = shell.execute("echo -n hello")
        XCTAssertEqual(result, "hello")
    }

    func testEchoQuoted() {
        let result = shell.execute("echo \"hello   world\"")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "hello   world")
    }

    // MARK: - pwd / cd

    func testPwd() {
        let result = shell.execute("pwd")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), tempDir)
    }

    func testCd() {
        let subDir = tempDir + "/subdir"
        try? FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        let _ = shell.execute("cd subdir")
        let result = shell.execute("pwd")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), subDir)
    }

    func testCdInvalid() {
        let _ = shell.execute("cd /nonexistent/path")
        XCTAssertEqual(shell.env.lastExitCode, 1)
    }

    // MARK: - ls

    func testLs() {
        let file1 = tempDir + "/test1.txt"
        let file2 = tempDir + "/test2.txt"
        FileManager.default.createFile(atPath: file1, contents: "content1".data(using: .utf8))
        FileManager.default.createFile(atPath: file2, contents: "content2".data(using: .utf8))
        let result = shell.execute("ls")
        XCTAssertTrue(result.contains("test1.txt"))
        XCTAssertTrue(result.contains("test2.txt"))
    }

    func testLsLongFormat() {
        let file = tempDir + "/test.txt"
        FileManager.default.createFile(atPath: file, contents: "content".data(using: .utf8))
        let result = shell.execute("ls -l")
        XCTAssertTrue(result.contains("test.txt"))
        XCTAssertTrue(result.contains("-rw"))
    }

    func testLsAll() {
        let file = tempDir + "/test.txt"
        let hidden = tempDir + "/.hidden"
        FileManager.default.createFile(atPath: file, contents: Data())
        FileManager.default.createFile(atPath: hidden, contents: Data())
        let result = shell.execute("ls -a")
        XCTAssertTrue(result.contains("test.txt"))
        XCTAssertTrue(result.contains(".hidden"))
    }

    // MARK: - cat

    func testCat() {
        let file = tempDir + "/test.txt"
        try? "hello world".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("cat test.txt")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testCatMultipleFiles() {
        let f1 = tempDir + "/f1.txt"
        let f2 = tempDir + "/f2.txt"
        try? "a\n".write(toFile: f1, atomically: true, encoding: .utf8)
        try? "b\n".write(toFile: f2, atomically: true, encoding: .utf8)
        let result = shell.execute("cat f1.txt f2.txt")
        XCTAssertTrue(result.contains("a"))
        XCTAssertTrue(result.contains("b"))
    }

    // MARK: - mkdir

    func testMkdir() {
        let _ = shell.execute("mkdir newdir")
        let dir = tempDir + "/newdir"
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testMkdirParent() {
        let _ = shell.execute("mkdir -p a/b/c")
        let dir = tempDir + "/a/b/c"
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
    }

    // MARK: - rm

    func testRm() {
        let file = tempDir + "/toberemoved.txt"
        FileManager.default.createFile(atPath: file, contents: Data())
        let _ = shell.execute("rm toberemoved.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    func testRmRecursive() {
        let dir = tempDir + "/rmdir"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let _ = shell.execute("rm -r rmdir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    // MARK: - cp / mv

    func testCp() {
        let src = tempDir + "/src.txt"
        try? "data".write(toFile: src, atomically: true, encoding: .utf8)
        let _ = shell.execute("cp src.txt dst.txt")
        let dst = tempDir + "/dst.txt"
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst))
        XCTAssertEqual(try? String(contentsOfFile: dst, encoding: .utf8), "data")
    }

    func testMv() {
        let src = tempDir + "/src.txt"
        try? "data".write(toFile: src, atomically: true, encoding: .utf8)
        let _ = shell.execute("mv src.txt dst.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src))
        let dst = tempDir + "/dst.txt"
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst))
    }

    // MARK: - touch / chmod

    func testTouch() {
        let _ = shell.execute("touch newfile.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir + "/newfile.txt"))
    }

    func testChmod() {
        let file = tempDir + "/chmodtest.txt"
        FileManager.default.createFile(atPath: file, contents: Data())
        let _ = shell.execute("chmod 755 chmodtest.txt")
        var st = stat()
        stat(file, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o755)
    }

    // MARK: - head / tail

    func testHead() {
        let file = tempDir + "/lines.txt"
        let content = (1...20).map { "line \($0)" }.joined(separator: "\n")
        try? content.write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("head -n 5 lines.txt")
        let lines = result.split(separator: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].contains("line 1"))
    }

    func testTail() {
        let file = tempDir + "/lines.txt"
        let content = (1...20).map { "line \($0)" }.joined(separator: "\n")
        try? content.write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("tail -n 3 lines.txt")
        let lines = result.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.last?.contains("line 20") ?? false)
    }

    // MARK: - wc

    func testWc() {
        let file = tempDir + "/wc.txt"
        try? "hello world\nfoo bar".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("wc wc.txt")
        // 验证输出包含行数、词数、字符数
        let parts = result.split(separator: " ")
        XCTAssertEqual(parts.count, 4) // lines words chars filename
        XCTAssertEqual(parts[0], "2") // 2 lines
    }

    // MARK: - grep

    func testGrep() {
        let file = tempDir + "/grep.txt"
        try? "hello\nworld\nhello world\n".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("grep hello grep.txt")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
    }

    func testGrepInvert() {
        let file = tempDir + "/grep.txt"
        try? "hello\nworld\n".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("grep -v hello grep.txt")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("world"))
    }

    func testGrepIgnoreCase() {
        let file = tempDir + "/grep.txt"
        try? "HELLO\nworld\n".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("grep -i hello grep.txt")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
    }

    // MARK: - 管道

    func testPipe() {
        let file = tempDir + "/pipe.txt"
        try? "hello\nworld\nfoo\nbar\n".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("cat pipe.txt | grep oo")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("foo"))
    }

    func testPipeWithHead() {
        let file = tempDir + "/pipe.txt"
        let content = (1...10).map { "line \($0)" }.joined(separator: "\n")
        try? content.write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("cat pipe.txt | head -n 3")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
    }

    func testPipeChain() {
        let file = tempDir + "/chain.txt"
        try? "apple\nbanana\napricot\navocado\nberry\n".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("cat chain.txt | grep ap | sort")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("apple"))
        XCTAssertTrue(lines[1].contains("apricot"))
    }

    // MARK: - 重定向

    func testOutputRedirect() {
        let _ = shell.execute("echo hello > redirect.txt")
        let content = try? String(contentsOfFile: tempDir + "/redirect.txt", encoding: .utf8)
        XCTAssertEqual(content?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testOutputAppend() {
        let _ = shell.execute("echo hello > append.txt")
        let _ = shell.execute("echo world >> append.txt")
        let content = try? String(contentsOfFile: tempDir + "/append.txt", encoding: .utf8)
        XCTAssertTrue(content?.contains("hello") ?? false)
        XCTAssertTrue(content?.contains("world") ?? false)
    }

    // MARK: - env / which

    func testEnv() {
        let result = shell.execute("env")
        XCTAssertTrue(result.contains("PATH="))
        XCTAssertTrue(result.contains("HOME="))
        XCTAssertTrue(result.contains("USER="))
    }

    func testWhich() {
        let result = shell.execute("which ls")
        XCTAssertTrue(result.contains("built-in"))
    }

    func testWhichNotFound() {
        let result = shell.execute("which nonexistent_cmd")
        XCTAssertEqual(result, "")
        XCTAssertEqual(shell.env.lastExitCode, 1)
    }

    // MARK: - sort / uniq / tr / cut

    func testSort() {
        let file = tempDir + "/sort.txt"
        try? "c\na\nb\n".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("sort sort.txt")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["a", "b", "c"])
    }

    func testSortReverse() {
        let file = tempDir + "/sort.txt"
        try? "a\nb\nc\n".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("sort -r sort.txt")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["c", "b", "a"])
    }

    func testUniq() {
        let file = tempDir + "/uniq.txt"
        try? "a\na\nb\nb\nc\n".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("uniq uniq.txt")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["a", "b", "c"])
    }

    func testTr() {
        let file = tempDir + "/tr.txt"
        try? "hello".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("tr e a < tr.txt")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "hallo")
    }

    func testCut() {
        let file = tempDir + "/cut.txt"
        try? "a,b,c\nd,e,f\n".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("cut -d , -f 2 cut.txt")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["b", "e"])
    }

    // MARK: - tee

    func testTee() {
        let result = shell.execute("echo hello | tee tee.txt")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        let content = try? String(contentsOfFile: tempDir + "/tee.txt", encoding: .utf8)
        XCTAssertEqual(content?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    // MARK: - seq / expr

    func testSeq() {
        let result = shell.execute("seq 5")
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["1", "2", "3", "4", "5"])
    }

    func testExpr() {
        let result = shell.execute("expr 3 + 4")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "7")
    }

    // MARK: - dirname / basename

    func testDirname() {
        let result = shell.execute("dirname /a/b/c.txt")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "/a/b")
    }

    func testBasename() {
        let result = shell.execute("basename /a/b/c.txt")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "c.txt")
    }

    // MARK: - date / uname / id / whoami

    func testDate() {
        let result = shell.execute("date")
        XCTAssertFalse(result.isEmpty)
        // 日期格式: EEE MMM d HH:mm:ss z yyyy
        XCTAssertTrue(result.contains("202") || result.contains("2025") || result.contains("2026"))
    }

    func testUname() {
        let result = shell.execute("uname")
        XCTAssertTrue(result.contains("Linux"))
        XCTAssertTrue(result.contains("isy"))
    }

    func testId() {
        let result = shell.execute("id")
        XCTAssertTrue(result.contains("uid=0"))
    }

    func testWhoami() {
        let result = shell.execute("whoami")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "root")
    }

    // MARK: - test / printf

    func testTestFileExists() {
        let file = tempDir + "/testfile.txt"
        FileManager.default.createFile(atPath: file, contents: Data())
        let result = shell.execute("test -f testfile.txt")
        XCTAssertEqual(result, "") // 成功返回空
    }

    func testTestFileNotExists() {
        let result = shell.execute("test -f nonexistent.txt")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    func testPrintf() {
        let result = shell.execute("printf \"hello %s\" world")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    // MARK: - sleep

    func testSleep() {
        let start = Date()
        let _ = shell.execute("sleep 0.1")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.09)
    }

    // MARK: - clear

    func testClear() {
        let result = shell.execute("clear")
        XCTAssertTrue(result.contains("\u{1B}[2J"))
        XCTAssertTrue(result.contains("\u{1B}[H"))
    }

    // MARK: - help / isy

    func testHelp() {
        let result = shell.execute("help")
        XCTAssertTrue(result.contains("isy 内置 Shell"))
        XCTAssertTrue(result.contains("ls"))
        XCTAssertTrue(result.contains("cat"))
    }

    func testIsyInfo() {
        let result = shell.execute("isy")
        XCTAssertTrue(result.contains("iOS System"))
        XCTAssertTrue(result.contains("binary patching"))
    }

    // MARK: - 通配符展开

    func testGlobExpand() {
        let _ = try? "a".write(toFile: tempDir + "/file1.txt", atomically: true, encoding: .utf8)
        let _ = try? "b".write(toFile: tempDir + "/file2.txt", atomically: true, encoding: .utf8)
        let result = shell.execute("ls *.txt")
        XCTAssertTrue(result.contains("file1.txt"))
        XCTAssertTrue(result.contains("file2.txt"))
    }

    // MARK: - 命令解析

    func testParseQuotedArgs() {
        let result = shell.execute("echo \"hello world\"")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testParseEscapedChars() {
        let result = shell.execute("echo hello\\ world")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    // MARK: - du

    func testDu() {
        let file = tempDir + "/dufile.txt"
        try? "hello world".write(toFile: file, atomically: true, encoding: .utf8)
        let result = shell.execute("du .")
        XCTAssertTrue(result.contains("\t."))
    }

    // MARK: - kill

    func testKillUsage() {
        let result = shell.execute("kill")
        XCTAssertTrue(result.contains("usage"))
        XCTAssertEqual(shell.env.lastExitCode, 1)
    }

    func testKillInvalidPid() {
        let result = shell.execute("kill 99999")
        XCTAssertTrue(result.contains("kill:"))
        XCTAssertEqual(shell.env.lastExitCode, 1)
    }

    func testKillWithSignal() {
        let result = shell.execute("kill -9 99999")
        XCTAssertTrue(result.contains("kill:"))
    }

    // MARK: - ps

    func testPs() {
        let result = shell.execute("ps")
        XCTAssertTrue(result.contains("PID"))
        XCTAssertTrue(result.contains("COMMAND"))
    }

    // MARK: - df

    func testDf() {
        let result = shell.execute("df")
        XCTAssertTrue(result.contains("Filesystem"))
        XCTAssertTrue(result.contains("Used"))
        XCTAssertTrue(result.contains("Mounted on"))
    }
}