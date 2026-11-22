import XCTest
@testable import ElsewhereMobile

final class PairingInboxTests: XCTestCase {
    func testDrainReturnsDataAndFileInReceiptOrderAndRemovesBoth() throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appending(path: "PairingInbox")
        let source = root.appending(path: "device.mobiledevicepairing")
        let bytes = Data(repeating: 7, count: 512 * 1024)
        try bytes.write(to: source)
        let date = Date(timeIntervalSince1970: 1_000)
        let later = PairingInbox(directory: directory, now: { date.addingTimeInterval(1) })
        let earlier = PairingInbox(directory: directory, now: { date })
        let fileID = try later.enqueue(fileURL: source)
        let data = Data([0, 1, 2])
        let dataID = try earlier.enqueue(data: data, suggestedName: nil)

        XCTAssertEqual(later.drainPending(), [
            PendingPairingItem(id: dataID, suggestedName: nil, data: data, receivedAt: date),
            PendingPairingItem(id: fileID, suggestedName: source.lastPathComponent, data: bytes, receivedAt: date.addingTimeInterval(1))
        ])
        XCTAssertTrue(later.drainPending().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testFileSizeErrors() throws {
        let root = try makeTemporaryDirectory()
        let inbox = PairingInbox(directory: root.appending(path: "PairingInbox"))
        let source = root.appending(path: "device.plist")
        for (count, expected) in [(0, PairingInboxError.emptyFile), (512 * 1024 + 1, .fileTooLarge)] {
            try Data(repeating: 0, count: count).write(to: source)
            do {
                _ = try inbox.enqueue(fileURL: source)
                XCTFail("文件大小超出允许范围")
            } catch {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testDrainDeletesExpiredItemAndKeepsFreshItem() throws {
        let directory = try makeTemporaryDirectory()
        let date = Date(timeIntervalSince1970: 1_000)
        let initial = PairingInbox(directory: directory, now: { date })
        _ = try initial.enqueue(data: Data([1]), suggestedName: nil)
        let fresh = PairingInbox(directory: directory, now: { date.addingTimeInterval(599) })
        let id = try fresh.enqueue(data: Data([2]), suggestedName: "new.plist")
        let reader = PairingInbox(directory: directory, now: { date.addingTimeInterval(601) })
        XCTAssertEqual(reader.drainPending().map(\.id), [id])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
