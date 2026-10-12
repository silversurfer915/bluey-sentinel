import AppKit
import AVFoundation
import CoreAudio
import Combine

struct MicrophoneDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Bluey's input route; changing it never changes the Mac's system input setting.
@MainActor
final class MicrophoneStore: ObservableObject {
    static let shared = MicrophoneStore()
    @Published private(set) var devices: [MicrophoneDevice] = []
    @Published private(set) var selectedUID = UserDefaults.standard.string(forKey: "blueyMicrophoneUID") ?? ""
    @Published private(set) var status = ""
    var onRouteChanged: (() -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?
    private var addresses = [AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain), AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)]

    init() {
        refresh()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh(); self?.onRouteChanged?() }
        }
        self.listener = listener
        for index in addresses.indices {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[index], .main, listener)
        }
    }
    func select(_ uid: String) {
        guard uid != selectedUID else { return }
        selectedUID = uid
        UserDefaults.standard.set(uid, forKey: "blueyMicrophoneUID")
        refresh()
        onRouteChanged?()
    }
    nonisolated static func resolve(preferredUID: String, devices: [MicrophoneDevice], defaultID: AudioDeviceID) -> AudioDeviceID {
        devices.first { $0.uid == preferredUID }?.id ?? defaultID
    }
    var activeName: String {
        devices.first { $0.id == activeDeviceID }?.name ?? "System default"
    }
    var activeDeviceID: AudioDeviceID {
        var address = addresses[1], device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return Self.resolve(preferredUID: selectedUID, devices: devices, defaultID: device)
    }
    func refresh() {
        var address = addresses[0], size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        guard size > 0 else { devices = []; status = "No microphone available"; return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { return }
        devices = ids.compactMap { id in
            var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain), inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &input, 0, nil, &inputSize) == noErr, inputSize > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return MicrophoneDevice(id: id, uid: uid, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        status = !selectedUID.isEmpty && !devices.contains(where: { $0.uid == selectedUID }) ? "Preferred mic disconnected · using \(activeName)" : "Input · \(activeName)"
    }
    private func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer))
        }
        guard result == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }
    var activeUID: String? { devices.first { $0.id == activeDeviceID }?.uid }
}
