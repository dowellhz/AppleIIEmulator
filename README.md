# Apple II Emulator for macOS

一个原生 SwiftUI Apple IIc 模拟器工程，采用硬件总线模型而非“运行 BASIC 的终端”。目前可构建运行，并包含：

![Lode Runner 在内置 Apple IIe 游戏兼容模式中运行](Documentation/lode-runner-gameplay.png)

## About

Apple II Emulator 是一个为 macOS 打造的原生 Apple II 模拟器。它的目标不是把经典软件包装成一个终端，而是以可读、可验证的硬件模型重现 6502、内存映射、视频软开关、Disk II 与一位扬声器的协作方式。

项目使用 Swift、SwiftUI、AppKit、Foundation 和 AVFoundation 构建，不依赖第三方框架。界面保留了 Apple II 时代的显示器与塑料机箱质感，同时将 ROM、磁盘映像、游戏库和输入控制保持在可直接操作的 macOS 应用中。当前重点是可靠启动和运行经典软件；部分外设与受保护磁盘格式仍在持续完善。

- 65C02 核心（包含 IIc 固件所用的 65C02 指令、十进制算术、JMP 间接寻址页尾缺陷）；
- IIc 主/辅助 RAM、80STORE、ALTZP、80 列、双高分辨率和 ROM 银行切换；
- 键盘锁存器、扬声器软开关、40/80 列文字、Lo-Res、Hi-Res、Double Hi-Res 画面；
- 应用内置 Apple IIc ROM 00、03、04、FF，以及仅用于输入排查的诊断 ROM；
- 集成双驱动器 IWM/Disk II，支持 140 KB `.dsk`、`.do`、`.po` 与 35 磁道 `.nib` 映像；`.2mg/.2img` 包装的写保护标记会传递到 IWM 写保护感测；支持保留 quarter-track 映射和 MC3470 弱位近似的 WOZ 1.x/2.x 位流映像（当前只读）；
- IIc 内置双 6551 ACIA：端口 1（打印机，`$C098-$C09B`）和端口 2（调制解调器，`$C0A8-$C0AB`）的寄存器、收发状态与 CPU 周期发送时序；
- IIc 内置鼠标接口：slot 4 的 6821 PIA（`$C0C0-$C0C3`）握手协议、位置/按键、夹紧范围与移动/VBL 中断；显示区域的鼠标移动会馈入该硬件；
- 主板磁带输入/输出（`$C060` / `$C020`）与 Apple II+ 四路 annunciator（`$C058-$C05F`）软开关；
- 顶部“ROM”和“磁盘”菜单：可从内置选项选择 ROM，或按需打开已验证的用户 ROM 映像；磁盘映像独立装入。
- ROM 菜单可额外打开用户有权使用的 ROM 映像：Apple II/II+ 12 KB，或 Apple IIc 16 KB / 32 KB；加载后会按映像类型切换机器并重置。
- 不依赖第三方库，可直接用 Xcode 打开 `Package.swift`。

## 运行

```sh
cd AppleIIEmulator
swift run
```

直接打开 `build/AppleIIEmulator.app` 即可运行。首次启动默认使用内置 Apple II+ Autostart ROM，显示经典 `APPLE ][` 开机画面；默认不插入磁盘。通过 GAME 菜单选择游戏会自动装入驱动器 1 并重新启动。测试启动盘仅保留在“磁盘”菜单中，用于验证 ROM、IWM、GCR 解码和 `$0801` 引导链。点一下屏幕即可输入；若要验证键盘回显，可在“ROM”菜单选择“内置诊断 ROM”。

第三方 `.dsk` / `.do`（DOS 顺序）、`.po`（ProDOS 顺序）、`.nib` 或 WOZ 1.x/2.x 位流映像可通过“磁盘”菜单独立装入驱动器 1 或 2；之后按 Command-R 重置即可由该 ROM 启动。WOZ 目前以只读方式装入，避免在尚未实现 WOZ 容器回写时损坏受保护映像。“磁盘 → 将驱动器 N 另存为 .nib…”会导出当前（包括写入后的）标准 35 磁道 NIB 映像。请只使用你有权使用的磁盘映像。

项目根目录 `Downloads/AppleIIGames/ftp.apple.asimov.net/images/games/action/` 中的下载游戏会在构建时打包进 App：在窗口的 `GAME` 菜单或菜单栏“游戏”中选择“已下载游戏”，再按首字母选择游戏，即可将其装入驱动器 1，并以 Apple II+ 游戏兼容模式启动。打包后的 App 不依赖原下载目录；“从已下载游戏库打开…”仍保留，供后来新增但尚未打包的映像使用。“最近玩过”会同时记录内置游戏和用户装入的一到两张启动磁盘，按最近顺序保留 8 项并去重；若磁盘文件后来移动或删除，重新打开该项时会自动移除失效记录。

## 下一阶段

当前版本以启动和执行为目标。Apple IIc 的两个 6551 ACIA 可从“串口”菜单连接到用户选择的 macOS `/dev/cu.*` 设备；主机 I/O 在独立队列上运行，收发字节仍经 ACIA 寄存器和 6502 周期时序进入模拟器。标准 macOS termios 未提供 3600-baud 档，选择该 ACIA 档位时会明确报错，不会以错误速率通信。WOZ 1.x/2.x 位流目前只读装入，并含保守的弱位近似；WOZ `FLUX`、容器回写以及更完整的 MC3470 读放大/锁相模拟仍待实现。因此它不是逐周期、全外设覆盖的 Apple IIc 保真模拟器。
