// ELFLoader.swift - ARM64 Linux ELF 解析器
//
// 解析 ELF64 (Little Endian, AArch64) 的 program headers / section headers,
// 为后续 mmap 加载和 binary patching 提供信息.
//
// 关键设计:
//   - 只解析, 不加载. 加载由 Memory.swift 根据 program headers 执行 mmap
//   - 识别 PT_LOAD (可加载段), PT_INTERP (动态链接器), PT_DYNAMIC (动态信息)
//   - PT_LOAD 中, p_flags 的 X 位决定该段是否需要 binary patching (SVC->BL)
//   - 解析 .dynamic 段中的 NEEDED 项, 列出依赖的 .so

import Foundation

/// ELF 文件头 (ELF64, Little Endian)
public struct ELF64Header {
    public var ident: [UInt8]    // 16 bytes ELF magic
    public var type: UInt16      // ET_EXEC=2, ET_DYN=3
    public var machine: UInt16   // EM_AARCH64=183
    public var version: UInt32
    public var entry: UInt64
    public var phoff: UInt64
    public var shoff: UInt64
    public var flags: UInt32
    public var ehsize: UInt16
    public var phentsize: UInt16
    public var phnum: UInt16
    public var shentsize: UInt16
    public var shnum: UInt16
    public var shstrndx: UInt16

    public var isDynamic: Bool { type == 3 }
    public var isAarch64: Bool { machine == 183 }
}

/// Program header (ELF64)
public struct ELF64ProgramHeader {
    public var type: UInt32   // PT_LOAD=1, PT_DYNAMIC=2, PT_INTERP=3, PT_NOTE=4, PT_GNU_STACK=0x6474e551
    public var flags: UInt32  // PF_X=1, PF_W=2, PF_R=4
    public var offset: UInt64
    public var vaddr: UInt64
    public var paddr: UInt64
    public var filesz: UInt64
    public var memsz: UInt64
    public var align: UInt64

    public var isLoad: Bool { type == 1 }
    public var isExecutable: Bool { (flags & 1) != 0 }
    public var isWritable: Bool { (flags & 2) != 0 }
    public var isReadable: Bool { (flags & 4) != 0 }
}

public enum ELFType: UInt32 {
    case load = 1
    case dynamic = 2
    case interp = 3
    case note = 4
    case gnuStack = 0x6474e551
    case gnuRelro = 0x6474e552
}

/// 已解析的 ELF 镜像
public struct ELFImage {
    public let header: ELF64Header
    public let programHeaders: [ELF64ProgramHeader]
    public let interp: String?              // 动态链接器路径 (如 /lib/ld-linux-aarch64.so.1)
    public let loadSegments: [ELF64ProgramHeader]
    public let neededLibraries: [String]    // 依赖的 .so 列表
    public let baseAddress: UInt64          // 对 PIE: 加载基址; 对 ET_EXEC: 0

    public var entryPoint: UInt64 { header.entry + baseAddress }
}

/// ELF 加载错误
public enum ELFError: Error {
    case notELF
    case not64Bit
    case notLittleEndian
    case notAarch64
    case truncated
    case invalidProgramHeader
}

/// ELF 解析器 (纯逻辑, 不做 I/O)
public struct ELFParser {

    public static func parse(data: Data, baseAddress: UInt64 = 0) throws -> ELFImage {
        guard data.count >= 64 else { throw ELFError.truncated }

        // ELF magic: 0x7F 'E' 'L' 'F'
        guard data[0] == 0x7F, data[1] == 0x45, data[2] == 0x4C, data[3] == 0x46 else {
            throw ELFError.notELF
        }
        // EI_CLASS = 2 (ELF64)
        guard data[4] == 2 else { throw ELFError.not64Bit }
        // EI_DATA = 1 (Little Endian)
        guard data[5] == 1 else { throw ELFError.notLittleEndian }

        let header = try parseHeader(data)
        guard header.isAarch64 else { throw ELFError.notAarch64 }

        let phdrs = try parseProgramHeaders(data, header: header)
        var interp: String? = nil
        var needed: [String] = []

        for ph in phdrs {
            if ph.type == ELFType.interp.rawValue {
                // PT_INTERP: 动态链接器路径
                let start = Int(ph.offset)
                let end = min(start + Int(ph.filesz), data.count)
                if start < end {
                    var bytes = Array(data[start..<end])
                    if let last = bytes.lastIndex(of: 0) { bytes.removeSubrange(last..<bytes.count) }
                    interp = String(bytes: bytes, encoding: .utf8)
                }
            }
            if ph.type == ELFType.dynamic.rawValue {
                // PT_DYNAMIC: 解析 NEEDED 依赖
                needed = parseNeeded(data: data, phdr: ph)
            }
        }

        let loadSegs = phdrs.filter { $0.isLoad }

        return ELFImage(
            header: header,
            programHeaders: phdrs,
            interp: interp,
            loadSegments: loadSegs,
            neededLibraries: needed,
            baseAddress: baseAddress
        )
    }

    static func parseHeader(_ data: Data) throws -> ELF64Header {
        // ELF64 header layout (Little Endian)
        func u16(_ off: Int) -> UInt16 {
            UInt16(data[off]) | (UInt16(data[off+1]) << 8)
        }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[off]) | (UInt32(data[off+1]) << 8) |
            (UInt32(data[off+2]) << 16) | (UInt32(data[off+3]) << 24)
        }
        func u64(_ off: Int) -> UInt64 {
            // 拆分为两段避免 release 模式类型推断超时
            let lo: UInt64 = UInt64(data[off]) | (UInt64(data[off+1]) << 8) |
                             (UInt64(data[off+2]) << 16) | (UInt64(data[off+3]) << 24)
            let hi: UInt64 = UInt64(data[off+4]) | (UInt64(data[off+5]) << 8) |
                             (UInt64(data[off+6]) << 16) | (UInt64(data[off+7]) << 24)
            return lo | (hi << 32)
        }
        var ident = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { ident[i] = data[i] }
        return ELF64Header(
            ident: ident,
            type: u16(16), machine: u16(18), version: u32(20),
            entry: u64(24), phoff: u64(32), shoff: u64(40),
            flags: u32(48), ehsize: u16(52),
            phentsize: u16(54), phnum: u16(56),
            shentsize: u16(58), shnum: u16(60), shstrndx: u16(62)
        )
    }

    static func parseProgramHeaders(_ data: Data, header: ELF64Header) throws -> [ELF64ProgramHeader] {
        var result: [ELF64ProgramHeader] = []
        let phoff = Int(header.phoff)
        let phentsize = Int(header.phentsize)
        let phnum = Int(header.phnum)

        guard phentsize >= 56 else { throw ELFError.invalidProgramHeader }

        for i in 0..<phnum {
            let off = phoff + i * phentsize
            guard off + 56 <= data.count else { throw ELFError.truncated }
            func u32(_ o: Int) -> UInt32 {
                UInt32(data[off+o]) | (UInt32(data[off+o+1]) << 8) |
                (UInt32(data[off+o+2]) << 16) | (UInt32(data[off+o+3]) << 24)
            }
            func u64(_ o: Int) -> UInt64 {
                // 拆分为两段避免 release 模式类型推断超时
                let lo: UInt64 = UInt64(data[off+o]) | (UInt64(data[off+o+1]) << 8) |
                                 (UInt64(data[off+o+2]) << 16) | (UInt64(data[off+o+3]) << 24)
                let hi: UInt64 = UInt64(data[off+o+4]) | (UInt64(data[off+o+5]) << 8) |
                                 (UInt64(data[off+o+6]) << 16) | (UInt64(data[off+o+7]) << 24)
                return lo | (hi << 32)
            }
            result.append(ELF64ProgramHeader(
                type: u32(0), flags: u32(4),
                offset: u64(8), vaddr: u64(16), paddr: u64(24),
                filesz: u64(32), memsz: u64(40), align: u64(48)
            ))
        }
        return result
    }

    /// 解析 PT_DYNAMIC 段中的 NEEDED 依赖
    static func parseNeeded(data: Data, phdr: ELF64ProgramHeader) -> [String] {
        var needed: [String] = []
        let entrySize = 16  // Elf64_Dyn = 16 bytes
        let count = Int(phdr.filesz) / entrySize
        let start = Int(phdr.offset)

        var strtabOffset: UInt64 = 0
        var neededTags: [UInt64] = []

        // 第一遍: 收集 DT_STRTAB 和 DT_NEEDED
        for i in 0..<count {
            let off = start + i * entrySize
            guard off + 16 <= data.count else { break }

            func u64(_ o: Int) -> UInt64 {
                let lo: UInt64 = UInt64(data[off+o]) | (UInt64(data[off+o+1]) << 8) |
                                 (UInt64(data[off+o+2]) << 16) | (UInt64(data[off+o+3]) << 24)
                let hi: UInt64 = UInt64(data[off+o+4]) | (UInt64(data[off+o+5]) << 8) |
                                 (UInt64(data[off+o+6]) << 16) | (UInt64(data[off+o+7]) << 24)
                return lo | (hi << 32)
            }

            let tag = u64(0)
            let val = u64(8)

            if tag == 5 {  // DT_STRTAB
                strtabOffset = val
            } else if tag == 1 {  // DT_NEEDED
                neededTags.append(val)
            } else if tag == 0 {  // DT_NULL
                break
            }
        }

        // 第二遍: 从 .dynstr 读取名字
        for nameOff in neededTags {
            let off = Int(strtabOffset) + Int(nameOff)
            guard off < data.count else { continue }
            var end = off
            while end < data.count && data[end] != 0 { end += 1 }
            if let name = String(bytes: data[off..<end], encoding: .utf8) {
                needed.append(name)
            }
        }
        return needed
    }
}
