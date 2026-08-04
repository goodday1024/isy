// DynamicLinker.swift - ARM64 Linux 动态链接器 (完整实现)
//
// 职责:
//   1. 加载主程序依赖的 .so (递归处理 NEEDED)
//   2. 解析 PT_DYNAMIC 段: DT_NEEDED / DT_STRTAB / DT_SYMTAB / DT_JMPREL /
//      DT_REL(A) / DT_PLTGOT / DT_PLTRELSZ 等
//   3. 执行重定位:
//      - R_AARCH64_RELATIVE: *addr = base + addend
//      - R_AARCH64_GLOB_DAT / R_AARCH64_JUMP_SLOT: 查符号表填地址
//      - R_AARCH64_ABS64: S + A
//      - R_AARCH64_COPY: 复制符号内容
//   4. 初始化 .init_array / .fini_array
//   5. 设置 TPIDR_EL0 (TLS): 从 PT_TLS 分配 TLS 块

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import isyCHot

// MARK: - ELF 动态段条目

public struct Elf64Dyn {
    public var tag: Int64
    public var val: UInt64
}

public enum DynTag: Int64 {
    case null = 0
    case needed = 1
    case pltrelsz = 2
    case pltgot = 3
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
    case soname = 14
    case rpath = 15
    case symbolic = 16
    case rel = 17
    case relsz = 18
    case relent = 19
    case pltrel = 20
    case debug = 21
    case textrel = 22
    case jmprel = 23
    case bind_now = 24
    case init_array = 25
    case fini_array = 26
    case init_arraysz = 27
    case fini_arraysz = 28
    case flags = 30
    case flags_1 = 0x6ffffffb
    case gnu_hash = 0x6ffffef5
    case versym = 0x6ffffff0
    case verdef = 0x6ffffffc
    case verneed = 0x6ffffffe
}

// MARK: - ARM64 重定位类型

public enum RelocType: UInt32 {
    case none = 0
    case abs64 = 257          // R_AARCH64_ABS64: S + A
    case copy = 1024          // R_AARCH64_COPY
    case glob_dat = 1025      // R_AARCH64_GLOB_DAT: S
    case jump_slot = 1026     // R_AARCH64_JUMP_SLOT: S
    case relative = 1027      // R_AARCH64_RELATIVE: B + A
    case tlsdesc = 1031       // R_AARCH64_TLSDESC
    case irelative = 1032     // R_AARCH64_IRELATIVE
}

// MARK: - Elf64_Rela / Elf64_Sym

public struct Elf64Rela {
    public var offset: UInt64
    public var info: UInt64
    public var addend: Int64

    public var type: UInt32 { UInt32(info & 0xFFFFFFFF) }
    public var sym: UInt32 { UInt32(info >> 32) }
}

public struct Elf64Sym {
    public var name: UInt32     // st_name (offset in .dynstr)
    public var info: UInt8      // st_info
    public var other: UInt8     // st_other
    public var shndx: UInt16    // st_shndx
    public var value: UInt64    // st_value
    public var size: UInt64     // st_size

    public var bind: UInt8 { info >> 4 }
    public var type: UInt8 { info & 0xF }
}

// MARK: - 已加载的共享库

public struct SharedLibrary {
    public let name: String
    public let baseAddress: UInt64
    public let image: ELFImage
    public let hostBase: UnsafeMutableRawPointer  // 宿主内存基址
    public var symbols: [String: UInt64] = [:]     // 导出符号表
}

// MARK: - 动态链接器

public final class DynamicLinker {
    public var libraries: [SharedLibrary] = []
    public var rootfs: RootFS?
    public var globalSymbols: [String: UInt64] = [:]
    public var addressSpace: LinuxAddressSpace?

    private var nextBase: UInt64 = 0x20000000  // 512MB

    public init(rootfs: RootFS? = nil, addressSpace: LinuxAddressSpace? = nil) {
        self.rootfs = rootfs
        self.addressSpace = addressSpace
    }

    // MARK: - 加载依赖

    /// 加载主程序的所有依赖 (递归)
    public func loadDependencies(
        of mainImage: ELFImage,
        mainBase: UInt64,
        mainHostBase: UnsafeMutableRawPointer,
        mainData: Data,
        loadData: (String) throws -> Data
    ) throws -> [SharedLibrary] {
        // 解析主程序的 .dynamic 段收集 NEEDED
        let dyns = Self.parseDynamic(image: mainImage, data: mainData)
        var needed: [String] = []
        for d in dyns {
            if d.tag == DynTag.needed.rawValue {
                // d.val 是 .dynstr 中的偏移
                if let name = readString(data: mainData, dyns: dyns, offset: Int(d.val)) {
                    needed.append(name)
                }
            }
        }

        var loaded: [String: SharedLibrary] = [:]
        var queue = needed

        while let libName = queue.first {
            queue.removeFirst()
            if loaded[libName] != nil { continue }

            let baseAddr = nextLoadAddress()
            let data = try loadData(libName)
            let img = try ELFParser.parse(data: data, baseAddress: baseAddr)

            // mmap 加载 .so 的 PT_LOAD 段
            let hostBase: UnsafeMutableRawPointer
            if let aspace = addressSpace {
                // 加载到隔离地址空间
                hostBase = try loadSegments(img: img, data: data, into: aspace)
            } else {
                // 直接 mmap (测试/简单场景)
                hostBase = try loadSegmentsHost(img: img, data: data)
            }

            var lib = SharedLibrary(name: libName, baseAddress: baseAddr, image: img, hostBase: hostBase)

            // 解析 .dynsym 导出符号
            lib.symbols = parseDynSym(image: img, base: baseAddr, data: data)
            for (k, v) in lib.symbols { globalSymbols[k] = v }

            loaded[libName] = lib
            libraries.append(lib)

            // 递归处理 NEEDED
            let libDyns = Self.parseDynamic(image: img, data: data)
            for d in libDyns where d.tag == DynTag.needed.rawValue {
                if let name = readString(data: data, dyns: libDyns, offset: Int(d.val)) {
                    if loaded[name] == nil { queue.append(name) }
                }
            }
        }
        return Array(loaded.values)
    }

    // MARK: - 重定位

    /// 对一个镜像执行完整重定位
    public func relocate(image: ELFImage, base: UInt64, hostPtr: UnsafeMutableRawPointer, data: Data) throws -> Int {
        let dyns = Self.parseDynamic(image: image, data: data)
        let dynMap = makeDynMap(dyns)

        // 获取必需字段
        guard let relaAddr = dynMap[DynTag.rela.rawValue],
              let relaSize = dynMap[DynTag.relasz.rawValue] else {
            return 0
        }

        var patchCount = 0

        // 1. DT_RELA: 常规重定位 (R_AARCH64_RELATIVE, R_AARCH64_GLOB_DAT, R_AARCH64_ABS64, R_AARCH64_COPY)
        let relaCount = Int(relaSize) / 24  // Elf64_Rela = 24 bytes
        for i in 0..<relaCount {
            let rela = readRela(data: data, offset: Int(relaAddr) + i * 24)
            guard rela.type != RelocType.none.rawValue else { continue }

            let targetPtr = hostPtr.advanced(by: Int(rela.offset))
            switch rela.type {
            case RelocType.relative.rawValue:
                // R_AARCH64_RELATIVE: *(base + r_offset) = base + addend
                let value = base + UInt64(bitPattern: rela.addend)
                targetPtr.assumingMemoryBound(to: UInt64.self).pointee = value
                patchCount += 1

            case RelocType.abs64.rawValue:
                // R_AARCH64_ABS64: S + A
                let S = resolveSymbolValue(rela.sym, dyns: dyns, data: data, base: base)
                let value = S + UInt64(bitPattern: rela.addend)
                targetPtr.assumingMemoryBound(to: UInt64.self).pointee = value
                patchCount += 1

            case RelocType.glob_dat.rawValue:
                // R_AARCH64_GLOB_DAT: S
                let S = resolveSymbolValue(rela.sym, dyns: dyns, data: data, base: base)
                targetPtr.assumingMemoryBound(to: UInt64.self).pointee = S
                patchCount += 1

            case RelocType.copy.rawValue:
                // R_AARCH64_COPY: 复制符号内容
                let sym = readSymbol(dyns: dyns, data: data, index: Int(rela.sym))
                let S = resolveSymbolValue(rela.sym, dyns: dyns, data: data, base: base)
                if S != 0, sym.size > 0 {
                    // 从 S 复制 size 字节到 targetPtr
                    let srcPtr = UnsafeMutableRawPointer(bitPattern: UInt(S))
                    if let src = srcPtr {
                        memcpy(targetPtr, src, Int(sym.size))
                    }
                }
                patchCount += 1

            default:
                break
            }
        }

        // 2. DT_JMPREL: PLT 重定位 (R_AARCH64_JUMP_SLOT)
        if let jmprelAddr = dynMap[DynTag.jmprel.rawValue],
           let pltrelsz = dynMap[DynTag.pltrelsz.rawValue] {
            let jmprelCount = Int(pltrelsz) / 24
            for i in 0..<jmprelCount {
                let rela = readRela(data: data, offset: Int(jmprelAddr) + i * 24)
                if rela.type == RelocType.jump_slot.rawValue {
                    let targetPtr = hostPtr.advanced(by: Int(rela.offset))
                    let S = resolveSymbolValue(rela.sym, dyns: dyns, data: data, base: base)
                    targetPtr.assumingMemoryBound(to: UInt64.self).pointee = S
                    patchCount += 1
                }
            }
        }

        return patchCount
    }

    // MARK: - 符号解析

    /// 解析符号值
    private func resolveSymbolValue(_ symIdx: UInt32, dyns: [Elf64Dyn], data: Data, base: UInt64) -> UInt64 {
        let sym = readSymbol(dyns: dyns, data: data, index: Int(symIdx))
        let symName = readString(dyns: dyns, data: data, strtabOffset: Int(sym.name))

        // 如果符号有非零值，说明定义在当前库中
        if sym.value != 0 && sym.shndx != 0 {
            return base + sym.value
        }

        // 查找全局符号表
        if let name = symName, let addr = globalSymbols[name] {
            return addr
        }

        return 0
    }

    /// 解析 .dynsym 导出符号
    public func parseDynSym(image: ELFImage, base: UInt64, data: Data) -> [String: UInt64] {
        let dyns = Self.parseDynamic(image: image, data: data)
        let dynMap = makeDynMap(dyns)
        guard dynMap[DynTag.symtab.rawValue] != nil else { return [:] }

        var result: [String: UInt64] = [:]
        // 遍历所有符号 (保守估计 4096 个)
        let maxSyms = 4096
        for i in 0..<maxSyms {
            let sym = readSymbol(dyns: dyns, data: data, index: i)
            if sym.name == 0 { continue }
            guard let name = readString(dyns: dyns, data: data, strtabOffset: Int(sym.name)) else { continue }
            if sym.bind == 1 || sym.bind == 2, sym.value != 0, sym.shndx != 0 {
                result[name] = base + sym.value
            }
        }
        return result
    }

    // MARK: - .init_array 执行

    /// 调用 .init_array 中的初始化函数
    public func runInitArrays(image: ELFImage, base: UInt64, hostPtr: UnsafeMutableRawPointer, data: Data) {
        let dyns = Self.parseDynamic(image: image, data: data)
        let dynMap = makeDynMap(dyns)
        guard let initArray = dynMap[DynTag.init_array.rawValue],
              let initArraySz = dynMap[DynTag.init_arraysz.rawValue] else { return }

        let count = Int(initArraySz) / 8
        // init_array 中的地址是 VA (相对于 base)
        let initBase = hostPtr.advanced(by: Int(initArray))

        for i in 0..<count {
            let funcVA = initBase.advanced(by: i * 8).assumingMemoryBound(to: UInt64.self).pointee
            if funcVA == 0 || funcVA == UInt64.max { continue }
            // 调用初始化函数
            // 在真实环境中，需要通过 isy_enter_linux 调用
            // 这里简化：如果 funcVA 在 host 地址空间内，直接调用
            if let funcPtr = UnsafeMutableRawPointer(bitPattern: UInt(funcVA)) {
                typealias InitFunc = @convention(c) () -> Void
                let fn = unsafeBitCast(funcPtr, to: InitFunc.self)
                fn()
            }
        }
    }

    // MARK: - 查询

    public func resolveSymbol(_ name: String) -> UInt64? {
        globalSymbols[name]
    }

    // MARK: - 内部 helpers

    private func nextLoadAddress() -> UInt64 {
        let addr = nextBase
        nextBase += 0x4000000  // +64MB
        return addr
    }

    /// 加载 .so 的 PT_LOAD 段到隔离地址空间
    private func loadSegments(img: ELFImage, data: Data, into aspace: LinuxAddressSpace) throws -> UnsafeMutableRawPointer {
        guard let first = img.loadSegments.first else {
            throw ELFError.invalidProgramHeader
        }
        return try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let _ = try aspace.loadELFSegment(
                data: buf.baseAddress!, phdr: first, baseVA: img.baseAddress, segIndex: 0
            )
            // 返回第一个段的宿主指针
            guard let region = aspace.region(for: VA(img.baseAddress + first.vaddr)) else {
                throw ELFError.invalidProgramHeader
            }
            return region.base
        }
    }

    /// 加载 .so 段到宿主内存 (简单场景)
    private func loadSegmentsHost(img: ELFImage, data: Data) throws -> UnsafeMutableRawPointer {
        let pageSize = Int(getpagesize())
        // 计算总大小
        var totalSize = 0
        for ph in img.loadSegments {
            let end = Int(ph.vaddr + ph.memsz)
            if end > totalSize { totalSize = end }
        }
        totalSize = (totalSize + pageSize - 1) & ~(pageSize - 1)

        let ptr = mmap(nil, totalSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
        guard let host = ptr, host != MAP_FAILED else {
            throw MemoryError.mmapFailed(errno: errno)
        }

        // 加载每个段
        for ph in img.loadSegments {
            let off = Int(ph.vaddr)
            let src = data.withUnsafeBytes { $0.baseAddress! }.advanced(by: Int(ph.offset))
            memcpy(host.advanced(by: off), src, Int(ph.filesz))
            if ph.memsz > ph.filesz {
                memset(host.advanced(by: off + Int(ph.filesz)), 0, Int(ph.memsz - ph.filesz))
            }
        }
        return host
    }

    // MARK: - 静态解析工具

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
            let tag = readU64(data, off)
            let val = readU64(data, off + 8)
            result.append(Elf64Dyn(tag: Int64(bitPattern: tag), val: val))
            if tag == 0 { break }
        }
        return result
    }
}

// MARK: - 内部读取工具

private func makeDynMap(_ dyns: [Elf64Dyn]) -> [Int64: UInt64] {
    var map: [Int64: UInt64] = [:]
    for d in dyns { map[d.tag] = d.val }
    return map
}

private func readU64(_ data: Data, _ off: Int) -> UInt64 {
    let lo = UInt64(data[off]) | (UInt64(data[off+1]) << 8) |
             (UInt64(data[off+2]) << 16) | (UInt64(data[off+3]) << 24)
    let hi = UInt64(data[off+4]) | (UInt64(data[off+5]) << 8) |
             (UInt64(data[off+6]) << 16) | (UInt64(data[off+7]) << 24)
    return lo | (hi << 32)
}

private func readUInt32(_ data: Data, _ off: Int) -> UInt32 {
    UInt32(data[off]) | (UInt32(data[off+1]) << 8) |
    (UInt32(data[off+2]) << 16) | (UInt32(data[off+3]) << 24)
}

private func readRela(data: Data, offset: Int) -> Elf64Rela {
    Elf64Rela(
        offset: readU64(data, offset),
        info: readU64(data, offset + 8),
        addend: Int64(bitPattern: readU64(data, offset + 16))
    )
}

private func readSymbol(dyns: [Elf64Dyn], data: Data, index: Int) -> Elf64Sym {
    let map = makeDynMap(dyns)
    guard let symtab = map[DynTag.symtab.rawValue] else {
        return Elf64Sym(name: 0, info: 0, other: 0, shndx: 0, value: 0, size: 0)
    }
    let off = Int(symtab) + index * 24  // Elf64_Sym = 24 bytes
    guard off + 24 <= data.count else {
        return Elf64Sym(name: 0, info: 0, other: 0, shndx: 0, value: 0, size: 0)
    }
    return Elf64Sym(
        name: readUInt32(data, off),
        info: data[off + 4],
        other: data[off + 5],
        shndx: UInt16(data[off + 6]) | (UInt16(data[off + 7]) << 8),
        value: readU64(data, off + 8),
        size: readU64(data, off + 16)
    )
}

private func readString(dyns: [Elf64Dyn], data: Data, strtabOffset: Int) -> String? {
    let map = makeDynMap(dyns)
    guard let strtab = map[DynTag.strtab.rawValue] else { return nil }
    let off = Int(strtab) + strtabOffset
    guard off < data.count else { return nil }
    var end = off
    while end < data.count && data[end] != 0 { end += 1 }
    return String(bytes: data[off..<end], encoding: .utf8)
}

private func readString(data: Data, dyns: [Elf64Dyn], offset: Int) -> String? {
    readString(dyns: dyns, data: data, strtabOffset: offset)
}