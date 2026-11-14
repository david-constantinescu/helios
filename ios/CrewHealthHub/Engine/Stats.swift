import Foundation

/// Robust, explainable statistics used by the engines. No black-box models.
enum Stats {
    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .nan }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Median absolute deviation (unscaled).
    static func mad(_ xs: [Double], median m: Double? = nil) -> Double {
        guard !xs.isEmpty else { return .nan }
        let med = m ?? median(xs)
        return median(xs.map { abs($0 - med) })
    }

    /// Linear-interpolated percentile, p in 0…100.
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        if s.count == 1 { return s[0] }
        let r = (p / 100) * Double(s.count - 1)
        let lo = Int(r.rounded(.down)), hi = Int(r.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
    }

    /// Theil–Sen robust slope estimator: median of pairwise slopes. Returns nil with fewer than 2 distinct x.
    static func theilSen(_ pts: [(x: Double, y: Double)]) -> Double? {
        guard pts.count >= 2 else { return nil }
        var slopes: [Double] = []
        slopes.reserveCapacity(pts.count * (pts.count - 1) / 2)
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count where pts[j].x != pts[i].x {
                slopes.append((pts[j].y - pts[i].y) / (pts[j].x - pts[i].x))
            }
        }
        return slopes.isEmpty ? nil : median(slopes)
    }

    /// Largest-Triangle-Three-Buckets downsampling for charts.
    static func lttb(_ data: [(x: Double, y: Double)], threshold: Int) -> [(x: Double, y: Double)] {
        guard threshold >= 3, data.count > threshold else { return data }
        var sampled: [(x: Double, y: Double)] = [data[0]]
        let every = Double(data.count - 2) / Double(threshold - 2)
        var a = 0
        for i in 0..<(threshold - 2) {
            let avgStart = Int(Double(i + 1) * every) + 1
            let avgEnd = min(Int(Double(i + 2) * every) + 1, data.count)
            var ax = 0.0, ay = 0.0
            for j in avgStart..<avgEnd { ax += data[j].x; ay += data[j].y }
            let len = Double(max(avgEnd - avgStart, 1)); ax /= len; ay /= len
            let rs = Int(Double(i) * every) + 1, re = Int(Double(i + 1) * every) + 1
            var maxArea = -1.0, next = rs
            for j in rs..<min(re, data.count) {
                let area = abs((data[a].x - ax) * (data[j].y - data[a].y) - (data[a].x - data[j].x) * (ay - data[a].y))
                if area > maxArea { maxArea = area; next = j }
            }
            sampled.append(data[next]); a = next
        }
        sampled.append(data[data.count - 1])
        return sampled
    }
}

extension Double {
    func rounded(to places: Int) -> Double {
        let p = pow(10.0, Double(places)); return (self * p).rounded() / p
    }
    var isUsable: Bool { isFinite && !isNaN }
}
