// RootFS.swift - isy 根文件系统管理
//
// 设计:
//   - App bundle 内打包一个 ARM64 Linux rootfs (squashfs 或 tar.gz)
//     推荐 Alpine Linux (体积小 ~3MB base, 完整 ~50MB)
//   - 首次启动时解压到沙盒目录 (NSCachesDirectory/isy/rootfs)
//   - 路径映射: Linux "/" -> 沙盒 rootfs/ 目录
//   - OverlayFS 语义: rootfs 本身只读, 上层 rw 层 (rootfs.overlay) 接收写入
//     这样可以用一个压缩 rootfs 镜像服务多次启动, 写入隔离
//
// 文件系统层次:
//   $CACHES/isy/
//   ├── rootfs/                    解压后的只读 rootfs
//   │   ├── bin/  etc/  lib/  usr/  ...
//   └── overlay/                   可写覆盖层 (用户安装的包/配置)
//
// 跨平台:
//   - 在 Linux 测试环境, rootfs 路径指向 /tmp/isy/rootfs (用于跑测试)
//   - 在 iOS, 用 NSSearchPathForDirectoriesInDomains

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// RootFS 错误
public enum RootFSError: Error {
    case bundleResourceMissing(String)
    case extractFailed(String)
    case checksumMismatch
    case notMounted
}

/// 根文件系统管理
public final class RootFS {
    /// 沙盒根目录 (宿主路径)
    public let sandboxRoot: String
    /// 只读 rootfs 解压目录
    public var rootfsPath: String { sandboxRoot + "/rootfs" }
    /// 可写覆盖层目录
    public var overlayPath: String { sandboxRoot + "/overlay" }
    /// rootfs 版本 (用于增量更新判断)
    public var version: String = "0.1.0"
    /// 是否已挂载
    public private(set) var isMounted: Bool = false

    public init(sandboxRoot: String? = nil) {
        if let s = sandboxRoot {
            self.sandboxRoot = s
        } else {
            self.sandboxRoot = RootFS.defaultSandboxRoot()
        }
    }

    /// 默认沙盒根目录 (跨平台)
    public static func defaultSandboxRoot() -> String {
        #if canImport(Darwin) && !os(Linux)
        // iOS/macOS: NSCachesDirectory
        if let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first {
            return caches + "/isy"
        }
        return NSTemporaryDirectory() + "isy"
        #else
        // Linux 测试环境
        return "/tmp/isy"
        #endif
    }

    /// 挂载 rootfs (首次启动解压, 后续直接复用)
    /// - Parameter bundledArchive: App bundle 内的 rootfs 归档文件名 (如 "rootfs.tar.gz")
    public func mount(bundledArchive: String = "rootfs.tar.gz") throws {
        guard !isMounted else { return }

        // 创建目录
        try mkdirP(sandboxRoot)
        try mkdirP(rootfsPath)
        try mkdirP(overlayPath)

        // 检查是否已解压 (通过版本文件判断)
        let versionFile = sandboxRoot + "/.version"
        if let existing = try? String(contentsOfFile: versionFile, encoding: .utf8),
           existing == version {
            isMounted = true
            return
        }

        // 解压 bundled rootfs
        let archivePath = locateBundleResource(bundledArchive)
        guard let archivePath = archivePath else {
            // bundle 内没有 rootfs 时, 创建一个最小占位结构 (便于测试)
            try createMinimalRootfs()
            try? version.write(toFile: versionFile, atomically: true, encoding: .utf8)
            isMounted = true
            return
        }

        try extractArchive(archivePath, to: rootfsPath)
        try version.write(toFile: versionFile, atomically: true, encoding: .utf8)
        isMounted = true
    }

    /// 卸载 (清理)
    public func unmount() {
        // 只清理 overlay, rootfs 保留 (避免重复解压)
        let _ = try? FileManager.default.removeItem(atPath: overlayPath)
        try? mkdirP(overlayPath)
        isMounted = false
    }

    /// 把 Linux 路径解析为宿主真实路径
    /// - Parameter linuxPath: Linux 视角路径 (如 "/bin/sh")
    /// - Returns: 宿主路径 (overlay 优先, 再 rootfs)
    public func resolve(_ linuxPath: String) -> String {
        var p = linuxPath
        if p.hasPrefix("/") { p.removeFirst() }
        let overlay = overlayPath + "/" + p
        let rootfs = rootfsPath + "/" + p
        // overlay 存在则优先 (覆盖层语义)
        if FileManager.default.fileExists(atPath: overlay) {
            return overlay
        }
        return rootfs
    }

    /// 反向: 把宿主 rootfs 内的路径转成 Linux 路径
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

    /// 在 overlay 层创建一个文件 (用于写操作)
    public func createOverlayFile(linuxPath: String) throws -> String {
        var p = linuxPath
        if p.hasPrefix("/") { p.removeFirst() }
        let target = overlayPath + "/" + p
        let dir = (target as NSString).deletingLastPathComponent
        try mkdirP(dir)
        if !FileManager.default.fileExists(atPath: target) {
            FileManager.default.createFile(atPath: target, contents: nil)
        }
        return target
    }

    // MARK: - 内部
    private func locateBundleResource(_ name: String) -> String? {
        #if canImport(Darwin) && !os(Linux)
        if let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                      withExtension: (name as NSString).pathExtension) {
            return url.path
        }
        #endif
        // 开发/测试环境: 检查项目根目录
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

    private func extractArchive(_ archive: String, to dest: String) throws {
        #if canImport(Glibc)
        // Linux: 用系统 tar
        let task = Process()
        task.launchPath = "/bin/tar"
        task.arguments = ["-xzf", archive, "-C", dest]
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw RootFSError.extractFailed("tar exited \(task.terminationStatus)")
        }
        #else
        // Darwin: 用 FileManager 解压 (或调系统 tar)
        let task = Process()
        task.launchPath = "/usr/bin/tar"
        task.arguments = ["-xzf", archive, "-C", dest]
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw RootFSError.extractFailed("tar exited \(task.terminationStatus)")
        }
        #endif
    }

    /// 创建最小占位 rootfs (无 bundle 资源时, 用于测试)
    private func createMinimalRootfs() throws {
        let dirs = ["bin", "etc", "lib", "usr/bin", "usr/lib", "tmp", "var", "home", "proc", "sys", "dev"]
        for d in dirs {
            try mkdirP(rootfsPath + "/" + d)
        }
        // 写一个最小 /etc/os-release
        let osRelease = """
        NAME="isy"
        VERSION="\(version)"
        ID=isy
        PRETTY_NAME="isy \(version) (Alpine-based)"
        """
        try osRelease.write(toFile: rootfsPath + "/etc/os-release", atomically: true, encoding: .utf8)
    }

    private func mkdirP(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
    }
}
