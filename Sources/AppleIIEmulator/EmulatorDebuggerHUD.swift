import SwiftUI

/// A read-only live monitor plus one-instruction control. It deliberately
/// displays snapshots published by the emulation queue; the view never reads
/// mutable CPU or disk state directly from SwiftUI.
struct EmulatorDebuggerHUD: View {
    @ObservedObject var machine: AppleIIMachine

    var body: some View {
        let cpu = machine.debuggerSnapshot
        let disk = machine.presentedDiskState
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("调试监视器")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Spacer()
                Button("隐藏") { machine.isDebuggerVisible = false }
                    .buttonStyle(.plain)
            }
            Text("PC $\(hex(cpu.pc, width: 4))  A $\(hex(cpu.a))  X $\(hex(cpu.x))  Y $\(hex(cpu.y))")
            Text("SP $\(hex(cpu.sp))  P $\(hex(cpu.p))  CYC \(cpu.cycles)")
            Text("DISK D\(disk.selectedDrive + 1) T\(disk.tracks[disk.selectedDrive])  M:\(disk.motorOn ? "ON" : "OFF")  Q6:\(disk.q6 ? 1 : 0) Q7:\(disk.q7 ? 1 : 0)")
            HStack(spacing: 8) {
                Button("单步") { machine.stepInstruction() }
                    .disabled(machine.isRunning)
                Text(machine.isRunning ? "先暂停" : "已暂停")
            }
            HStack(spacing: 8) {
                Button("快速保存") { machine.saveQuickState() }
                Button("快速恢复") { machine.restoreQuickState() }
                    .disabled(!machine.hasQuickState)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color(red: 0.76, green: 1.0, blue: 0.70))
        .padding(10)
        .frame(width: 315, alignment: .leading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.green.opacity(0.35), lineWidth: 1))
        .padding(16)
    }

    private func hex(_ value: UInt8) -> String { String(format: "%02X", value) }
    private func hex(_ value: UInt16, width: Int) -> String { String(format: "%0*X", width, value) }
}
