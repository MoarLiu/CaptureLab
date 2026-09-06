import Foundation

/// Release ordering shared by the checker's Swift code and parity tests for
/// the installer's shell comparison. Legacy short/zero-padded cores are valid.
struct UpdateVersion: Comparable {
    static let validationPattern = #"^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)?(\+[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*)?$"#

    private let core: [String]
    private let prerelease: [String]?

    init?(_ value: String) {
        guard let range = value.range(of: Self.validationPattern, options: .regularExpression),
              range == value.startIndex..<value.endIndex else {
            return nil
        }
        let version = value.split(separator: "+", maxSplits: 1)[0]
        let parts = version.split(separator: "-", maxSplits: 1)
        var core = parts[0].split(separator: ".").map { Self.normalizedDecimal(String($0)) }
        while core.count > 1, core.last == "0" {
            core.removeLast()
        }
        self.core = core
        self.prerelease = parts.count == 2 ? parts[1].split(separator: ".").map {
            Self.isDecimal(String($0)) ? Self.normalizedDecimal(String($0)) : String($0)
        } : nil
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.core.count, rhs.core.count) {
            let left = index < lhs.core.count ? lhs.core[index] : "0"
            let right = index < rhs.core.count ? rhs.core[index] : "0"
            if left != right { return decimalIsLess(left, right) }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case (let left?, let right?):
            for (leftPart, rightPart) in zip(left, right) where leftPart != rightPart {
                let leftIsDecimal = isDecimal(leftPart)
                let rightIsDecimal = isDecimal(rightPart)
                if leftIsDecimal && rightIsDecimal { return decimalIsLess(leftPart, rightPart) }
                if leftIsDecimal != rightIsDecimal { return leftIsDecimal }
                return leftPart < rightPart
            }
            return left.count < right.count
        }
    }

    private static func normalizedDecimal(_ value: String) -> String {
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func isDecimal(_ value: String) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func decimalIsLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }
}
