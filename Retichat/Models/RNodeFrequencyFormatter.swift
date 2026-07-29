import Foundation

enum RNodeFrequencyFormatter {
    static func mhzText(for frequencyHz: UInt64) -> String {
        let wholeMHz = frequencyHz / 1_000_000
        let remainderHz = frequencyHz % 1_000_000
        guard remainderHz != 0 else { return String(wholeMHz) }

        let fraction = String(format: "%06llu", remainderHz)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return "\(wholeMHz).\(fraction)"
    }
}
