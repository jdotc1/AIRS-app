import XCTest
@testable import AIRSCore
final class ComponentLoadCommandTests: XCTestCase {
    func testBoundedLoadStringsAndMalformedOffsets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-component-review-20261020/load-tests/\(UUID())/Owned.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList:["CFBundleExecutable":"Main"],format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        func word(_ x: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded:x >> ($0*8)) }) }
        func image(offset: UInt32) -> Data {
            var data = Data([0xcf,0xfa,0xed,0xfe])
            for x: UInt32 in [0x0100000c,0,2,1,48,0,0,0xc,48,offset,0,0x10000,0x10000] { data.append(word(x)) }
            var name = Data("@rpath/Owned.dylib".utf8); name.append(0); name.append(Data(repeating:0,count:24-name.count)); data.append(name)
            return data
        }
        let url = root.appendingPathComponent("Contents/MacOS/Main")
        try image(offset:24).write(to:url)
        let row = try XCTUnwrap(BundleDiscovery().discover(root).entries.first(where: \.selectable))
        var reader = ComponentMetadataReader()
        let values = try reader.readLoadCommands(row)
        XCTAssertEqual(values.first?.path,"@rpath/Owned.dylib")
        XCTAssertEqual(values.first?.architecture,"arm64")
        try image(offset:4).write(to:url)
        let changed = try XCTUnwrap(BundleDiscovery().discover(root).entries.first(where: \.selectable))
        XCTAssertThrowsError(try reader.readLoadCommands(changed))
    }
}
