import Foundation
import CoreGraphics

/// Exposure history belongs to one capture pipeline, including tap-to-focus holds.
struct SubjectMeteringSession {
    private var lastMeteredRect: CGRect?
    private var suspendedUntil: Date?

    mutating func suspend(until date: Date) {
        suspendedUntil = date
        lastMeteredRect = nil
    }

    mutating func reset() {
        lastMeteredRect = nil
        suspendedUntil = nil
    }

    mutating func region(for bounds: CGRect, at date: Date) -> CGRect? {
        if let until = suspendedUntil, date < until { return nil }

        // The upper-middle of the person box excludes most torso and desk.
        let rect: CGRect = CGRect(x: bounds.minX + bounds.width * 0.2,
                          y: bounds.minY,
                          width: bounds.width * 0.6,
                          height: max(bounds.height * 0.45, 0.05))
        if let last = lastMeteredRect {
            let moved: CGFloat = abs(rect.midX - last.midX) + abs(rect.midY - last.midY)
                      + abs(rect.width - last.width) + abs(rect.height - last.height)
            guard moved > 0.06 else { return nil }
        }
        lastMeteredRect = rect
        return rect
    }
}
