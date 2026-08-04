// main.swift - isy CLI 入口
//
// 用于在 Linux/macOS 上验证 isyCore 的核心逻辑:
//   - C/Swift 互操作 (isy_get_trap_address, syscall handler 注册)
//   - ELF 解析
//   - Binary patcher 算法
//   - syscall 分发
//
// 真正的 ARM64 Linux 代码执行只在 iOS/arm64 设备上发生 (isyApp UI 入口).

import Foundation
import isyCore
import isyCHot

func printUsage() {
    print("""
    isy \(isyVersion) - iOS System (CLI 模式)
    用法:
      isycli info                打印运行时信息 (trap 地址等)
      isycli parse <elf>         解析 ELF 并打印段信息
      isycli patch <elf>         解析 + 模拟 patch + 打印 patch 表
      isycli bench               跑 BinaryPatcher 微基准
      isycli syscall <nr> [a0..] 调用指定 syscall 号 (测试用)
    """)
}

public let isyVersion = "0.1.0-dev"

let args = CommandLine.arguments
guard args.count >= 2 else { printUsage(); exit(0) }

switch args[1] {
case "info":
    print("isy \(isyVersion)")
    print("  trap address: 0x\(String(isy_get_trap_address(), radix: 16))")
    let s = isy_get_stats().pointee
    print("  stats: syscalls=\(s.syscalls) traps=\(s.traps) icache=\(s.icache_flushes)")
    #if arch(arm64)
    print("  arch: arm64 (近原生执行可用)")
    print("  tpidr_el0: 0x\(String(isy_arm64_get_tpidr_el0(), radix: 16))")
    print("  cntfrq: \(isy_arm64_get_cntfrq()) Hz")
    #else
    print("  arch: 非 arm64 (近原生执行不可用, 仅核心逻辑可测)")
    #endif

case "parse":
    guard args.count >= 3 else { print("用法: isycli parse <elf>"); exit(1) }
    let path = args[2]
    guard let data = FileManager.default.contents(atPath: path) else {
        print("无法读取 \(path)"); exit(1)
    }
    do {
        let img = try ELFParser.parse(data: data)
        print("ELF: machine=\(img.header.machine) type=\(img.header.type)")
        print("  entry=0x\(String(img.header.entry, radix: 16))")
        print("  phnum=\(img.header.phnum) loadSegs=\(img.loadSegments.count)")
        print("  interp=\(img.interp ?? "(无)")")
        for (i, ph) in img.loadSegments.enumerated() {
            print(String(format: "  LOAD[%d] off=0x%llx vaddr=0x%llx filesz=0x%llx memsz=0x%llx flags=%c%c%c",
                         i, ph.offset, ph.vaddr, ph.filesz, ph.memsz,
                         ph.isReadable ? "r" : "-",
                         ph.isWritable ? "w" : "-",
                         ph.isExecutable ? "x" : "-"))
        }
    } catch {
        print("ELF 解析失败: \(error)"); exit(1)
    }

case "patch":
    guard args.count >= 3 else { print("用法: isycli patch <elf>"); exit(1) }
    let path = args[2]
    guard let data = FileManager.default.contents(atPath: path) else {
        print("无法读取 \(path)"); exit(1)
    }
    do {
        let img = try ELFParser.parse(data: data)
        print("ELF: entry=0x\(String(img.header.entry, radix: 16)) loadSegs=\(img.loadSegments.count)")
        // 模拟 patch: 在内存中拷贝段, 跑 patcher
        let trapAddr = UInt64(isy_get_trap_address())
        print("trap address: 0x\(String(trapAddr, radix: 16))")
        var totalSVC = 0
        for (i, ph) in img.loadSegments.enumerated() where ph.isExecutable {
            // 统计 SVC 数量
            let start = Int(ph.offset)
            let end = start + Int(ph.filesz)
            var svcCount = 0
            var offset = start
            while offset + 4 <= end {
                let insn = UInt32(data[offset]) |
                           (UInt32(data[offset+1]) << 8) |
                           (UInt32(data[offset+2]) << 16) |
                           (UInt32(data[offset+3]) << 24)
                if BinaryPatcher.isSVC(insn) { svcCount += 1 }
                offset += 4
            }
            totalSVC += svcCount
            print("  LOAD[\(i)] exec, vaddr=0x\(String(ph.vaddr, radix: 16)), SVC 数: \(svcCount)")
        }
        print("总 SVC 数: \(totalSVC)")
        // 尝试编码一个 BL 验证范围
        if let first = img.loadSegments.first(where: { $0.isExecutable }) {
            let pc = first.vaddr
            do {
                let bl = try BinaryPatcher.encodeBL(from: pc, to: trapAddr)
                print(String(format: "  样例 BL: pc=0x%llx -> trap=0x%llx, insn=0x%08x", pc, trapAddr, bl))
            } catch PatchError.trapOutOfRange(let from, let to, let dist) {
                print("  ⚠️ BL 超范围: \(from) -> \(to), 距离=\(dist) (>±128MB)")
                print("  需调整 EmulatorConfig.loadBase 使其靠近 trap 地址")
            } catch {
                print("  ⚠️ 编码 BL 失败: \(error)")
            }
        }
    } catch {
        print("ELF 解析失败: \(error)"); exit(1)
    }

case "bench":
    runPatcherBench()

case "syscall":
    guard args.count >= 3 else { print("用法: isycli syscall <nr> [a0..a5]"); exit(1) }
    let nr = Int32(args[2]) ?? 0
    var a: [UInt64] = [0, 0, 0, 0, 0, 0]
    for i in 0..<min(6, args.count - 3) {
        a[i] = UInt64(args[3 + i]) ?? 0
    }
    let proc = LinuxProcess(pid: 1)
    let disp = SyscallDispatcher(process: proc)
    disp.registerCoreSyscalls(process: proc)
    var cpu = isy_cpu_state_t(
        regs: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0),
        sp: 0, pc: 0, pstate: 0, syscall_nr: UInt64(nr)
    )
    let r = disp.dispatch(nr: nr, cpu: &cpu, args: (a[0],a[1],a[2],a[3],a[4],a[5]))
    print("syscall \(SyscallName.name(for: nr)) = \(r)")

default:
    printUsage()
}

// ---------- 微基准 ----------
func runPatcherBench() {
    print("BinaryPatcher 微基准")
    // 构造 1M 条指令的假段, 其中 1% 是 SVC #0
    let count = 1_000_000
    var insns = [UInt32](repeating: 0xD503201F, count: count)  // NOP
    for i in stride(from: 0, to: count, by: 100) {
        insns[i] = 0xD4000001  // SVC #0
    }
    let trapAddr: UInt64 = 0x10000
    let config = PatchConfig(trapAddress: trapAddr)

    insns.withUnsafeMutableBufferPointer { buf in
        var table = PatchTable()
        let start = Date()
        do {
            try BinaryPatcher.patchSegment(buf, baseVA: 0x400000, config: config,
                                           segmentIndex: 0, into: &table)
        } catch {
            print("patch 失败: \(error)"); return
        }
        let elapsed = Date().timeIntervalSince(start)
        print("  段大小: \(count * 4) 字节 (\(count) 条指令)")
        print("  patch 记录: \(table.records.count)")
        print("  耗时: \(String(format: "%.3f", elapsed * 1000)) ms")
        print("  吞吐: \(String(format: "%.1f", Double(count * 4) / 1024 / 1024 / elapsed)) MB/s")
    }
}
