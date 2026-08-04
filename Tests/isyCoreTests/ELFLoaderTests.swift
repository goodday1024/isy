// ELFLoaderTests.swift - 验证 ELF 解析逻辑
//
// 构造最小的合法 ARM64 ELF 字节流, 验证 ELFParser 能正确解析.

import XCTest
@testable import isyCore

final class ELFLoaderTests: XCTestCase {

    /// 构造一个最小的 ELF64 AArch64 header (64 字节)
    private func makeMinimalELFHeader(type: UInt16 = 3, machine: UInt16 = 183) -> Data {
        var data = Data(count: 64)
        // e_ident: 7F 45 4C 46 02 01 01 00 ...
        data[0] = 0x7F; data[1] = 0x45; data[2] = 0x4C; data[3] = 0x46
        data[4] = 2  // ELFCLASS64
        data[5] = 1  // ELFDATA2LSB (Little Endian)
        data[6] = 1  // EV_CURRENT
        // e_type (offset 16)
        data[16] = UInt8(type & 0xFF); data[17] = UInt8((type >> 8) & 0xFF)
        // e_machine (offset 18): EM_AARCH64 = 183
        data[18] = UInt8(machine & 0xFF); data[19] = UInt8((machine >> 8) & 0xFF)
        // e_version (offset 20): 1
        data[20] = 1
        // e_entry (offset 24): 0x400000
        writeU64(&data, 24, 0x400000)
        // e_phoff (offset 32): 64 (紧跟 header)
        writeU64(&data, 32, 64)
        // e_shoff (offset 40): 0
        // e_flags (offset 48): 0
        // e_ehsize (offset 52): 64
        data[52] = 64
        // e_phentsize (offset 54): 56
        data[54] = 56
        // e_phnum (offset 56): 0 (无 program header)
        // e_shentsize (offset 58): 0
        // e_shnum (offset 60): 0
        // e_shstrndx (offset 62): 0
        return data
    }

    private func writeU64(_ data: inout Data, _ off: Int, _ val: UInt64) {
        for i in 0..<8 {
            data[off + i] = UInt8((val >> (i * 8)) & 0xFF)
        }
    }

    private func writeU32(_ data: inout Data, _ off: Int, _ val: UInt32) {
        for i in 0..<4 {
            data[off + i] = UInt8((val >> (i * 8)) & 0xFF)
        }
    }

    func testParse_validAArch64ELF() throws {
        let data = makeMinimalELFHeader()
        let img = try ELFParser.parse(data: data)
        XCTAssertEqual(img.header.machine, 183, "machine 应为 EM_AARCH64")
        XCTAssertEqual(img.header.type, 3, "type 应为 ET_DYN")
        XCTAssertEqual(img.header.entry, 0x400000)
        XCTAssertTrue(img.header.isAarch64)
        XCTAssertTrue(img.header.isDynamic)
        XCTAssertEqual(img.programHeaders.count, 0)
    }

    func testParse_rejectsNonELF() {
        var data = Data(count: 64)
        data[0] = 0x00; data[1] = 0x00  // 非 ELF magic
        XCTAssertThrowsError(try ELFParser.parse(data: data)) { error in
            guard case ELFError.notELF = error else {
                XCTFail("期望 notELF 错误, 实际: \(error)")
                return
            }
        }
    }

    func testParse_rejects32Bit() {
        var data = makeMinimalELFHeader()
        data[4] = 1  // ELFCLASS32
        XCTAssertThrowsError(try ELFParser.parse(data: data)) { error in
            guard case ELFError.not64Bit = error else {
                XCTFail("期望 not64Bit 错误"); return
            }
        }
    }

    func testParse_rejectsBigEndian() {
        var data = makeMinimalELFHeader()
        data[5] = 2  // ELFDATA2MSB (Big Endian)
        XCTAssertThrowsError(try ELFParser.parse(data: data)) { error in
            guard case ELFError.notLittleEndian = error else {
                XCTFail("期望 notLittleEndian 错误"); return
            }
        }
    }

    func testParse_rejectsNonAArch64() {
        let data = makeMinimalELFHeader(machine: 62)  // EM_X86_64
        XCTAssertThrowsError(try ELFParser.parse(data: data)) { error in
            guard case ELFError.notAarch64 = error else {
                XCTFail("期望 notAarch64 错误"); return
            }
        }
    }

    func testParse_rejectsTruncated() {
        let data = Data(count: 32)  // 太短
        XCTAssertThrowsError(try ELFParser.parse(data: data)) { error in
            guard case ELFError.truncated = error else {
                XCTFail("期望 truncated 错误"); return
            }
        }
    }

    func testParse_withOneProgramHeader() throws {
        var data = makeMinimalELFHeader()
        // e_phnum = 1
        data[56] = 1; data[57] = 0
        // 追加一个 PT_LOAD program header (56 字节)
        let phdrOffset = 64
        data.append(Data(count: 56))
        // p_type = PT_LOAD = 1
        writeU32(&data, phdrOffset + 0, 1)
        // p_flags = PF_R|PF_X = 5
        writeU32(&data, phdrOffset + 4, 5)
        // p_offset = 0x1000
        writeU64(&data, phdrOffset + 8, 0x1000)
        // p_vaddr = 0x400000
        writeU64(&data, phdrOffset + 16, 0x400000)
        // p_paddr = 0x400000
        writeU64(&data, phdrOffset + 24, 0x400000)
        // p_filesz = 0x1000
        writeU64(&data, phdrOffset + 32, 0x1000)
        // p_memsz = 0x2000
        writeU64(&data, phdrOffset + 40, 0x2000)
        // p_align = 0x1000
        writeU64(&data, phdrOffset + 48, 0x1000)

        let img = try ELFParser.parse(data: data)
        XCTAssertEqual(img.programHeaders.count, 1)
        XCTAssertEqual(img.loadSegments.count, 1)
        let ph = img.loadSegments[0]
        XCTAssertTrue(ph.isLoad)
        XCTAssertTrue(ph.isReadable)
        XCTAssertFalse(ph.isWritable)
        XCTAssertTrue(ph.isExecutable)
        XCTAssertEqual(ph.vaddr, 0x400000)
        XCTAssertEqual(ph.filesz, 0x1000)
        XCTAssertEqual(ph.memsz, 0x2000)
    }

    func testParse_baseAddressApplied() throws {
        let data = makeMinimalELFHeader()
        let img = try ELFParser.parse(data: data, baseAddress: 0x10000000)
        XCTAssertEqual(img.baseAddress, 0x10000000)
        XCTAssertEqual(img.entryPoint, 0x10000000 + 0x400000)
    }
}
