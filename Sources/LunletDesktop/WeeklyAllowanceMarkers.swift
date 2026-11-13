// SPDX-FileCopyrightText: 2026 yukunlabs
// SPDX-License-Identifier: 0BSD
// Refs: US-04, AC-04.10; US-17, AC-17.07.

enum WeeklyAllowanceMarkers {
    /// Ruler marks of the entry's allowance strand; there are no minor 10% ticks.
    static let references: [Double] = [20, 40, 60, 80]
    /// The low-allowance boundary, drawn longer and in red.
    static let warning: Double = 10
    static var barMarks: [Double] { [warning] + references }
}
