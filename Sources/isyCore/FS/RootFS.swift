// RootFS.swift - isy 根文件系统管理 (完整实现: OverlayFS 写时复制 + 纯 Swift tar 解压)
//
// 设计:
//   - App bundle 内打包一个 ARM64 Linux rootfs (tar.gz)
//   - 首次启动时解压到沙盒目录 (NSCachesDirectory/isy/rootfs)
//   - 路径映射: Linux "/" -> 沙盒 rootfs/ 目录
//   - OverlayFS 语义: rootfs 本身只读, 上层 rw 层 (rootfs.overlay) 接收写入
//   - 写时复制 (CoW): 对 rootfs 中的文件写入时, 先在 overlay 创建副本
//   - 删除: 在 overlay 创建 whiteout 文件标记删除
//   - 纯 Swift tar 解压: iOS 兼容 (不支持 Process 调用 tar)
//
// 文件系统层次:
//   $CACHES/isy/
//   ├── rootfs/          解压后的只读 rootfs
//   │   ├── bin/  etc/  lib/  usr/  ...
//   └── overlay/         可写覆盖层 (用户安装的包/配置)
//       └── .whiteout/   白名单 (标记删除的文件)

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#if canImport(Compression)
import Compression
#endif
#endif

// MARK: - RootFS 错误

public enum RootFSError: Error {
    case bundleResourceMissing(String)
    case extractFailed(String)
    case checksumMismatch
    case notMounted
    case permissionDenied(String)
}

// MARK: - 文件系统操作类型

public enum FileOp {
    case read, write, append, create, truncate
}

// MARK: - 根文件系统管理

public final class RootFS: @unchecked Sendable {
    public let sandboxRoot: String
    public var rootfsPath: String { sandboxRoot + "/rootfs" }
    public var overlayPath: String { sandboxRoot + "/overlay" }
    public var whiteoutPath: String { overlayPath + "/.whiteout" }
    public var version: String = "0.1.0"
    public private(set) var isMounted: Bool = false

    public init(sandboxRoot: String? = nil) {
        if let s = sandboxRoot {
            self.sandboxRoot = s
        } else {
            self.sandboxRoot = RootFS.defaultSandboxRoot()
        }
    }

    public static func defaultSandboxRoot() -> String {
        #if canImport(Darwin) && !os(Linux)
        if let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first {
            return caches + "/isy"
        }
        return NSTemporaryDirectory() + "isy"
        #else
        return "/tmp/isy"
        #endif
    }

    // MARK: - 挂载 / 卸载

    public func mount(bundledArchive: String = "rootfs.tar.gz") throws {
        guard !isMounted else { return }

        try mkdirP(sandboxRoot)
        try mkdirP(rootfsPath)
        try mkdirP(overlayPath)
        try mkdirP(whiteoutPath)

        let versionFile = sandboxRoot + "/.version"
        if let existing = try? String(contentsOfFile: versionFile, encoding: .utf8),
           existing == version {
            isMounted = true
            return
        }

        let archivePath = locateBundleResource(bundledArchive)
        if let archivePath = archivePath {
            try extractArchive(archivePath, to: rootfsPath)
        } else {
            // 尝试从 bundle 中加载单个 busybox 作为 /bin/busybox
            try createMinimalRootfs()
            try copyBusyboxIfAvailable()
        }
        try? version.write(toFile: versionFile, atomically: true, encoding: .utf8)
        isMounted = true
    }

    public func unmount() {
        let _ = try? FileManager.default.removeItem(atPath: overlayPath)
        try? mkdirP(overlayPath)
        try? mkdirP(whiteoutPath)
        isMounted = false
    }

    // MARK: - 路径解析 (OverlayFS 核心)

    /// 把 Linux 路径解析为宿主真实路径 (读路径)
    /// overlay 存在则优先, 否则回退到 rootfs
    public func resolve(_ linuxPath: String) -> String {
        let p = sanitizedPath(linuxPath)
        let overlay = overlayPath + "/" + p
        let whiteout = whiteoutPath + "/" + p

        // 如果在 overlay 被标记删除 (whiteout), 返回 rootfs 路径但标记为不存在
        if FileManager.default.fileExists(atPath: whiteout) {
            return rootfsPath + "/" + p
        }
        // overlay 存在则优先
        if FileManager.default.fileExists(atPath: overlay) {
            return overlay
        }
        return rootfsPath + "/" + p
    }

    /// 获取写入路径 (始终返回 overlay 路径, 必要时触发 CoW)
    public func resolveForWrite(_ linuxPath: String, operation: FileOp = .write) throws -> String {
        let p = sanitizedPath(linuxPath)
        let target = overlayPath + "/" + p
        let rootfs = rootfsPath + "/" + p
        let whiteout = whiteoutPath + "/" + p

        switch operation {
        case .read:
            return resolve(linuxPath)

        case .write, .append, .create:
            let dir = (target as NSString).deletingLastPathComponent
            try mkdirP(dir)

            if !FileManager.default.fileExists(atPath: target) {
                if FileManager.default.fileExists(atPath: rootfs) {
                    try FileManager.default.copyItem(atPath: rootfs, toPath: target)
                } else {
                    FileManager.default.createFile(atPath: target, contents: nil)
                }
            }
            if FileManager.default.fileExists(atPath: whiteout) {
                try? FileManager.default.removeItem(atPath: whiteout)
            }
            return target

        case .truncate:
            let dir = (target as NSString).deletingLastPathComponent
            try mkdirP(dir)
            if !FileManager.default.fileExists(atPath: target) {
                if FileManager.default.fileExists(atPath: rootfs) {
                    try FileManager.default.copyItem(atPath: rootfs, toPath: target)
                } else {
                    FileManager.default.createFile(atPath: target, contents: nil)
                }
            }
            try Data().write(to: URL(fileURLWithPath: target))
            if FileManager.default.fileExists(atPath: whiteout) {
                try? FileManager.default.removeItem(atPath: whiteout)
            }
            return target
        }
    }

    /// 删除文件 (OverlayFS: 创建 whiteout)
    public func delete(_ linuxPath: String) throws {
        let p = sanitizedPath(linuxPath)
        let overlay = overlayPath + "/" + p
        let whiteout = whiteoutPath + "/" + p

        let dir = (whiteout as NSString).deletingLastPathComponent
        try mkdirP(dir)

        FileManager.default.createFile(atPath: whiteout, contents: nil)
        if FileManager.default.fileExists(atPath: overlay) {
            try FileManager.default.removeItem(atPath: overlay)
        }
    }

    /// 检查文件是否存在 (考虑 overlay + whiteout)
    public func exists(_ linuxPath: String) -> Bool {
        let p = sanitizedPath(linuxPath)
        let overlay = overlayPath + "/" + p
        let whiteout = whiteoutPath + "/" + p
        let rootfs = rootfsPath + "/" + p

        if FileManager.default.fileExists(atPath: whiteout) { return false }
        if FileManager.default.fileExists(atPath: overlay) { return true }
        return FileManager.default.fileExists(atPath: rootfs)
    }

    /// 获取文件属性 (stat)
    public func fileStat(_ linuxPath: String) -> stat? {
        let resolved = resolve(linuxPath)
        var st = stat()
        if stat(resolved, &st) == 0 {
            return st
        }
        return nil
    }

    /// 列出目录内容 (OverlayFS 合并视图)
    public func listDirectory(_ linuxPath: String) throws -> [String] {
        let p = sanitizedPath(linuxPath)
        let rootfsDir = rootfsPath + "/" + p
        let overlayDir = overlayPath + "/" + p
        let whiteoutDir = whiteoutPath + "/" + p

        var entries = Set<String>()

        if let items = try? FileManager.default.contentsOfDirectory(atPath: rootfsDir) {
            entries.formUnion(items)
        }
        if let items = try? FileManager.default.contentsOfDirectory(atPath: overlayDir) {
            entries.formUnion(items)
        }
        if let whiteouts = try? FileManager.default.contentsOfDirectory(atPath: whiteoutDir) {
            entries.subtract(whiteouts)
        }

        return entries.sorted()
    }

    // MARK: - 路径转换

    public func toLinuxPath(_ hostPath: String) -> String {
        var p = hostPath
        if p.hasPrefix(rootfsPath) {
            p.removeFirst(rootfsPath.count)
        } else if p.hasPrefix(overlayPath) {
            p.removeFirst(overlayPath.count)
        }
        if p.isEmpty { p = "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        return p
    }

    public func hostPath(for linuxPath: String) -> String {
        return resolve(linuxPath)
    }

    public func createOverlayFile(linuxPath: String) throws -> String {
        return try resolveForWrite(linuxPath, operation: .create)
    }

    public func createDirectory(_ linuxPath: String, mode: UInt32 = 0o755) throws {
        let p = sanitizedPath(linuxPath)
        let target = overlayPath + "/" + p
        try mkdirP(target, mode: mode)
        let whiteout = whiteoutPath + "/" + p
        if FileManager.default.fileExists(atPath: whiteout) {
            try? FileManager.default.removeItem(atPath: whiteout)
        }
    }

    public func getDirectoryHostPath(_ linuxPath: String) -> String? {
        let p = sanitizedPath(linuxPath)
        let overlay = overlayPath + "/" + p
        if FileManager.default.fileExists(atPath: overlay) { return overlay }
        let rootfs = rootfsPath + "/" + p
        if FileManager.default.fileExists(atPath: rootfs) { return rootfs }
        return nil
    }

    // MARK: - 内部

    private func sanitizedPath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/") { p.removeFirst() }
        var components = p.split(separator: "/").map(String.init)
        components = components.filter { $0 != ".." && $0 != "." }
        return components.joined(separator: "/")
    }

    private func locateBundleResource(_ name: String) -> String? {
        #if canImport(Darwin) && !os(Linux)
        if let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                      withExtension: (name as NSString).pathExtension) {
            return url.path
        }
        #endif
        let candidates = [
            sandboxRoot + "/" + name,
            "Resources/" + name,
            name,
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return nil
    }

    /// 纯 Swift 解压 tar.gz (iOS 兼容)
    private func extractArchive(_ archive: String, to dest: String) throws {
        #if canImport(Glibc) || (canImport(Darwin) && !os(iOS) && !targetEnvironment(simulator))
        // macOS/Linux: 使用系统 tar
        let task = Process()
        #if canImport(Glibc)
        task.executableURL = URL(fileURLWithPath: "/bin/tar")
        #else
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        #endif
        task.arguments = ["-xzf", archive, "-C", dest]
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw RootFSError.extractFailed("tar exited \(task.terminationStatus)")
        }
        #else
        // iOS: 纯 Swift tar.gz 解压
        try extractTarGz(archive: archive, to: dest)
        #endif
    }

    /// 纯 Swift tar.gz 解压 (iOS 兼容)
    private func extractTarGz(archive: String, to dest: String) throws {
        guard let archiveData = try? Data(contentsOf: URL(fileURLWithPath: archive)) else {
            throw RootFSError.extractFailed("无法读取归档文件: \(archive)")
        }

        // 1. 解压 gzip
        let decompressed: Data
        #if canImport(Compression)
        if #available(iOS 13.0, macOS 10.15, *) {
            decompressed = try (archiveData as NSData).decompressed(using: .zlib) as Data
        } else {
            decompressed = archiveData
        }
        #else
        // Linux/非Apple平台: 使用系统 gzip 命令
        let tmpDir = NSTemporaryDirectory() + "isy_extract_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let tmpTar = tmpDir + "/archive.tar"
        try archiveData.write(to: URL(fileURLWithPath: tmpTar + ".gz"))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/gunzip")
        task.arguments = ["-f", tmpTar + ".gz"]
        try task.run()
        task.waitUntilExit()
        decompressed = try Data(contentsOf: URL(fileURLWithPath: tmpTar))
        try? FileManager.default.removeItem(atPath: tmpDir)
        #endif

        // 2. 解析 tar
        try extractTar(data: decompressed, to: dest)
    }

    /// 纯 Swift tar 解析
    private func extractTar(data: Data, to dest: String) throws {
        var pos = 0
        let blockSize = 512

        while pos + blockSize <= data.count {
            let header = data.subdata(in: pos..<pos + blockSize)

            // 检查是否结束 (两个连续的零块)
            if header.allSatisfy({ $0 == 0 }) {
                break
            }

            // 读取文件名
            let nameBytes = header.subdata(in: 0..<100)
            guard let name = String(bytes: nameBytes, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
                  !name.isEmpty else {
                // 可能是空填充块
                pos += blockSize
                continue
            }

            // 跳过 PaxHeaders 和 GNU 长文件名
            if name.hasPrefix("./") || name.hasPrefix("PaxHeaders") {
                let sizeStr = String(bytes: header.subdata(in: 124..<136), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "0"
                let size = strtoul(sizeStr, nil, 8)
                let blocks = (Int(size) + blockSize - 1) / blockSize
                pos += blockSize * (1 + blocks)
                continue
            }

            // 读取文件大小
            let sizeStr = String(bytes: header.subdata(in: 124..<136), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "0"
            let size = strtoul(sizeStr, nil, 8)

            // 读取类型标志
            let typeFlag = header[156]

            let fullPath = dest + "/" + name
            let parentDir = (fullPath as NSString).deletingLastPathComponent
            try mkdirP(parentDir)

            let fileBlocks = (Int(size) + blockSize - 1) / blockSize

            switch typeFlag {
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                // 普通文件
                let fileData = data.subdata(in: pos + blockSize..<pos + blockSize + Int(size))
                try fileData.write(to: URL(fileURLWithPath: fullPath))
                // 设置权限
                let modeStr = String(bytes: header.subdata(in: 100..<108), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "0755"
                let mode = strtoul(modeStr, nil, 8)
                chmod(fullPath, mode_t(mode))

            case UInt8(ascii: "5"):
                // 目录
                try mkdirP(fullPath)

            case UInt8(ascii: "2"):
                // 符号链接
                if Int(size) > 0 {
                    let linkTarget = String(bytes: data.subdata(in: pos + blockSize..<pos + blockSize + Int(size)), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                    symlink(linkTarget, fullPath)
                }

            case UInt8(ascii: "1"):
                // 硬链接
                let linkName = String(bytes: header.subdata(in: 157..<257), encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
                let linkPath = dest + "/" + linkName
                link(linkPath, fullPath)

            default:
                // 未知类型, 跳过
                break
            }

            pos += blockSize * (1 + fileBlocks)
        }
    }

    /// 从 bundle 复制 busybox 到 rootfs
    private func copyBusyboxIfAvailable() throws {
        #if canImport(Darwin) && !os(Linux)
        if let url = Bundle.main.url(forResource: "busybox", withExtension: nil) {
            let dest = rootfsPath + "/bin/busybox"
            try? FileManager.default.removeItem(atPath: dest)
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: dest))
            chmod(dest, 0o755)
        }
        #endif
        // 从沙盒搜索 busybox
        let candidates = [
            sandboxRoot + "/busybox",
            sandboxRoot + "/rootfs/bin/busybox",
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) {
                return
            }
        }
    }

    private func createMinimalRootfs() throws {
        let dirs = [
            "bin", "etc", "lib", "usr/bin", "usr/lib",
            "tmp", "var", "var/run", "var/log",
            "home", "home/root", "root",
            "proc", "sys", "dev", "dev/pts",
            "mnt", "opt", "sbin", "run"
        ]
        for d in dirs {
            try mkdirP(rootfsPath + "/" + d)
        }

        // 创建基础配置文件
        let osRelease = """
        NAME="isy"
        VERSION="\(version)"
        ID=isy
        PRETTY_NAME="isy \(version) (Alpine-based)"
        """
        try osRelease.write(toFile: rootfsPath + "/etc/os-release", atomically: true, encoding: .utf8)

        let passwd = """
        root:x:0:0:root:/root:/bin/sh
        nobody:x:65534:65534:nobody:/:/sbin/nologin
        """
        try passwd.write(toFile: rootfsPath + "/etc/passwd", atomically: true, encoding: .utf8)

        let group = """
        root:x:0:
        nobody:x:65534:
        """
        try group.write(toFile: rootfsPath + "/etc/group", atomically: true, encoding: .utf8)

        let resolvConf = """
        nameserver 8.8.8.8
        nameserver 1.1.1.1
        """
        try resolvConf.write(toFile: rootfsPath + "/etc/resolv.conf", atomically: true, encoding: .utf8)

        let hostname = "isy\n"
        try hostname.write(toFile: rootfsPath + "/etc/hostname", atomically: true, encoding: .utf8)

        let hosts = """
        127.0.0.1 localhost localhost.localdomain
        ::1       localhost localhost.localdomain
        """
        try hosts.write(toFile: rootfsPath + "/etc/hosts", atomically: true, encoding: .utf8)

        let profile = """
        export PATH=/bin:/usr/bin:/sbin:/usr/sbin
        export HOME=/root
        export TERM=xterm-256color
        export PS1='\\u@\\h:\\w\\$ '
        alias ls='ls --color=auto'
        alias ll='ls -la'
        """
        try profile.write(toFile: rootfsPath + "/etc/profile", atomically: true, encoding: .utf8)

        // 创建 busybox 符号链接骨架 (如果 busybox 存在)
        if FileManager.default.fileExists(atPath: rootfsPath + "/bin/busybox") {
            let applets = ["sh", "ls", "cat", "echo", "mkdir", "rm", "cp", "mv",
                          "chmod", "chown", "ps", "kill", "mount", "umount",
                          "grep", "sed", "awk", "vi", "head", "tail", "wc",
                          "find", "xargs", "tar", "gzip", "gunzip", "dd",
                          "df", "du", "free", "top", "uptime", "id", "whoami",
                          "ping", "wget", "nc", "ifconfig", "route", "netstat",
                          "date", "cal", "sleep", "true", "false", "test",
                          "ln", "stat", "readlink", "dirname", "basename",
                          "sort", "uniq", "tr", "cut", "diff", "patch",
                          "env", "printenv", "which", "clear", "reset",
                          "tee", "yes", "seq", "expr", "printf"]
            for applet in applets {
                let linkPath = rootfsPath + "/bin/\(applet)"
                if !FileManager.default.fileExists(atPath: linkPath) {
                    symlink("busybox", linkPath)
                }
            }
        }
    }

    private func mkdirP(_ path: String, mode: UInt32 = 0o755) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: mode]
        )
    }
}