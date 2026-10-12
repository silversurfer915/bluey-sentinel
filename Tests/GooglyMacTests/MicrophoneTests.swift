import XCTest
@testable import GooglyMac
final class MicrophoneTests: XCTestCase {
    func testPreferredRouteAndDisconnectFallback() {
        let devices = [MicrophoneDevice(id: 10, uid: "built-in", name: "Built-in"), MicrophoneDevice(id: 20, uid: "usb", name: "USB mic")]
        XCTAssertEqual(MicrophoneStore.resolve(preferredUID: "usb", devices: devices, defaultID: 10), 20)
        XCTAssertEqual(MicrophoneStore.resolve(preferredUID: "usb", devices: Array(devices.prefix(1)), defaultID: 10), 10)
        XCTAssertEqual(MicrophoneStore.resolve(preferredUID: "", devices: devices, defaultID: 10), 10)
    }
}
