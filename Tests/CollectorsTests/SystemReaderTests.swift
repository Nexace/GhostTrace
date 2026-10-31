import Foundation
@testable import Collectors
import RecorderCore
import Testing

@Test func theLiveReaderSeesThisMac() throws {
    let reading = SystemReader.live.read()
    print("cpu:", reading.cpu as Any, "net:", reading.network as Any, "disk:", reading.disk as Any, "free:", reading.freeSpace as Any, reading.volumeCapacity as Any, "gpu:", reading.gpuUtilization as Any, reading.gpuMemoryInUse as Any, "battery:", reading.battery as Any, "idle:", reading.idleSeconds as Any)
    #expect(try #require(reading.cpu).total > 0)
    #expect(reading.network != nil)
    #expect(reading.disk != nil)
    #expect(reading.freeSpace != nil)
    #expect(reading.memoryUsed != nil)
}

@Test func cachedFreeSpaceStaysCloseToTheFreshReadingAndWithinTheVolume() throws {
    let first = try #require(SystemReader.volumeSpace(now: Date()))
    let second = try #require(SystemReader.volumeSpace(now: Date()))
    #expect(first.free <= first.capacity)
    #expect(first.free.distance(to: second.free).magnitude < (1 << 30))
}

@Test func theInPlaceInterfaceNameMatchesIfIndexToName() throws {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var size = 0
    #expect(sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0)
    var buffer = [UInt8](repeating: 0, count: size + size / 8)
    size = buffer.count
    #expect(sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0)
    var offset = 0, checked = 0, ethernet = 0
    while offset + MemoryLayout<if_msghdr>.size <= size {
        let header = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self) }
        guard header.ifm_msglen > 0 else { break }
        defer { offset += Int(header.ifm_msglen) }
        guard Int32(header.ifm_type) == RTM_IFINFO2 else { continue }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(header.ifm_index), &name) != nil else { continue }
        let expected = String(cString: name).hasPrefix("en")
        #expect(SystemReader.isEthernetName(buffer, link: offset + MemoryLayout<if_msghdr2>.size, end: offset + Int(header.ifm_msglen)) == expected, "\(String(cString: name))")
        checked += 1
        ethernet += expected ? 1 : 0
    }
    #expect(checked > 1 && ethernet > 0)
}
