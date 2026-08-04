// RootFSTests.swift - 验证根文件系统管理功能

import XCTest
@testable import isyCore

final class RootFSTests: XCTestCase {

    var rootfs: RootFS!
    var testDir: String!

    override func setUp() {
        super.setUp()
        testDir = NSTemporaryDirectory() + "isy_rootfs_test_\(UUID().uuidString)"
        rootfs = RootFS(sandboxRoot: testDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: testDir)
        rootfs = nil
        super.tearDown()
    }

    // MARK: - 挂载 / 卸载

    func testMountCreatesDirectoryStructure() throws {
        try rootfs.mount()
        XCTAssertTrue(rootfs.isMounted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootfs.rootfsPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootfs.overlayPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootfs.whiteoutPath))
    }

    func testMountIdempotent() throws {
        try rootfs.mount()
        try rootfs.mount() // 第二次挂载不应崩溃
        XCTAssertTrue(rootfs.isMounted)
    }

    func testUnmount() throws {
        try rootfs.mount()
        rootfs.unmount()
        XCTAssertFalse(rootfs.isMounted)
    }

    func testMinimalRootfs() throws {
        try rootfs.mount()
        let expectedDirs = ["bin", "etc", "lib", "tmp", "var", "home", "root", "proc", "sys", "dev", "mnt", "opt", "sbin", "run"]
        for dir in expectedDirs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: rootfs.rootfsPath + "/" + dir),
                          "目录 \(dir) 应存在")
        }
    }

    func testMinimalRootfsConfigFiles() throws {
        try rootfs.mount()
        let configFiles = ["etc/os-release", "etc/passwd", "etc/group", "etc/resolv.conf", "etc/hostname", "etc/hosts", "etc/profile"]
        for file in configFiles {
            let path = rootfs.rootfsPath + "/" + file
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "配置文件 \(file) 应存在")
        }
    }

    // MARK: - 路径解析

    func testResolveRootfsPath() throws {
        try rootfs.mount()
        let resolved = rootfs.resolve("/bin")
        XCTAssertTrue(resolved.hasSuffix("/bin"))
    }

    func testResolveOverlayPrecedence() throws {
        try rootfs.mount()
        // 在 overlay 创建文件
        let overlayFile = rootfs.overlayPath + "/test.txt"
        let rootfsFile = rootfs.rootfsPath + "/test.txt"
        try? "overlay".write(toFile: overlayFile, atomically: true, encoding: .utf8)
        try? "rootfs".write(toFile: rootfsFile, atomically: true, encoding: .utf8)

        let resolved = rootfs.resolve("/test.txt")
        XCTAssertEqual(resolved, overlayFile)
        let content = try? String(contentsOfFile: resolved, encoding: .utf8)
        XCTAssertEqual(content, "overlay")
    }

    func testResolveWhiteout() throws {
        try rootfs.mount()
        // 创建 rootfs 文件
        let rootfsFile = rootfs.rootfsPath + "/test.txt"
        try? "data".write(toFile: rootfsFile, atomically: true, encoding: .utf8)
        // 创建 whiteout
        let whiteout = rootfs.whiteoutPath + "/test.txt"
        let whiteoutDir = (whiteout as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: whiteoutDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: whiteout, contents: nil)

        _ = rootfs.resolve("/test.txt")
        // 即使 whiteout 存在, resolve 返回 rootfs 路径
        // 但 exists 应该返回 false
        XCTAssertFalse(rootfs.exists("/test.txt"))
    }

    // MARK: - 文件存在性

    func testExistsRootfs() throws {
        try rootfs.mount()
        let file = rootfs.rootfsPath + "/test.txt"
        try? "data".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(rootfs.exists("/test.txt"))
    }

    func testExistsOverlay() throws {
        try rootfs.mount()
        let file = rootfs.overlayPath + "/test.txt"
        try? "data".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(rootfs.exists("/test.txt"))
    }

    func testExistsNotFound() throws {
        try rootfs.mount()
        XCTAssertFalse(rootfs.exists("/nonexistent/file.txt"))
    }

    // MARK: - 写时复制 (CoW)

    func testResolveForWriteCreatesCopy() throws {
        try rootfs.mount()
        // 在 rootfs 创建文件
        let rootfsFile = rootfs.rootfsPath + "/test.txt"
        try? "original".write(toFile: rootfsFile, atomically: true, encoding: .utf8)

        // 写入时触发 CoW
        let writePath = try rootfs.resolveForWrite("/test.txt", operation: .write)
        XCTAssertTrue(writePath.hasPrefix(rootfs.overlayPath))

        // 确认 overlay 中的文件存在且与原文件内容相同
        XCTAssertTrue(FileManager.default.fileExists(atPath: writePath))
        let content = try? String(contentsOfFile: writePath, encoding: .utf8)
        XCTAssertEqual(content, "original")
    }

    func testResolveForWriteCreatesNewFile() throws {
        try rootfs.mount()
        // 写入不存在的文件应在 overlay 创建
        let writePath = try rootfs.resolveForWrite("/newfile.txt", operation: .create)
        XCTAssertTrue(writePath.hasPrefix(rootfs.overlayPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: writePath))
    }

    func testResolveForWriteTruncate() throws {
        try rootfs.mount()
        let rootfsFile = rootfs.rootfsPath + "/test.txt"
        try? "original data".write(toFile: rootfsFile, atomically: true, encoding: .utf8)

        let writePath = try rootfs.resolveForWrite("/test.txt", operation: .truncate)
        let content = try? String(contentsOfFile: writePath, encoding: .utf8)
        XCTAssertEqual(content, "") // 截断后为空
    }

    // MARK: - 删除 (Whiteout)

    func testDeleteCreatesWhiteout() throws {
        try rootfs.mount()
        let rootfsFile = rootfs.rootfsPath + "/test.txt"
        try? "data".write(toFile: rootfsFile, atomically: true, encoding: .utf8)

        try rootfs.delete("/test.txt")
        XCTAssertFalse(rootfs.exists("/test.txt"))
        let whiteout = rootfs.whiteoutPath + "/test.txt"
        XCTAssertTrue(FileManager.default.fileExists(atPath: whiteout))
    }

    func testDeleteOverlayFile() throws {
        try rootfs.mount()
        let overlayFile = rootfs.overlayPath + "/test.txt"
        try? "overlay data".write(toFile: overlayFile, atomically: true, encoding: .utf8)

        try rootfs.delete("/test.txt")
        XCTAssertFalse(rootfs.exists("/test.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlayFile))
    }

    // MARK: - 目录操作

    func testCreateDirectory() throws {
        try rootfs.mount()
        try rootfs.createDirectory("/newdir")
        let overlayDir = rootfs.overlayPath + "/newdir"
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayDir, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testListDirectory() throws {
        try rootfs.mount()
        // 在 rootfs 创建文件
        try? "a".write(toFile: rootfs.rootfsPath + "/file1.txt", atomically: true, encoding: .utf8)
        // 在 overlay 创建文件
        try? "b".write(toFile: rootfs.overlayPath + "/file2.txt", atomically: true, encoding: .utf8)

        let entries = try rootfs.listDirectory("/")
        XCTAssertTrue(entries.contains("file1.txt"))
        XCTAssertTrue(entries.contains("file2.txt"))
    }

    func testListDirectoryWithWhiteout() throws {
        try rootfs.mount()
        try? "a".write(toFile: rootfs.rootfsPath + "/file1.txt", atomically: true, encoding: .utf8)
        try? "b".write(toFile: rootfs.rootfsPath + "/file2.txt", atomically: true, encoding: .utf8)

        // 删除 file1.txt
        try rootfs.delete("/file1.txt")

        let entries = try rootfs.listDirectory("/")
        XCTAssertFalse(entries.contains("file1.txt"))
        XCTAssertTrue(entries.contains("file2.txt"))
    }

    // MARK: - 路径转换

    func testToLinuxPath() throws {
        try rootfs.mount()
        let hostPath = rootfs.rootfsPath + "/bin/sh"
        let linuxPath = rootfs.toLinuxPath(hostPath)
        XCTAssertEqual(linuxPath, "/bin/sh")
    }

    func testToLinuxPathRoot() throws {
        try rootfs.mount()
        let hostPath = rootfs.rootfsPath
        let linuxPath = rootfs.toLinuxPath(hostPath)
        XCTAssertEqual(linuxPath, "/")
    }

    func testHostPath() throws {
        try rootfs.mount()
        let hostPath = rootfs.hostPath(for: "/bin")
        XCTAssertTrue(hostPath.hasSuffix("/bin"))
    }

    // MARK: - File Stat

    func testFileStat() throws {
        try rootfs.mount()
        let file = rootfs.rootfsPath + "/stat_test.txt"
        try? "data".write(toFile: file, atomically: true, encoding: .utf8)

        let st = rootfs.fileStat("/stat_test.txt")
        XCTAssertNotNil(st)
        XCTAssertEqual(st!.st_size, 4)
    }

    func testFileStatNotFound() throws {
        try rootfs.mount()
        let st = rootfs.fileStat("/nonexistent.txt")
        XCTAssertNil(st)
    }

    // MARK: - Sandbox Root

    func testDefaultSandboxRoot() {
        let sandbox = RootFS.defaultSandboxRoot()
        XCTAssertFalse(sandbox.isEmpty)
        XCTAssertTrue(sandbox.contains("isy"))
    }

    // MARK: - 路径清理

    func testSanitizedPath() throws {
        try rootfs.mount()
        let hostPath = rootfs.hostPath(for: "/bin/../etc/passwd")
        // 路径清理后不应包含 ..
        XCTAssertFalse(hostPath.contains(".."))
    }

    // MARK: - 版本管理

    func testVersionFile() throws {
        try rootfs.mount()
        let versionFile = rootfs.sandboxRoot + "/.version"
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionFile))
        if let version = try? String(contentsOfFile: versionFile, encoding: .utf8) {
            XCTAssertEqual(version, rootfs.version)
        }
    }
}