import Foundation

/// Sorts optional values with unknown (nil) values last, in both directions,
/// so "—" rows never crowd the top of a column.
struct NilsLastComparator<Value: Comparable>: SortComparator, Hashable {
    var order: SortOrder = .forward

    func compare(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending
        case (_, nil):
            return .orderedAscending
        case let (left?, right?):
            if left == right { return .orderedSame }
            let ascending = left < right
            return ascending == (order == .forward) ? .orderedAscending : .orderedDescending
        }
    }
}
