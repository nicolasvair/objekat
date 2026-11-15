import Foundation

// WHICH AUTOMATION ROWS A ZONE REACHES — the arithmetic, with no model behind it.
//
// A row of automation is a DISPLAY lane, and two objects can sit on the same lane at different
// instants (the ordinary case: consecutive children of a group). Both bands then answer to the same
// lane number, but each one exists only over its own object's window. Filtering the rows by lane
// alone therefore confused the two: a copy took an empty row it had no business with, a paste wiped
// or wrote on the OTHER object outside its window, and the point selection gathered points that are
// not even on screen.
//
// A row is reached when its span (the object's window, in absolute seconds; unbounded for an
// infinite bus, which has none) and the zone share some time. Compiled alone by
// tools/test_automation_rows_in_zone.swift, which is why it knows nothing but numbers.
enum AutomationZoneFilter {

    /// What counts as "no length" — the same figure for the zone and for the shared stretch, so that
    /// two objects laid end to end (the end of one a rounding error away from the start of the next)
    /// do not read as overlapping.
    static let epsilon = 1e-9

    /// The window a row exists over, in ABSOLUTE timeline seconds. An infinite bus has neither a
    /// start nor an end: its band covers the whole timeline.
    static func span(origin: Double, duration: Double, isInfinite: Bool) -> ClosedRange<Double> {
        isInfinite ? (-Double.infinity)...Double.infinity : origin...(origin + max(0, duration))
    }

    /// Does a zone reach a row's span?
    ///
    /// - A zone with a LENGTH reaches the rows it shares a stretch of time with — a stretch of
    ///   positive length: touching at one instant is not sharing, otherwise a zone laid exactly
    ///   over the second of two consecutive children would take the first one too.
    /// - A zone with NO length (a point) reaches the rows it is inside of, edges included.
    static func reaches(span: ClosedRange<Double>, zone: ClosedRange<Double>) -> Bool {
        if zone.upperBound - zone.lowerBound <= epsilon {
            return span.contains(zone.lowerBound)
        }
        return span.lowerBound < zone.upperBound - epsilon
            && span.upperBound > zone.lowerBound + epsilon
    }

    /// The rows on the zone's lanes whose span the zone reaches, in their order.
    static func rows<Row>(_ rows: [Row], lanes: Set<Int>, zone: ClosedRange<Double>,
                          lane: (Row) -> Int, span: (Row) -> ClosedRange<Double>) -> [Row] {
        rows.filter { lanes.contains(lane($0)) && reaches(span: span($0), zone: zone) }
    }
}
