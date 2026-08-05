// Memory.swift - isy 内存管理: 隔离的 Linux 进程地址空间
//
// 设计:
//   - 给每个 Linux "进程" 分配一段连续的大块虚拟地址空间 (通过 mmap)
//   - 在该空间内加载 ELF 的 PT_LOAD 段
//   - 对可执行段: 先 mmap RW -> 加载内容 -> binary patch (SVC->BL) ->
//     mprotect RX -> flush I-cache. 这是 W^X 合规路径 (非 JIT)
//   - 对数据段: mmap RW
//   - 维护段映射表 (VA range -> mmap region), 供翻译层查询
//
// iOS mmap 行为:
//   - POSIX mmap/mprotect 在 iOS 上完全可用
//   - 不能同时 W+X (W^X 原则), 但 RW -> RX 切换是允许的
//   - 不能用 MAP_JIT (那是给 Safari JavaScriptCore 的)
//   - 我们对静态 ELF 代码做局部 patch (非运行时生成), 完全合规
//
// 跨平台:
//   - mmap/mprotect 在 Linux/macOS/iOS 都可用, 本文件可直接编译测试
//   - 在 Linux x86_64 上无法真正执行 arm64 代码, 但内存/patch 逻辑可测

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import isyCHot

/// Linux 进程地址空间中的一个内存区域
public struct MemoryRegion {
    public let base: UnsafeMutableRawPointer
    public let size: Int
    public let prot: ProtFlags
    public let vaBase: UInt64    // 该区域对应的 Linux 虚拟地址基址
    public let backing: BackingKind

    public enum BackingKind {
        case elfSegment(index: Int)   // ELF PT_LOAD 段
        case heap                      // brk/mmap 堆
        case stack                     // 主线程栈
        case anonymous                 // mmap MAP_ANONYMOUS
    }

    public var vaEnd: UInt64 { vaBase + UInt64(size) }
    public func contains(va: VA) -> Bool { va.raw >= vaBase && va.raw < vaEnd }
}

/// 内存映射错误
public enum MemoryError: Error {
    case mmapFailed(errno: Int32)
    case mprotectFailed(errno: Int32, addr: UInt64, size: Int)
    case regionConflict(va: UInt64, size: Int)
    case outOfAddressSpace
}

/// Linux 进程地址空间
public final class LinuxAddressSpace {
    /// 已分配的内存区域 (按 vaBase 排序)
    public var regions: [MemoryRegion] = []

    /// Linux 代码加载基址 (PIE 用, 实际地址由 mmap 决定)
    /// 注意: 必须保证此地址到 __isy_syscall_trap 的距离 < 128MB (BL 范围)
    public var codeBase: UInt64 = 0

    /// 堆栈顶 (Linux 主线程栈)
    public var stackTop: UInt64 = 0

    public init() {}

    /// 分配一段匿名内存 (用于栈/堆)
    /// - Parameters:
    ///   - size: 字节数 (会向上对齐到页大小)
    ///   - prot: 保护标志
    ///   - vaHint: 期望的虚拟地址 (MAP_FIXED, 0 表示由内核选择)
    ///   - backing: 区域类型
    /// - Returns: 实际分配的区域
    public func allocateAnonymous(
        size: Int, prot: ProtFlags,
        vaHint: UInt64 = 0,
        backing: MemoryRegion.BackingKind = .anonymous
    ) throws -> MemoryRegion {
        let pageSize = Int(getpagesize())
        let alignedSize = (size + pageSize - 1) & ~(pageSize - 1)

        var posixProt: Int32 = 0
        if prot.contains(.read)  { posixProt |= PROT_READ }
        if prot.contains(.write) { posixProt |= PROT_WRITE }
        if prot.contains(.exec)  { posixProt |= PROT_EXEC }

        var flags: Int32 = MAP_PRIVATE | MAP_ANONYMOUS
        if vaHint != 0 { flags |= MAP_FIXED }

        let hintPtr = UnsafeMutableRawPointer(bitPattern: UInt(vaHint))
        let mmapResult = mmap(hintPtr, alignedSize, posixProt, flags, -1, 0)
        guard let ptr = mmapResult,
              ptr != UnsafeMutableRawPointer(bitPattern: UInt.max) else {
            throw MemoryError.mmapFailed(errno: errno)
        }

        let region = MemoryRegion(
            base: ptr, size: alignedSize, prot: prot,
            vaBase: vaHint != 0 ? vaHint : UInt64(UInt(bitPattern: ptr)),
            backing: backing
        )
        regions.append(region)
        regions.sort { $0.vaBase < $1.vaBase }
        return region
    }

    /// 加载 ELF PT_LOAD 段到内存
    /// - Parameters:
    ///   - segment: ELF 段数据 (filesz 字节)
    ///   - phdr: ELF program header
    ///   - baseVA: 加载基址 (PIE 时由 caller 决定)
    ///   - segIndex: 段索引
    /// - Returns: 加载后的区域
    public func loadELFSegment(
        data: UnsafeRawPointer, phdr: ELF64ProgramHeader,
        baseVA: UInt64, segIndex: Int
    ) throws -> MemoryRegion {
        let pageSize = Int(getpagesize())
        let pageStart = Int(phdr.vaddr) & ~(pageSize - 1)
        let pageEnd = (Int(phdr.vaddr + phdr.memsz) + pageSize - 1) & ~(pageSize - 1)
        let mapSize = pageEnd - pageStart

        // 段权限: 先 RW (要写内容 + patch), 后续通过 makeExecutable 改 R/RX
        // iOS: 可执行段必须用 MAP_JIT flag, 否则执行运行时修改的代码会 crash
        let isExec = phdr.isExecutable
        var posixProt: Int32 = PROT_READ | PROT_WRITE
        // 不在此处加 PROT_EXEC, patch 完成后由 makeExecutable 开启

        var flags: Int32 = MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED
        if isExec {
            // iOS 可执行段: 添加 MAP_JIT flag
            flags |= Int32(isy_map_jit_flag())
            // iOS MAP_JIT 内存: 切换为可写模式以加载代码
            isy_jit_write_protect(0)
        }

        let va = baseVA + UInt64(pageStart)
        let hintPtr = UnsafeMutableRawPointer(bitPattern: UInt(va))
        let mmapResult = mmap(hintPtr, mapSize, posixProt, flags, -1, 0)
        guard let ptr = mmapResult,
              ptr != UnsafeMutableRawPointer(bitPattern: UInt.max) else {
            if isExec { isy_jit_write_protect(1) }  // 恢复
            throw MemoryError.mmapFailed(errno: errno)
        }

        // 拷贝 filesz 字节
        let fileOffset = Int(phdr.offset)
        let copyOffset = Int(phdr.vaddr) - pageStart
        memcpy(ptr.advanced(by: copyOffset), data.advanced(by: fileOffset), Int(phdr.filesz))
        // memsz > filesz 的部分 (BSS) 清零 (mmap MAP_ANONYMOUS 默认零, 但 copyOffset 之后可能有残留)
        let bssStart = copyOffset + Int(phdr.filesz)
        let bssEnd = copyOffset + Int(phdr.memsz)
        if bssStart < bssEnd {
            memset(ptr.advanced(by: bssStart), 0, bssEnd - bssStart)
        }

        // iOS: 写入完成, 保持可写状态 (binary patching 还需要写入)
        // makeExecutable 会在 patch 完成后切换为可执行
        // 注意: isy_jit_write_protect(0) 已在上方调用, 保持可写

        let region = MemoryRegion(
            base: ptr, size: mapSize,
            prot: ProtFlags(rawValue: Int32(phdr.flags & 7)),
            vaBase: va,
            backing: .elfSegment(index: segIndex)
        )
        regions.append(region)
        regions.sort { $0.vaBase < $1.vaBase }
        return region
    }

    /// 把一个区域改为只读+可执行 (patch 完成后调用, 实现 W^X)
    public func makeExecutable(_ region: MemoryRegion) throws {
        let jitFlag = isy_map_jit_flag()
        if jitFlag != 0 {
            // iOS (MAP_JIT): 权限由 pthread_jit_write_protect_np 控制, 不用 mprotect
            // binary patching 已在 isy_jit_write_protect(0) 下完成, 现在切换为可执行
            isy_jit_write_protect(1)
        } else {
            // macOS/Linux: 用 mprotect 切换为 R-X
            var posixProt: Int32 = PROT_READ
            if region.prot.contains(.exec) { posixProt |= PROT_EXEC }
            let r = mprotect(region.base, region.size, posixProt)
            if r != 0 {
                throw MemoryError.mprotectFailed(errno: errno, addr: region.vaBase, size: region.size)
            }
        }
        // flush I-cache (自修改代码必须!)
        isy_arm64_flush_icache(region.base, region.size)
    }

    /// 把一个区域改为只读 (RELRO 段用)
    public func makeReadOnly(_ region: MemoryRegion) throws {
        let r = mprotect(region.base, region.size, PROT_READ)
        if r != 0 {
            throw MemoryError.mprotectFailed(errno: errno, addr: region.vaBase, size: region.size)
        }
    }

    /// 查找包含指定 VA 的区域
    public func region(for va: VA) -> MemoryRegion? {
        // 二分查找 (regions 按 vaBase 排序)
        var lo = 0, hi = regions.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let r = regions[mid]
            if va.raw < r.vaBase {
                hi = mid - 1
            } else if va.raw >= r.vaEnd {
                lo = mid + 1
            } else {
                return r
            }
        }
        return nil
    }

    /// 把 VA 转为宿主指针 (用于读写 Linux 内存)
    public func hostPointer(for va: VA, size: Int = 1) -> UnsafeMutableRawPointer? {
        guard let r = region(for: va) else { return nil }
        let offset = Int(va.raw - r.vaBase)
        guard offset + size <= r.size else { return nil }
        return r.base.advanced(by: offset)
    }

    /// 获取一个可执行段的 32-bit 指令流视图 (供 BinaryPatcher 使用)
    public func instructionStream(
        for region: MemoryRegion, baseVA: UInt64
    ) -> UnsafeMutableBufferPointer<UInt32>? {
        guard case .elfSegment = region.backing else { return nil }
        guard region.prot.contains(.exec) else { return nil }
        let count = region.size / 4
        return UnsafeMutableBufferPointer(
            start: region.base.assumingMemoryBound(to: UInt32.self),
            count: count
        )
    }

    /// 移除所有区域 (用于 execve 后清理旧地址空间)
    public func removeAllRegions() {
        for r in regions {
            munmap(r.base, r.size)
        }
        regions.removeAll()
    }

    /// 获取栈区域
    public var stackRegion: MemoryRegion? {
        regions.first { if case .stack = $0.backing { return true }; return false }
    }

    /// 释放所有区域
    deinit {
        for r in regions {
            munmap(r.base, r.size)
        }
    }
}
