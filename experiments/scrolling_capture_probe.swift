// Independent feasibility probe; not linked into CaptureLab or exposed as a feature.
// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift experiments/scrolling_capture_probe.swift --self-test
// ... --compare first.png second.png vertical|horizontal [stitched.png]
// ... --capture x,y,width,height output-directory
import AppKit
import Foundation

struct Pixels {
    let width: Int
    let height: Int
    var values: [UInt8]
    init(width: Int, height: Int, values: [UInt8]) {
        self.width = width; self.height = height; self.values = values
    }
    init(url: URL) throws {
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width <= 4096, cg.height <= 4096 else { throw ProbeError.invalidImage }
        width = cg.width; height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        guard success else { throw ProbeError.invalidImage }
        values = bytes
    }
}
enum ProbeError: Error { case invalidImage, invalidArguments, captureFailed }
struct Match: Codable {
    let shift: Int
    let meanError: Double
    let ambiguityGap: Double
    let accepted: Bool
}

func match(_ first: Pixels, _ second: Pixels, horizontal: Bool) throws -> Match {
    guard first.width == second.width, first.height == second.height else { throw ProbeError.invalidImage }
    let length = horizontal ? first.width : first.height
    let breadth = horizontal ? first.height : first.width
    let margin = max(4, length / 10)
    guard length >= 80 else { throw ProbeError.invalidImage }
    var scores: [(shift: Int, error: Double)] = []
    for shift in 0..<(length - max(48, 2 * margin)) {
        var total = 0.0
        var count = 0
        for major in stride(from: margin, to: length - shift - margin, by: 3) {
            for minor in stride(from: 8, to: breadth - 8, by: 7) {
                let a = horizontal ? (minor * first.width + major + shift) * 4 : ((major + shift) * first.width + minor) * 4
                let b = horizontal ? (minor * second.width + major) * 4 : (major * second.width + minor) * 4
                for channel in 0..<3 {
                    total += abs(Double(first.values[a + channel]) - Double(second.values[b + channel]))
                    count += 1
                }
            }
        }
        if count > 0 { scores.append((shift, total / Double(count))) }
    }
    scores.sort { $0.error < $1.error }
    guard let best = scores.first else { throw ProbeError.invalidImage }
    let runner = scores.first { abs($0.shift - best.shift) > 3 }?.error ?? best.error
    return Match(shift: best.shift, meanError: best.error, ambiguityGap: runner - best.error,
                 accepted: best.error < 8 && runner - best.error > 8)
}

func fixture(offset: Int, horizontal: Bool, repeated: Bool = false, fixedHeader: Bool = false,
             width: Int = 192, height: Int = 192) -> Pixels {
    var values = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let major = (horizontal ? x : y) + offset
            let minor = horizontal ? y : x
            for channel in 0..<3 {
                let value = repeated ? (major % 12) * 16 : (major * 79 + minor * 17 + channel * 53 + (major * minor % 97)) % 256
                values[(y * width + x) * 4 + channel] = fixedHeader && y < 18 ? 235 : UInt8(value)
            }
        }
    }
    return Pixels(width: width, height: height, values: values)
}

func stitch(_ first: Pixels, _ second: Pixels, result: Match, horizontal: Bool) throws -> Pixels {
    guard result.accepted else { throw ProbeError.invalidImage }
    let width = first.width + (horizontal ? result.shift : 0)
    let height = first.height + (horizontal ? 0 : result.shift)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let inFirst = x < first.width && y < first.height
            let source = inFirst ? first : second
            let sx = inFirst ? x : x - (horizontal ? result.shift : 0)
            let sy = inFirst ? y : y - (horizontal ? 0 : result.shift)
            for channel in 0..<4 { bytes[(y * width + x) * 4 + channel] = source.values[(sy * source.width + sx) * 4 + channel] }
        }
    }
    return Pixels(width: width, height: height, values: bytes)
}

func write(_ pixels: Pixels, to url: URL) throws {
    guard let provider = CGDataProvider(data: Data(pixels.values) as CFData),
          let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ProbeError.invalidImage }
    try data.write(to: url, options: .atomic)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if arguments == ["--self-test"] {
    var results: [String: Match] = [:]
    results["vertical"] = try match(fixture(offset: 0, horizontal: false), fixture(offset: 57, horizontal: false), horizontal: false)
    results["horizontal"] = try match(fixture(offset: 0, horizontal: true), fixture(offset: 42, horizontal: true), horizontal: true)
    results["fixed-header"] = try match(fixture(offset: 0, horizontal: false, fixedHeader: true), fixture(offset: 57, horizontal: false, fixedHeader: true), horizontal: false)
    results["repeated-pattern"] = try match(fixture(offset: 0, horizontal: false, repeated: true), fixture(offset: 48, horizontal: false, repeated: true), horizontal: false)
    results["duplicate"] = try match(fixture(offset: 0, horizontal: false), fixture(offset: 0, horizontal: false), horizontal: false)
    precondition(results["vertical"]?.shift == 57 && results["vertical"]?.accepted == true)
    precondition(results["horizontal"]?.shift == 42 && results["horizontal"]?.accepted == true)
    precondition(results["fixed-header"]?.shift == 57 && results["fixed-header"]?.accepted == true)
    precondition(results["repeated-pattern"]?.accepted == false)
    precondition(results["duplicate"]?.shift == 0 && results["duplicate"]?.accepted == true)
    let vertical = try stitch(fixture(offset: 0, horizontal: false), fixture(offset: 57, horizontal: false), result: results["vertical"]!, horizontal: false)
    precondition(vertical.values == fixture(offset: 0, horizontal: false, height: 249).values)
    let horizontal = try stitch(fixture(offset: 0, horizontal: true), fixture(offset: 42, horizontal: true), result: results["horizontal"]!, horizontal: true)
    precondition(horizontal.values == fixture(offset: 0, horizontal: true, width: 234).values)
    print(String(decoding: try encoder.encode(results), as: UTF8.self))
} else if [4, 5].contains(arguments.count), arguments[0] == "--compare", ["vertical", "horizontal"].contains(arguments[3]) {
    let first = try Pixels(url: URL(fileURLWithPath: arguments[1]))
    let second = try Pixels(url: URL(fileURLWithPath: arguments[2]))
    let horizontal = arguments[3] == "horizontal"
    let result = try match(first, second, horizontal: horizontal)
    print(String(decoding: try encoder.encode(result), as: UTF8.self))
    if arguments.count == 5 { try write(stitch(first, second, result: result, horizontal: horizontal), to: URL(fileURLWithPath: arguments[4])) }
} else if arguments.count == 3, arguments[0] == "--capture" {
    let region = arguments[1].split(separator: ",").compactMap { Int($0) }
    guard region.count == 4, region[2] > 0, region[3] > 0 else { throw ProbeError.invalidArguments }
    let output = URL(fileURLWithPath: arguments[2]).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    print("Move this terminal outside the selected region. Press Return after each manual scroll, or type q to finish.")
    var index = 0
    while let line = readLine(), line != "q" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R" + arguments[1], output.appendingPathComponent("frame-\(index).png").path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProbeError.captureFailed }
        index += 1
        print("Captured frame \(index) in \(output.path)")
    }
} else {
    print("Usage: --self-test | --compare first.png second.png vertical|horizontal [stitched.png] | --capture x,y,width,height output-directory")
    exit(2)
}
