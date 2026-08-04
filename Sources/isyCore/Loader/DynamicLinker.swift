// DynamicLinker.swift - ARM64 Linux 动态链接器
//
// 职责:
//   1. 加载主程序依赖的 .so (递归处理 NEEDED)
//   2. 解析 PT_DYNAMIC 段: DT_NEEDED / DT_STRTAB / DT_SYMTAB / DT_JMPREL /
//      DT_REL(A) / DT_PLTGOT / DT_PLTRELSZ 等
//   3. 执行重定位:
//      - R_AARCH64_RELATIVE: *addr += base
//      - R_AARCH64_GLOB_DAT / R_AARCH64_JUMP_SLOT: 查符号表填地址
//      - R_AARCH64_ABS64: S + A
//   4. 处理 PLT: 把 PLT[0] 改成调用我们的延迟绑定 stub, 或在加载时全绑定
//   5. 初始化 .init_array / .fini_array
//   6. 设置 TPIDR_EL0 (TLS): 从 PT_TLS 分配 TLS 块
//
// 注意: 这是最复杂的模块之一. 完整实现 ~2000 行. 这里给出骨架 + 核心重定位.

import Foundation

/// ELF 动态段条目 (Elf64_Dyn)
public struct Elf64Dyn {
    public var tag: Int64   // DT_NEEDED=1, DT_STRTAB=5, DT_SYMTAB=6, ...
    public var val: UInt64  // tag 决定 val 是地址还是偏移
}

/// DT 标签
public enum DynTag: Int64 {
    case null = 0
    case needed = 1
    case pltrelsz = 2
    case plmgot = 3
    case hash = 4
    case strtab = 5
    case symtab = 6
    case rela = 7
    case relasz = 8
    case relaent = 9
    case strsz = 10
    case syment = 11
    case init_ = 12
    case fini = 13
    case init_array = 25
    case init_arraysz = 27
    case fini_array = 26
    case fini_arraysz = 28
    case flags_1 = 0x6ffffffb
    case gnu_hash = 0x6ffffef5
}

/// ARM64 重定位类型
public enum RelocType: UInt32 {
    case none = 0
    case abs64 = 257          // R_AARCH64_ABS64: S + A
    case copy = 1024          // R_AARCH64_COPY
    case glob_dat = 1025      // R_AARCH64_GLOB_DAT
    case jump_slot = 1026     // R_AARCH64_JUMP_SLOT (PLT)
    case relative = 1027      // R_AARCH64_RELATIVE: B + A
    case tlsdesc = 1031       // R_AARCH64_TLSDESC
    case irelative = 1032     // R_AARCH64_IRELATIVE
}

/// Elf64_Rela: r_offset, r_info (sym << 32 | type), r_addend
public struct Elf64Rela {
    public var offset: UInt64
    public var info: UInt64
    public var addend: Int64

    public var type: UInt32 { UInt32(info & 0xFFFFFFFF) }
    public var sym: UInt32 { UInt32(info >> 32) }
}

/// Elf64_Sym: st_name, st_info, st_other, st_shndx, st_value, st_size
public struct Elf64Sym {
    public var name: UInt32
    public var info: UInt8
    public var other: UInt8
    public var shndx: UInt16
    public var value: UInt64
    public var size: UInt64

    public var bind: UInt8 { info >> 4 }       // STB_LOCAL=0, STB_GLOBAL=1, STB_WEAK=2
    public var type: UInt8 { info & 0xF }      // STT_NOTYPE=0, STT_OBJECT=1, STT_FUNC=2
}

/// 已加载的共享库
public struct SharedLibrary {
    public let name: String
    public let baseAddress: UInt64
    public let image: ELFImage
    public var symbols: [String: UInt64] = [:]  // 导出符号表
}

/// 动态链接器
public final class DynamicLinker {
    public var libraries: [SharedLibrary] = []
    public var rootfs: RootFS?

    /// 全局符号表 (所有已加载库的符号汇总)
    public var globalSymbols: [String: UInt64] = [:]

    public init(rootfs: RootFS? = nil) {
        self.rootfs = rootfs
    }

    /// 加载主程序的所有依赖 (递归)
    /// - Parameters:
    ///   - mainImage: 主程序 ELF
    ///   - mainBase: 主程序加载基址
    ///   - loadData: 闭包, 给定 .so 名字返回文件字节
    public func loadDependencies(
        of mainImage: ELFImage,
        mainBase: UInt64,
        loadData: (String) throws -> Data
    ) throws -> [SharedLibrary] {
        var loaded: [String: SharedLibrary] = [:]
        var queue: [String] = mainImage.neededLibraries

        while let libName = queue.first {
            queue.removeFirst()
            if loaded[libName] != nil { continue }

            let baseAddr = nextLoadAddress()
            let data = try loadData(libName)
            let img = try ELFParser.parse(data: data, baseAddress: baseAddr)
            let lib = SharedLibrary(name: libName, baseAddress: baseAddr, image: img)

            // TODO: 实际 mmap 加载 .so 的 PT_LOAD 段到 baseAddr
            // (由 Memory.swift 完成, 这里只记录元数据)
            // 收集导出符号
            // TODO: 解析 .dynsym + .dynstr 构建符号表
            // lib.symbols = parseDynSym(...)

            loaded[libName] = lib
            libraries.append(lib)
            for sym in lib.symbols { globalSymbols[sym.key] = sym.value }
            queue.append(contentsOf: img.neededLibraries)
        }
        return Array(loaded.values)
    }

    /// 对一个镜像执行重定位
    /// - Parameters:
    ///   - image: 镜像
    ///   - base: 加载基址 (PIE 偏移)
    ///   - hostPtr: 镜像在宿主内存中的基址 (用于直接修改 GOT)
    public func relocate(image: ELFImage, base: UInt64, hostPtr: UnsafeMutableRawPointer) throws {
        // 简化骨架: 完整实现需要解析 PT_DYNAMIC, 找到 DT_RELA/DT_RELASZ
        // 然后遍历每个 Elf64_Rela, 根据 type 计算 value 写入 *(base + r_offset)
        //
        // 伪代码:
        //   let dyn = parseDynamic(image)
        //   let relas = readRelas(dyn[DT_RELA], dyn[DT_RELASZ])
        //   for rela in relas {
        //       let target = hostPtr + Int(rela.offset)
        //       switch RelaType(rela.type) {
        //       case .relative:  target.writeUInt64(base + UInt64(rela.addend))
        //       case .abs64:     let S = resolveSymbol(rela.sym); target.writeUInt64(S + addend)
        //       case .jump_slot: let S = resolveSymbol(rela.sym); target.writeUInt64(S); lazy bind
        //       case .glob_dat:  let S = resolveSymbol(rela.sym); target.writeUInt64(S)
        //       ...
        //       }
        //   }
        _ = image; _ = base; _ = hostPtr
    }

    /// 解析符号 (查找全局符号表)
    public func resolveSymbol(_ name: String) -> UInt64? {
        globalSymbols[name]
    }

    /// 调用 .init_array 中的初始化函数
    public func runInitArrays(image: ELFImage, base: UInt64) {
        // 遍历 DT_INIT_ARRAY, 对每个函数指针调用 BL
        // (需要 isy_enter_linux 的支持, 或者直接函数指针调用)
        _ = image; _ = base
    }

    /// 下一个可用加载基址 (每个 .so 间隔 64MB)
    private var nextBase: UInt64 = 0x20000000  // 512MB 起
    private func nextLoadAddress() -> UInt64 {
        let addr = nextBase
        nextBase += 0x4000000  // +64MB
        return addr
    }

    /// 解析 PT_DYNAMIC 段
    public static func parseDynamic(image: ELFImage, data: Data) -> [Elf64Dyn] {
        guard let phdr = image.programHeaders.first(where: { $0.type == ELFType.dynamic.rawValue }) else {
            return []
        }
        var result: [Elf64Dyn] = []
        let entrySize = 16
        let count = Int(phdr.filesz) / entrySize
        let start = Int(phdr.offset)
        for i in 0..<count {
            let off = start + i * entrySize
            guard off + 16 <= data.count else { break }
            func u64(_ o: Int) -> UInt64 {
                UInt64(data[o]) | (UInt64(data[o+1]) << 8) |
                (UInt64(data[o+2]) << 16) | (UInt64(data[o+3]) << 24) |
                (UInt64(data[o+4]) << 32) | (UInt64(data[o+5]) << 40) |
                (UInt64(data[o+6]) << 48) | (UInt64(data[o+7]) << 56)
            }
            let tag = Int64(bitPattern: u64(off))
            let val = u64(off + 8)
            result.append(Elf64Dyn(tag: tag, val: val))
            if tag == 0 { break }  // DT_NULL 结束
        }
        return result
    }
}
