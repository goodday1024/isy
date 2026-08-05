// Emulator.swift - isy 顶层运行时
//
// 职责:
//   1. 加载 ARM64 Linux ELF 到隔离地址空间
//   2. 对可执行段做 binary patching (SVC -> BL __isy_syscall_trap)
//   3. 把可执行段从 RW 切换为 R-X (W^X 合规)
//   4. 构造 Linux 启动栈 (argc/argv/envp/auxv)
//   5. 安装 syscall dispatcher
//   6. 调用 isy_enter_linux 进入 Linux 代码原生执行
//
// 注意: 真正的 isy_enter_linux 只在 arm64 平台可用. 在非 arm64 平台
// (如 Linux x86_64 测试环境), load + patch 逻辑可完整运行, run() 会返回
// 平台不支持错误.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import isyCHot

/// isy 顶层运行时
public final class Emulator {
    public let process: LinuxProcess
    public let dispatcher: SyscallDispatcher
    public var patchTable: PatchTable = PatchTable()
    public var config: EmulatorConfig

    /// 已加载的 ELF 镜像 (主程序)
    public private(set) var mainImage: ELFImage?

    /// 动态链接器 (如果主程序是动态链接的)
    public private(set) var dynamicLinker: DynamicLinker?

    /// Trampoline 虚拟地址 (SVC -> BL trampoline -> MOVZ/MOVK/BR __isy_syscall_trap)
    public private(set) var trampolineVA: UInt64 = 0

    /// 全局共享 trampoline 地址 (供 execve 复用)
    nonisolated(unsafe) public static var sharedTrampolineVA: UInt64 = 0

    public init(config: EmulatorConfig = .default) {
        self.config = config
        self.process = LinuxProcess(pid: 1)
        self.dispatcher = SyscallDispatcher(process: process)
        self.dispatcher.registerCoreSyscalls(process: process)
        _ = isy_runtime_anchor()
    }

    /// 加载主程序 ELF (支持静态和动态链接)
    /// - Parameters:
    ///   - data: ELF 文件原始字节
    ///   - argv: 命令行参数 (argv[0] 通常是程序名)
    ///   - envp: 环境变量
    ///   - loadLibrary: 加载共享库的回调 (从 RootFS 读取 .so 文件)
    /// - Returns: 入口点 VA
    @discardableResult
    public func loadMain(_ data: Data, argv: [String] = [], envp: [String] = [],
                         loadLibrary: ((String) throws -> Data)? = nil) throws -> UInt64 {
        // 0. 设置 trampoline (解决 BL ±128MB 范围限制)
        try setupTrampoline()

        // 1. 解析 ELF
        let baseVA = config.loadBase
        let image = try ELFParser.parse(data: data, baseAddress: baseVA)

        // 2. 加载 PT_LOAD 段
        var execSegments: [(region: MemoryRegion, segIndex: Int, phdr: ELF64ProgramHeader)] = []
        var allSegments: [(region: MemoryRegion, segIndex: Int, phdr: ELF64ProgramHeader)] = []
        for (i, ph) in image.loadSegments.enumerated() {
            let region = try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                try process.addressSpace.loadELFSegment(
                    data: buf.baseAddress!, phdr: ph, baseVA: baseVA, segIndex: i
                )
            }
            allSegments.append((region, i, ph))
            if ph.isExecutable {
                execSegments.append((region, i, ph))
            }
        }
        process.addressSpace.codeBase = baseVA

        // 3. 动态链接: 加载解释器和依赖库
        var interpreterEntry: UInt64?
        if let interpPath = image.interp, let loadLib = loadLibrary {
            let dynamicLinker = DynamicLinker(
                rootfs: process.rootfs,
                addressSpace: process.addressSpace
            )
            process.dynamicLinker = dynamicLinker
            self.dynamicLinker = dynamicLinker

            // 确定主要段的主机基址
            guard let mainHostBase = allSegments.first?.region.base else {
                throw ELFError.invalidProgramHeader
            }

            // 加载解释器 (ld-linux-aarch64.so.1)
            let interpData = try loadLib(interpPath)
            let interpBase = config.interpBase
            let interpImage = try ELFParser.parse(data: interpData, baseAddress: interpBase)
            let interpEntry = interpImage.entryPoint

            // 加载解释器的 PT_LOAD 段
            var interpExecSegments: [(region: MemoryRegion, segIndex: Int, phdr: ELF64ProgramHeader)] = []
            for (i, ph) in interpImage.loadSegments.enumerated() {
                let region = try interpData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                    try process.addressSpace.loadELFSegment(
                        data: buf.baseAddress!, phdr: ph, baseVA: interpBase, segIndex: 100 + i
                    )
                }
                if ph.isExecutable {
                    interpExecSegments.append((region, i, ph))
                }
            }

            // 加载依赖库
            _ = try dynamicLinker.loadDependencies(
                of: image, mainBase: baseVA, mainHostBase: mainHostBase, mainData: data,
                loadData: loadLib
            )

            // 对解释器可执行段做 binary patching
            let interpPatchConfig = PatchConfig(trapAddress: trampolineVA)
            for seg in interpExecSegments {
                let patchStartVA = seg.phdr.vaddr + interpBase
                let patchByteSize = Int(seg.phdr.filesz)
                let patchCount = patchByteSize / 4
                guard let stream = process.addressSpace.instructionStream(
                    for: seg.region, baseVA: patchStartVA
                ) else { continue }
                let subStream = UnsafeMutableBufferPointer<UInt32>(
                    start: stream.baseAddress, count: min(patchCount, stream.count)
                )
                try BinaryPatcher.patchSegment(
                    subStream, baseVA: patchStartVA, config: interpPatchConfig,
                    segmentIndex: seg.segIndex, into: &patchTable
                )
            }

            // 对解释器段做 W^X 切换
            for seg in interpExecSegments {
                try process.addressSpace.makeExecutable(seg.region)
            }

            // 对每个加载的库做重定位
            for lib in dynamicLinker.libraries {
                _ = try dynamicLinker.relocate(
                    image: lib.image, base: lib.baseAddress,
                    hostPtr: lib.hostBase, data: interpData
                )
            }

            // 执行 .init_array
            dynamicLinker.runInitArrays(
                image: interpImage, base: interpBase,
                hostPtr: interpExecSegments.first?.region.base ?? mainHostBase,
                data: interpData
            )

            interpreterEntry = interpEntry
        }

        // 4. 对每个可执行段做 binary patching
        // 使用 trampoline 地址 (而非真实 trap 地址), 解决 BL ±128MB 范围限制
        let patchConfig = PatchConfig(trapAddress: trampolineVA)

        for seg in execSegments {
            // 计算 patch 范围: 只 patch filesz 部分 (memsz 多出的 BSS 不算)
            let patchStartVA = seg.phdr.vaddr + baseVA
            let patchByteSize = Int(seg.phdr.filesz)
            let patchCount = patchByteSize / 4

            guard let stream = process.addressSpace.instructionStream(
                for: seg.region, baseVA: patchStartVA
            ) else { continue }

            // 取出实际的指令子范围 (只 patch filesz)
            let subStream = UnsafeMutableBufferPointer<UInt32>(
                start: stream.baseAddress, count: min(patchCount, stream.count)
            )
            try BinaryPatcher.patchSegment(
                subStream, baseVA: patchStartVA, config: patchConfig,
                segmentIndex: seg.segIndex, into: &patchTable
            )
        }

        // 5. flush I-cache + 切换可执行段为 R-X (W^X)
        for seg in execSegments {
            try process.addressSpace.makeExecutable(seg.region)
        }

        // 6. 构造启动栈
        let stackRegion = try process.addressSpace.allocateAnonymous(
            size: config.stackSize, prot: [.read, .write],
            vaHint: config.stackBase, backing: .stack
        )
        try setupStartupStack(stackRegion: stackRegion, argv: argv, envp: envp)

        process.mainImage = image
        self.mainImage = image

        // 如果是动态链接的, 入口点是解释器而非主程序
        if let interpEntry = interpreterEntry {
            // 将主程序入口信息通过 auxv 传递给解释器
            process.cpu.pc = interpEntry
            return interpEntry
        }
        return image.entryPoint
    }

    /// 构造 Linux 进程启动栈 (argc/argv/envp/auxv)
    private func setupStartupStack(stackRegion: MemoryRegion, argv: [String], envp: [String]) throws {
        let stackTop = stackRegion.vaBase + UInt64(stackRegion.size) - 16
        var sp = stackTop
        let base = stackRegion.base

        // 1. 写入 argv/envp 字符串 (从栈顶往下)
        var argvPtrs: [UInt64] = []
        var envpPtrs: [UInt64] = []
        for a in argv {
            sp -= UInt64(a.utf8.count + 1)
            let off = Int(sp - stackRegion.vaBase)
            let bytes = Array(a.utf8) + [0]
            for (i, b) in bytes.enumerated() {
                base.advanced(by: off + i).assumingMemoryBound(to: UInt8.self).pointee = b
            }
            argvPtrs.append(sp)
        }
        for e in envp {
            sp -= UInt64(e.utf8.count + 1)
            let off = Int(sp - stackRegion.vaBase)
            let bytes = Array(e.utf8) + [0]
            for (i, b) in bytes.enumerated() {
                base.advanced(by: off + i).assumingMemoryBound(to: UInt8.self).pointee = b
            }
            envpPtrs.append(sp)
        }

        // 2. 对齐到 16
        sp &= ~UInt64(15)

        // 3. 写 auxv (简化: AT_PAGESZ, AT_NULL)
        // AT_PAGESZ=6, AT_NULL=0
        sp -= 16
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 0)   // AT_NULL type
        writeU64(base: base, va: sp + 8, stackVA: stackRegion.vaBase, value: 0) // AT_NULL value
        sp -= 16
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 6)    // AT_PAGESZ
        writeU64(base: base, va: sp + 8, stackVA: stackRegion.vaBase, value: 4096)

        // 4. envp 指针数组 (NULL 结尾)
        sp -= 8
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 0)  // NULL
        for p in envpPtrs.reversed() {
            sp -= 8
            writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: p)
        }

        // 5. argv 指针数组 (NULL 结尾)
        sp -= 8
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: 0)  // NULL
        for p in argvPtrs.reversed() {
            sp -= 8
            writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: p)
        }

        // 6. argc
        sp -= 8
        writeU64(base: base, va: sp, stackVA: stackRegion.vaBase, value: UInt64(argv.count))

        // 最终 sp 对齐到 16
        sp &= ~UInt64(15)

        process.cpu.sp = sp
        process.cpu.pc = mainImage?.entryPoint ?? 0
        process.cpu.x0 = UInt64(argv.count)
        process.cpu.x1 = sp + 8           // argv
        process.cpu.x2 = sp + 8 + UInt64(argv.count + 1) * 8  // envp
        process.cpu.x3 = 0                 // auxv (简化)
        process.stackTop = stackTop
    }

    private func writeU64(base: UnsafeMutableRawPointer, va: UInt64, stackVA: UInt64, value: UInt64) {
        let off = Int(va - stackVA)
        base.advanced(by: off).assumingMemoryBound(to: UInt64.self).pointee = value
    }

    /// 设置 trampoline 页面: 在 loadBase 处分配一页, 写入跳转到 __isy_syscall_trap 的代码
    /// 然后将 loadBase 后移一页, 使 ELF 代码加载在 trampoline 之后
    /// SVC #0 -> BL trampoline (短距离) -> MOVZ/MOVK/BR __isy_syscall_trap (任意距离)
    private func setupTrampoline() throws {
        #if arch(arm64)
        // 如果已经设置过, 跳过 (execve 复用)
        if trampolineVA != 0 { return }

        let trapAddr = UInt64(isy_get_trap_address())

        // 在 loadBase 处分配一页 trampoline
        let trampSize = 0x1000
        // mmap hint 参数: Darwin 是 UnsafeMutableRawPointer?, Glibc 是 UnsafeMutableRawPointer?
        // 通过 Int -> bitPattern 转换为指针
        let hint = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(config.loadBase)))
        let trampPtr = mmap(
            hint,
            trampSize,
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS,
            -1, 0
        )
        guard trampPtr != MAP_FAILED else {
            throw ELFError.mmapFailed
        }

        // 写入 trampoline 代码
        BinaryPatcher.writeTrampoline(to: trapAddr, at: trampPtr)

        // Flush I-cache
        #if canImport(Darwin)
        sys_icache_invalidate(trampPtr, 16)
        #endif

        // W^X: 切换为 R-X
        mprotect(trampPtr, trampSize, PROT_READ | PROT_EXEC)

        trampolineVA = config.loadBase
        Emulator.sharedTrampolineVA = trampolineVA

        // ELF 代码加载在 trampoline 之后 (loadBase + 0x1000)
        config.loadBase += UInt64(trampSize)
        #else
        // 非 arm64: 不需要 trampoline (不执行原生代码)
        trampolineVA = config.loadBase
        Emulator.sharedTrampolineVA = trampolineVA
        #endif
    }

    /// 运行 (只在 arm64 平台可用)
    /// - Returns: 进程退出码
    public func run() -> Int32 {
        #if arch(arm64)
        dispatcher.install()
        guard let entry = mainImage?.entryPoint else { return -1 }
        let stackBase = process.addressSpace.regions.first {
            if case .stack = $0.backing { return true }
            return false
        }?.base
        let r = isy_enter_linux(UInt(entry), &process.cpu.raw, stackBase)
        return Int32(truncatingIfNeeded: r)
        #else
        // 非 arm64 平台: 仅返回错误 (load/patch 已完成, 可供测试)
        return -1
        #endif
    }

    /// 统计信息 (供性能分析)
    public var stats: (syscalls: UInt64, traps: UInt64, icacheFlushes: UInt64) {
        let s = isy_get_stats().pointee
        return (s.syscalls, s.traps, s.icache_flushes)
    }
}

/// Emulator 配置
public struct EmulatorConfig: Sendable {
    /// Linux 代码加载基址 (PIE)
    public var loadBase: UInt64 = 0x10000000   // 256MB
    /// 解释器 (ld-linux) 加载基址
    public var interpBase: UInt64 = 0x20000000  // 512MB
    /// 主线程栈基址
    public var stackBase: UInt64 = 0x70000000_00000000  // 7TB (iOS 高地址区)
    /// 栈大小
    public var stackSize: Int = 8 * 1024 * 1024  // 8MB
    /// 是否启用 MRS/MSR trap (第一版关闭)
    public var patchSystemRegisters: Bool = false

    public static let `default` = EmulatorConfig()
}
