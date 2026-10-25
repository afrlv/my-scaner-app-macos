import CoreGraphics
import Foundation
import Vision

enum RegionDetector {
    static func detect(in overview: CGImage, glassMM: CGSize) async -> [CGRect] {
        await Task.detached(priority: .userInitiated) {
            detectSync(in: overview, glassMM: glassMM)
        }.value
    }

    static func detectSync(in overview: CGImage, glassMM: CGSize) -> [CGRect] {
        var result = finalize(visionBoxes(in: overview, glassMM: glassMM), glassMM: glassMM)
        if result.isEmpty {
            result = finalize(fallbackBoxes(in: overview, glassMM: glassMM), glassMM: glassMM)
        }
        return result.sorted { a, b in
            a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
        }
    }

    private static func finalize(_ boxes: [CGRect], glassMM: CGSize) -> [CGRect] {
        removeNested(collapseDuplicates(boxes))
            .map { ScanGeometry.clamp($0.insetBy(dx: -padding, dy: -padding), to: glassMM) }
            .filter { !$0.isEmpty }
    }

    /// Схлопывает почти совпадающие рамки (IoU > 0.85 или все края в пределах 3 мм), оставляя бо́льшую.
    static func collapseDuplicates(_ boxes: [CGRect]) -> [CGRect] {
        let ordered = boxes.sorted { a, b in
            let areaA = a.width * a.height, areaB = b.width * b.height
            if areaA != areaB { return areaA > areaB }
            return a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
        }
        var kept: [CGRect] = []
        for box in ordered where !kept.contains(where: { nearlyEqual($0, box) }) {
            kept.append(box)
        }
        return kept
    }

    private static func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        let edges = 3.0 as CGFloat
        if abs(a.minX - b.minX) <= edges, abs(a.maxX - b.maxX) <= edges,
           abs(a.minY - b.minY) <= edges, abs(a.maxY - b.maxY) <= edges {
            return true
        }
        let inter = a.intersection(b)
        guard !inter.isNull else { return false }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 && interArea / union > 0.85
    }

    static func fallbackBoxesForTesting(in image: CGImage, glassMM: CGSize) -> [CGRect] {
        fallbackBoxes(in: image, glassMM: glassMM)
    }

    private static let padding: CGFloat = 2
    private static let mergeDistanceMM: CGFloat = 3

    private static func visionBoxes(in image: CGImage, glassMM: CGSize) -> [CGRect] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 8
        request.minimumSize = 0.08
        request.minimumConfidence = 0.6
        request.quadratureTolerance = 30
        request.minimumAspectRatio = 0.1
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).map { obs in
            let b = obs.boundingBox
            return CGRect(
                x: b.minX * glassMM.width,
                y: (1 - b.maxY) * glassMM.height,
                width: b.width * glassMM.width,
                height: b.height * glassMM.height)
        }
    }

    private static func fallbackBoxes(in image: CGImage, glassMM: CGSize) -> [CGRect] {
        let longSide = 200.0
        let scale = min(1, longSide / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = ImageOps.makeContext(width: w, height: h), let data = ctx.data else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self)
        let stride = ctx.bytesPerRow

        func channel(_ x: Int, _ y: Int, _ c: Int) -> Int { Int(px[y * stride + x * 4 + c]) }

        var background = [Int](repeating: 0, count: 3)
        for c in 0..<3 {
            var samples: [Int] = []
            for y in 0..<h {
                for x in 0..<w where x < 2 || y < 2 || x >= w - 2 || y >= h - 2 {
                    samples.append(channel(x, y, c))
                }
            }
            samples.sort()
            background[c] = samples[samples.count / 2]
        }

        let threshold = 40
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var diff = 0
                for c in 0..<3 { diff = max(diff, abs(channel(x, y, c) - background[c])) }
                mask[y * w + x] = diff > threshold
            }
        }

        var visited = [Bool](repeating: false, count: w * h)
        var boxes: [CGRect] = []
        var queue: [Int] = []
        let minArea = Double(w * h) * 0.01
        for start in 0..<(w * h) where mask[start] && !visited[start] {
            visited[start] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var head = 0
            var minX = w, minY = h, maxX = 0, maxY = 0
            while head < queue.count {
                let i = queue[head]
                head += 1
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, mask[i - 1], !visited[i - 1] { visited[i - 1] = true; queue.append(i - 1) }
                if x < w - 1, mask[i + 1], !visited[i + 1] { visited[i + 1] = true; queue.append(i + 1) }
                if y > 0, mask[i - w], !visited[i - w] { visited[i - w] = true; queue.append(i - w) }
                if y < h - 1, mask[i + w], !visited[i + w] { visited[i + w] = true; queue.append(i + w) }
            }
            guard Double(queue.count) >= minArea else { continue }
            boxes.append(CGRect(
                x: CGFloat(minX) / CGFloat(w) * glassMM.width,
                y: CGFloat(minY) / CGFloat(h) * glassMM.height,
                width: CGFloat(maxX - minX + 1) / CGFloat(w) * glassMM.width,
                height: CGFloat(maxY - minY + 1) / CGFloat(h) * glassMM.height))
        }
        return mergeClose(boxes)
    }

    private static func mergeClose(_ input: [CGRect]) -> [CGRect] {
        var boxes = input
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<boxes.count {
                for j in (i + 1)..<max(boxes.count, i + 1) {
                    if boxes[i].insetBy(dx: -mergeDistanceMM / 2, dy: -mergeDistanceMM / 2)
                        .intersects(boxes[j].insetBy(dx: -mergeDistanceMM / 2, dy: -mergeDistanceMM / 2)) {
                        boxes[i] = boxes[i].union(boxes[j])
                        boxes.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return boxes
    }

    private static func removeNested(_ boxes: [CGRect]) -> [CGRect] {
        let tolerance: CGFloat = 0.5
        return boxes.enumerated().filter { index, box in
            !boxes.enumerated().contains { otherIndex, other in
                guard otherIndex != index else { return false }
                let contains = other.insetBy(dx: -tolerance, dy: -tolerance).contains(box)
                if contains && other.insetBy(dx: -tolerance, dy: -tolerance) == box.insetBy(dx: -tolerance, dy: -tolerance) {
                    return otherIndex < index
                }
                return contains
            }
        }.map(\.element)
    }
}
