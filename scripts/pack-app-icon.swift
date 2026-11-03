import Foundation

// Modern ICNS elements contain complete PNGs, each preceded by a four-byte
// representation type and a big-endian size that includes the element header.
func element(_ type: String, payload: Data) -> Data {
    var data = Data(type.utf8)
    var length = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift pack-app-icon.swift INPUT.iconset OUTPUT.icns\n", stderr)
    exit(1)
}

let iconSet = URL(fileURLWithPath: CommandLine.arguments[1])
let representations = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]
var images = Data()
for (type, name) in representations {
    let png = try Data(contentsOf: iconSet.appendingPathComponent(name))
    guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
        fputs("Not a PNG: \(name)\n", stderr)
        exit(1)
    }
    images.append(element(type, payload: png))
}
try element("icns", payload: images).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
