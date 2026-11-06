// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-38, AC-38.01, AC-38.07.
import Foundation
import LunletHook

// Claude Code runs this program at the end of every turn of a session that loads Lunlet's Stop hook.
signal(SIGPIPE, SIG_IGN)
let input = FileHandle.standardInput.readDataToEndOfFile()
_ = HookRuntime().run(input: input, pid: getpid(), parentPID: getppid()) { line in
    FileHandle.standardOutput.write(line + Data([0x0A]))
}
exit(0)
