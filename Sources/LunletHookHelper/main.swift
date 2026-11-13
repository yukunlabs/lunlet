// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.07.
import Foundation
import LunletHook

// Claude Code runs this program at the end of every turn of a session that loads Lunlet's Stop hook.
signal(SIGPIPE, SIG_IGN)
let input = FileHandle.standardInput.readDataToEndOfFile()
// Quitting Claude Code mid-hold ends this program with TERM or HUP. From here on those only raise a flag that the
// runtime's waits check, so it removes its stop files, which hold the reply text, and exits 0. They are installed
// after the input is read: until then the signals end the program as usual and there is nothing to remove.
HookInterrupt.install()
_ = HookRuntime(isInterrupted: { HookInterrupt.isRaised }).run(input: input, pid: getpid(), parentPID: getppid()) { line in
    FileHandle.standardOutput.write(line + Data([0x0A]))
}
exit(0)
