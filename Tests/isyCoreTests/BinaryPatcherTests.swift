// BinaryPatcherTests.swift - 验证 SVC->BL 替换算法的正确性
//
// 这些测试在 Linux x86_64 上运行 (不依赖 arm64), 验证核心算法逻辑.

import XCTest
@testable import isyCore

final class BinaryPatcherTests: XCTestCase {

    // ---------- BL 编码 ----------
    func testEncodeBL_forwardOffset() throws {
        // pc=0x1000, target=0x1008, diff=+8, imm26=2
        // BL = 0x94000000 | 2 = 0x94000002
        let bl = try BinaryPatcher.encodeBL(from: 0x1000, to: 0x1008)
        XCTAssertEqual(bl, 0x94000002, "正向 BL 编码错误")
    }

    func testEncodeBL_backwardOffset() throws {
        // pc=0x1000, target=0xFFC, diff=-4, imm26=-1
        // imm26 = -1 = 0x03FFFFFF (26-bit 二补码)
        // BL = 0x94000000 | 0x03FFFFFF = 0x97FFFFFF
        let bl = try BinaryPatcher.encodeBL(from: 0x1000, to: 0xFFC)
        XCTAssertEqual(bl, 0x97FFFFFF, "反向 BL 编码错误")
    }

    func testEncodeBL_zeroOffset() throws {
        // pc == target (BL to self, 实际不会发生但算法应处理)
        let bl = try BinaryPatcher.encodeBL(from: 0x1000, to: 0x1000)
        XCTAssertEqual(bl, 0x94000000, "零偏移 BL 编码错误")
    }

    func testEncodeBL_maxForwardRange() throws {
        // 最大正向范围: ±128MB - 4
        // 128MB = 0x8000000, imm26 最大正值 = 2^25 - 1 = 33554431, 字节 = 134217724
        let pc: UInt64 = 0x1000
        let target = pc + 134217724  // 接近上限
        let bl = try BinaryPatcher.encodeBL(from: pc, to: target)
        XCTAssertEqual(bl & 0xFC000000, 0x94000000, "最大正向范围 BL opcode 错误")
    }

    func testEncodeBL_outOfRange_throws() {
        // 超出 ±128MB 范围应抛出 trapOutOfRange
        let pc: UInt64 = 0x1000
        let target = pc + 200 * 1024 * 1024  // 200MB, 超出 128MB
        XCTAssertThrowsError(try BinaryPatcher.encodeBL(from: pc, to: target)) { error in
            guard case PatchError.trapOutOfRange = error else {
                XCTFail("期望 trapOutOfRange 错误, 实际: \(error)")
                return
            }
        }
    }

    // ---------- SVC 识别 ----------
    func testIsSVC_recognizesSVC0() {
        XCTAssertTrue(BinaryPatcher.isSVC(0xD4000001), "SVC #0 应被识别")
    }

    func testIsSVC_rejectsOtherSVC() {
        // SVC #1 = 0xD4000001 | (1 << 5) = 0xD4000021
        XCTAssertFalse(BinaryPatcher.isSVC(0xD4000021), "SVC #1 不应被 isSVC 识别 (只识别 SVC #0)")
    }

    func testIsAnySVC_recognizesAllSVC() {
        // SVC #imm16 编码: 0xD4000001 | (imm16 << 5)
        XCTAssertTrue(BinaryPatcher.isAnySVC(0xD4000001), "SVC #0")
        XCTAssertTrue(BinaryPatcher.isAnySVC(0xD4000021), "SVC #1")
        XCTAssertTrue(BinaryPatcher.isAnySVC(0xD400FFE1), "SVC #0x7FF")
        XCTAssertFalse(BinaryPatcher.isAnySVC(0xD503201F), "NOP 不应是 SVC")
    }

    func testIsSVC_rejectsNonSVC() {
        XCTAssertFalse(BinaryPatcher.isSVC(0xD503201F), "NOP 不应被识别为 SVC")
        XCTAssertFalse(BinaryPatcher.isSVC(0x94000000), "BL 不应被识别为 SVC")
        XCTAssertFalse(BinaryPatcher.isSVC(0x00000000), "全零不应被识别为 SVC")
    }

    // ---------- 完整 patch 流程 ----------
    func testPatchSegment_replacesAllSVC() throws {
        // 构造指令流: NOP, SVC, NOP, SVC, NOP
        let insns: [UInt32] = [
            0xD503201F,  // NOP
            0xD4000001,  // SVC #0
            0xD503201F,  // NOP
            0xD4000001,  // SVC #0
            0xD503201F,  // NOP
        ]
        var buffer = insns
        let trapAddr: UInt64 = 0x2000
        let config = PatchConfig(trapAddress: trapAddr)

        try buffer.withUnsafeMutableBufferPointer { ptr in
            var table = PatchTable()
            try BinaryPatcher.patchSegment(ptr, baseVA: 0x1000, config: config,
                                           segmentIndex: 0, into: &table)
            // 验证 SVC 被替换为 BL
            XCTAssertEqual(ptr[0], 0xD503201F, "NOP 不应被修改")
            XCTAssertTrue(BinaryPatcher.isBL(ptr[1]), "SVC[1] 应被替换为 BL")
            XCTAssertEqual(ptr[2], 0xD503201F, "NOP 不应被修改")
            XCTAssertTrue(BinaryPatcher.isBL(ptr[3]), "SVC[3] 应被替换为 BL")
            XCTAssertEqual(ptr[4], 0xD503201F, "NOP 不应被修改")
            // 验证 patch 表
            XCTAssertEqual(table.records.count, 2, "应有 2 条 patch 记录")
            XCTAssertEqual(table.records[0].va, VA(0x1004), "第一条 patch VA 错误")
            XCTAssertEqual(table.records[0].originalInstruction, 0xD4000001)
            XCTAssertEqual(table.records[1].va, VA(0x100C), "第二条 patch VA 错误")
        }
    }

    func testPatchSegment_BLTargetsCorrectAddress() throws {
        // 验证 patch 后的 BL 跳转目标确实是 trap 地址
        let insns: [UInt32] = [0xD4000001]  // 单条 SVC
        var buffer = insns
        let trapAddr: UInt64 = 0x2000
        let config = PatchConfig(trapAddress: trapAddr)

        try buffer.withUnsafeMutableBufferPointer { ptr in
            var table = PatchTable()
            try BinaryPatcher.patchSegment(ptr, baseVA: 0x1000, config: config,
                                           segmentIndex: 0, into: &table)
            let bl = ptr[0]
            // 解码 BL imm26, 计算实际跳转地址
            let imm26 = Int32(bitPattern: UInt32(bl & 0x03FFFFFF))
            // 符号扩展到 32 位
            let extended = (imm26 << 6) >> 6  // 符号扩展 26->32
            let target = UInt64(Int64(0x1000) + Int64(extended) * 4)
            XCTAssertEqual(target, trapAddr, "BL 跳转目标应为 trap 地址")
        }
    }

    func testPatchSegment_emptySegment() throws {
        // 空段不应崩溃, patch 表应为空
        var insns: [UInt32] = []
        let config = PatchConfig(trapAddress: 0x2000)
        try insns.withUnsafeMutableBufferPointer { ptr in
            var table = PatchTable()
            try BinaryPatcher.patchSegment(ptr, baseVA: 0x1000, config: config,
                                           segmentIndex: 0, into: &table)
            XCTAssertEqual(table.records.count, 0)
        }
    }

    func testPatchSegment_doesNotTouchNonSVC() throws {
        // 各种非 SVC 指令不应被修改
        let insns: [UInt32] = [
            0xD503201F,  // NOP
            0xAA1F03E0,  // MOV x0, xzr
            0x910003FF,  // MOV sp, sp (ADD sp, sp, #0)
            0xD65F03C0,  // RET
            0xD4000001,  // SVC #0 (唯一应被 patch)
            0xF94003E0,  // LDR x0, [sp]
        ]
        var buffer = insns
        let config = PatchConfig(trapAddress: 0x100000)
        try buffer.withUnsafeMutableBufferPointer { ptr in
            var table = PatchTable()
            try BinaryPatcher.patchSegment(ptr, baseVA: 0x400000, config: config,
                                           segmentIndex: 0, into: &table)
            // 只有 index 4 被修改
            XCTAssertEqual(ptr[0], 0xD503201F)
            XCTAssertEqual(ptr[1], 0xAA1F03E0)
            XCTAssertEqual(ptr[2], 0x910003FF)
            XCTAssertEqual(ptr[3], 0xD65F03C0)
            XCTAssertTrue(BinaryPatcher.isBL(ptr[4]))
            XCTAssertEqual(ptr[5], 0xF94003E0)
            XCTAssertEqual(table.records.count, 1)
        }
    }

    // ---------- PatchTable ----------
    func testPatchTable_lookupByAddress() {
        var table = PatchTable()
        let record = PatchRecord(
            va: VA(0x1000),
            originalInstruction: 0xD4000001,
            patchedInstruction: 0x94000002,
            segmentIndex: 0
        )
        table.add(record)
        XCTAssertEqual(table.originalInstruction(at: VA(0x1000)), 0xD4000001)
        XCTAssertNil(table.originalInstruction(at: VA(0x2000)))
    }

    // ---------- MRS/MSR 识别 ----------
    func testIsMRS_recognizesSystemRegisterRead() {
        // MRS x0, TPIDR_EL0
        // 编码: 1101 0101 0011 0011 1101 0000 0100 0000 = 0xD53BD040
        XCTAssertTrue(BinaryPatcher.isMRS(0xD53BD040))
    }

    func testIsMSR_recognizesSystemRegisterWrite() {
        // MSR TPIDR_EL0, x0
        // 编码: 1101 0101 0001 0011 1101 0000 0100 0000 = 0xD51BD040
        XCTAssertTrue(BinaryPatcher.isMSR(0xD51BD040))
    }

    // ---------- 性能基准 (宽松阈值, 防止环境抖动) ----------
    func testPatchSegment_performance_largeSegment() throws {
        // 1M 条指令, 1% SVC, 应在合理时间内完成
        let count = 100_000
        var insns = [UInt32](repeating: 0xD503201F, count: count)
        for i in stride(from: 0, to: count, by: 100) {
            insns[i] = 0xD4000001
        }
        let config = PatchConfig(trapAddress: 0x100000)

        let start = Date()
        try insns.withUnsafeMutableBufferPointer { ptr in
            var table = PatchTable()
            try BinaryPatcher.patchSegment(ptr, baseVA: 0x400000, config: config,
                                           segmentIndex: 0, into: &table)
            XCTAssertEqual(table.records.count, count / 100)
        }
        let elapsed = Date().timeIntervalSince(start)
        // 宽松阈值: 100K 指令应在 100ms 内完成
        XCTAssertLessThan(elapsed, 0.1, "patch 性能不达标: \(elapsed * 1000)ms")
    }
}
