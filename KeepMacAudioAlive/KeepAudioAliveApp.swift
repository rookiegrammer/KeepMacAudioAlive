import SwiftUI
import CoreAudio
import AVFoundation
import AppKit
internal import Combine

// MARK: - Models

struct AudioDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isConnected: Bool
    
    init(id: AudioDeviceID, uid: String, name: String, isConnected: Bool = true) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isConnected = isConnected
    }
}

// MARK: - CoreAudio Engine

class AudioEngine: ObservableObject {
    static let shared = AudioEngine()
    
    // Playback state
    @Published var isRunning: Bool = false
    @Published var currentlyActiveDeviceUID: String?
    @Published var currentlyActiveDeviceName: String?
    
    // Connected hardware devices
    @Published var devices: [AudioDevice] = []
    
    // Multi-select interfaces (persisted UIDs, includes disconnected ones)
    @Published var selectedDeviceUIDs: Set<String> = []
    
    // Cache of known device names: UID -> Name (for disconnected devices)
    @Published var knownDeviceNames: [String: String] = [:]
    
    // Feature toggles
    @Published var isAutoRunEnabled: Bool = true
    @Published var isUniversalEnabled: Bool = true
    @Published var isAutoRunActive: Bool = false
    
    // Collapsible section state for window UI
    @Published var isOutputsExpanded: Bool = true
    
    // Sleep management state
    @Published var isSystemSleeping: Bool = false
    private var wasRunningBeforeSleep: Bool = false
    
    // Current macOS default output
    @Published var currentSystemOutputID: AudioDeviceID?
    @Published var currentSystemOutputUID: String?
    @Published var currentSystemOutputName: String?
    
    // App presentation preference
    @Published var runInMenuBarOnly: Bool = false
    
    // Legacy / manual single device selection
    @Published var manualSelectedDeviceUID: String?
    
    private var ioProcID: AudioDeviceIOProcID?
    private var currentDeviceID: AudioDeviceID?
    
    private let userDefaults = UserDefaults.standard
    private let kSelectedUIDsKey = "SelectedDeviceUIDs"
    private let kKnownNamesKey = "KnownDeviceNames"
    private let kAutoRunEnabledKey = "IsAutoRunEnabled"
    private let kUniversalEnabledKey = "IsUniversalEnabled"
    private let kRunInMenuBarOnlyKey = "RunInMenuBarOnly"
    private let kOutputsExpandedKey = "IsOutputsExpanded"
    private let kLegacySelectedUIDKey = "LastSelectedDeviceUID"
    
    init() {
        // Load persisted preferences
        if userDefaults.object(forKey: kRunInMenuBarOnlyKey) != nil {
            self.runInMenuBarOnly = userDefaults.bool(forKey: kRunInMenuBarOnlyKey)
        } else {
            self.runInMenuBarOnly = false
        }
        
        if userDefaults.object(forKey: kAutoRunEnabledKey) != nil {
            self.isAutoRunEnabled = userDefaults.bool(forKey: kAutoRunEnabledKey)
        } else {
            self.isAutoRunEnabled = true
        }
        
        if userDefaults.object(forKey: kUniversalEnabledKey) != nil {
            self.isUniversalEnabled = userDefaults.bool(forKey: kUniversalEnabledKey)
        } else {
            self.isUniversalEnabled = true
        }
        
        if userDefaults.object(forKey: kOutputsExpandedKey) != nil {
            self.isOutputsExpanded = userDefaults.bool(forKey: kOutputsExpandedKey)
        } else {
            self.isOutputsExpanded = true
        }
        
        if let savedNames = userDefaults.dictionary(forKey: kKnownNamesKey) as? [String: String] {
            self.knownDeviceNames = savedNames
        }
        
        if let savedUIDs = userDefaults.stringArray(forKey: kSelectedUIDsKey) {
            self.selectedDeviceUIDs = Set(savedUIDs)
        } else if let legacyUID = userDefaults.string(forKey: kLegacySelectedUIDKey) {
            self.selectedDeviceUIDs = [legacyUID]
        }
        
        self.manualSelectedDeviceUID = userDefaults.string(forKey: kLegacySelectedUIDKey)
        
        // Ensure CoreAudio HAL knows this process allows the CPU to idle sleep
        configureAllowSleep()
        
        refreshDevices()
        setupListeners()
    }
    
    deinit {
        // Remove CoreAudio listeners
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, hardwareListenerCallback, selfPointer)
        
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &outputAddress, defaultOutputListenerCallback, selfPointer)
        
        // Remove sleep / wake observers
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        
        stop()
    }
    
    // MARK: - Power & Sleep Management
    
    /// Tells CoreAudio that this process allows the CPU to idle sleep even when audio IO is active
    func configureAllowSleep() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertySleepingIsAllowed,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var allowSleep: UInt32 = 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &allowSleep
        )
        if status != noErr {
            print("Notice: kAudioHardwarePropertySleepingIsAllowed returned: \(status)")
        }
    }
    
    @objc private func handleWillSleep(_ notification: Notification) {
        print("Mac is preparing to sleep. Pausing audio keep-alive.")
        isSystemSleeping = true
        wasRunningBeforeSleep = isRunning
        if isRunning {
            stop()
        }
    }
    
    @objc private func handleDidWake(_ notification: Notification) {
        print("Mac woke from sleep. Restoring audio keep-alive.")
        isSystemSleeping = false
        configureAllowSleep()
        
        // Immediately refresh devices
        refreshDevices()
        
        // External USB DACs and Bluetooth devices may take a moment to re-enumerate on wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, !self.isSystemSleeping else { return }
            self.refreshDevices()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.isSystemSleeping else { return }
            self.refreshDevices()
        }
    }
    
    // MARK: - Device Management
    
    func refreshDevices() {
        DispatchQueue.main.async {
            self._refreshDevicesInternal()
        }
    }
    
    private func _refreshDevicesInternal() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        
        var newDevices: [AudioDevice] = []
        
        for id in deviceIDs {
            var outputStreamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &outputStreamAddress, 0, nil, &streamSize)
            
            if streamSize > 0 {
                let name = getDeviceStringProperty(id: id, selector: kAudioObjectPropertyName)
                let uid = getDeviceStringProperty(id: id, selector: kAudioDevicePropertyDeviceUID)
                
                newDevices.append(AudioDevice(id: id, uid: uid, name: name, isConnected: true))
                if uid != "Unknown" && name != "Unknown" && !name.isEmpty {
                    self.knownDeviceNames[uid] = name
                }
            }
        }
        
        self.devices = newDevices
        saveKnownNames()
        
        // Handle Disconnection of currently active device
        if isRunning, let currentID = currentDeviceID {
            let deviceStillExists = newDevices.contains { $0.id == currentID }
            if !deviceStillExists {
                print("Active audio device disconnected. Stopping active IOProc.")
                stop()
            }
        }
        
        updateCurrentSystemOutput()
        
        // If first launch and no selection exists, select the current system output
        if selectedDeviceUIDs.isEmpty, let currentUID = currentSystemOutputUID {
            selectedDeviceUIDs.insert(currentUID)
            saveSelectedUIDs()
        }
        
        if manualSelectedDeviceUID == nil, let first = newDevices.first {
            manualSelectedDeviceUID = first.uid
        }
        
        evaluateKeepAlive()
    }
    
    func updateCurrentSystemOutput() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        
        if status == noErr && deviceID != 0 {
            let name = getDeviceStringProperty(id: deviceID, selector: kAudioObjectPropertyName)
            let uid = getDeviceStringProperty(id: deviceID, selector: kAudioDevicePropertyDeviceUID)
            self.currentSystemOutputID = deviceID
            self.currentSystemOutputUID = uid
            self.currentSystemOutputName = name
            if uid != "Unknown" && name != "Unknown" && !name.isEmpty {
                self.knownDeviceNames[uid] = name
                saveKnownNames()
            }
        } else {
            self.currentSystemOutputID = nil
            self.currentSystemOutputUID = nil
            self.currentSystemOutputName = nil
        }
    }
    
    func handleDefaultOutputChanged() {
        updateCurrentSystemOutput()
        evaluateKeepAlive()
    }
    
    // MARK: - Keep-Alive State Evaluation
    
    func evaluateKeepAlive() {
        // 0. Do not start IOProc while the Mac is sleeping
        guard !isSystemSleeping else {
            if isRunning {
                stop()
            }
            isAutoRunActive = false
            return
        }
        
        // 1. Universal switch check
        guard isUniversalEnabled else {
            if isRunning {
                stop()
            }
            isAutoRunActive = false
            return
        }
        
        // 2. Auto Run logic
        if isAutoRunEnabled {
            guard let curUID = currentSystemOutputUID, !curUID.isEmpty else {
                if isRunning {
                    stop()
                }
                isAutoRunActive = false
                return
            }
            
            // Check if current system output matches one of the selected interfaces
            if selectedDeviceUIDs.contains(curUID) {
                if let targetDevice = devices.first(where: { $0.uid == curUID }) {
                    if isRunning && currentDeviceID == targetDevice.id {
                        isAutoRunActive = true
                    } else {
                        start(deviceID: targetDevice.id, uid: curUID, name: targetDevice.name)
                        isAutoRunActive = isRunning
                    }
                } else {
                    if isRunning {
                        stop()
                    }
                    isAutoRunActive = false
                }
            } else {
                // Not in selected interfaces: stop keeping alive
                if isRunning {
                    stop()
                }
                isAutoRunActive = false
            }
        } else {
            // Manual mode: if waking from sleep and was previously running, restore
            isAutoRunActive = false
            if wasRunningBeforeSleep && !isRunning {
                if let uid = manualSelectedDeviceUID, let dev = devices.first(where: { $0.uid == uid }) {
                    start(deviceID: dev.id, uid: uid, name: dev.name)
                }
            }
        }
    }
    
    // MARK: - User Intent Actions
    
    func toggleOutputsExpanded() {
        isOutputsExpanded.toggle()
        userDefaults.set(isOutputsExpanded, forKey: kOutputsExpandedKey)
        WindowManager.shared.adjustWindowHeight(expanded: isOutputsExpanded)
    }
    
    func toggleDeviceSelection(uid: String) {
        if selectedDeviceUIDs.contains(uid) {
            selectedDeviceUIDs.remove(uid)
        } else {
            selectedDeviceUIDs.insert(uid)
        }
        saveSelectedUIDs()
        evaluateKeepAlive()
    }
    
    func selectAllConnectedDevices() {
        for device in devices {
            selectedDeviceUIDs.insert(device.uid)
        }
        saveSelectedUIDs()
        evaluateKeepAlive()
    }
    
    func deselectAllDevices() {
        selectedDeviceUIDs.removeAll()
        saveSelectedUIDs()
        evaluateKeepAlive()
    }
    
    func toggleAutoRun() {
        isAutoRunEnabled.toggle()
        userDefaults.set(isAutoRunEnabled, forKey: kAutoRunEnabledKey)
        evaluateKeepAlive()
    }
    
    func toggleUniversalEnabled() {
        isUniversalEnabled.toggle()
        userDefaults.set(isUniversalEnabled, forKey: kUniversalEnabledKey)
        evaluateKeepAlive()
    }
    
    func toggleRunInMenuBarOnly() {
        runInMenuBarOnly.toggle()
        userDefaults.set(runInMenuBarOnly, forKey: kRunInMenuBarOnlyKey)
        WindowManager.shared.applyAppMode(menuBarOnly: runInMenuBarOnly)
    }
    
    func setRunInMenuBarOnly(_ value: Bool) {
        guard runInMenuBarOnly != value else { return }
        runInMenuBarOnly = value
        userDefaults.set(runInMenuBarOnly, forKey: kRunInMenuBarOnlyKey)
        WindowManager.shared.applyAppMode(menuBarOnly: runInMenuBarOnly)
    }
    
    // Manual Start / Stop for legacy or manual single-device mode
    func manualStart() {
        guard let uid = manualSelectedDeviceUID,
              let device = devices.first(where: { $0.uid == uid }) else { return }
        start(deviceID: device.id, uid: uid, name: device.name)
    }
    
    func manualStop() {
        wasRunningBeforeSleep = false
        stop()
    }
    
    // MARK: - CoreAudio IOProc Operations
    
    func start(deviceID: AudioDeviceID, uid: String, name: String) {
        guard !isSystemSleeping else { return }
        
        if isRunning {
            if currentDeviceID == deviceID {
                return
            }
            stop()
        }
        
        // Ensure sleep is allowed by CoreAudio HAL
        configureAllowSleep()
        
        let status = AudioDeviceCreateIOProcID(deviceID, renderCallback, nil, &ioProcID)
        guard status == noErr, let procID = ioProcID else {
            print("Error creating IOProc: \(status)")
            ioProcID = nil
            currentDeviceID = nil
            currentlyActiveDeviceUID = nil
            currentlyActiveDeviceName = nil
            isRunning = false
            return
        }
        
        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            print("Error starting AudioDevice: \(startStatus)")
            AudioDeviceDestroyIOProcID(deviceID, procID)
            ioProcID = nil
            currentDeviceID = nil
            currentlyActiveDeviceUID = nil
            currentlyActiveDeviceName = nil
            isRunning = false
            return
        }
        
        currentDeviceID = deviceID
        currentlyActiveDeviceUID = uid
        currentlyActiveDeviceName = name
        isRunning = true
        userDefaults.set(uid, forKey: kLegacySelectedUIDKey)
    }
    
    func stop() {
        guard let deviceID = currentDeviceID, let procID = ioProcID else {
            ioProcID = nil
            currentDeviceID = nil
            currentlyActiveDeviceUID = nil
            currentlyActiveDeviceName = nil
            isRunning = false
            return
        }
        
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        
        ioProcID = nil
        currentDeviceID = nil
        currentlyActiveDeviceUID = nil
        currentlyActiveDeviceName = nil
        isRunning = false
    }
    
    // MARK: - Hardware & Notification Listeners Setup
    
    private func setupListeners() {
        // 1. CoreAudio device changes (plug/unplug)
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, hardwareListenerCallback, selfPointer)
        
        // 2. CoreAudio default output changes
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &outputAddress, defaultOutputListenerCallback, selfPointer)
        
        // 3. System Sleep / Wake notifications
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(handleDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    private func getDeviceStringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var stringRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &stringRef)
        if status == noErr, let existingRef = stringRef {
            return existingRef.takeRetainedValue() as String
        }
        return "Unknown"
    }
    
    private func saveSelectedUIDs() {
        userDefaults.set(Array(selectedDeviceUIDs), forKey: kSelectedUIDsKey)
    }
    
    private func saveKnownNames() {
        userDefaults.set(knownDeviceNames, forKey: kKnownNamesKey)
    }
}

// MARK: - C Listeners & Callbacks

private let renderCallback: AudioDeviceIOProc = { (inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData) -> OSStatus in
    let bufferList = UnsafeMutableAudioBufferListPointer(outOutputData)
    for buffer in bufferList {
        if let dataPointer = buffer.mData, buffer.mDataByteSize > 0 {
            memset(dataPointer, 0, Int(buffer.mDataByteSize))
        }
    }
    return noErr
}

func hardwareListenerCallback(
    objectID: AudioObjectID,
    numberAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    if let clientData = clientData {
        let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
        engine.refreshDevices()
    }
    return noErr
}

func defaultOutputListenerCallback(
    objectID: AudioObjectID,
    numberAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    if let clientData = clientData {
        let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
        DispatchQueue.main.async {
            engine.handleDefaultOutputChanged()
        }
    }
    return noErr
}

// MARK: - Window Manager

class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    
    var window: NSWindow?
    private var isConfigured = false
    
    func setupWindowIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        
        let initialHeight: CGFloat = AudioEngine.shared.isOutputsExpanded ? 550 : 310
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Keep Mac Audio Alive"
        win.minSize = NSSize(width: 400, height: 280)
        win.maxSize = NSSize(width: 650, height: 900)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        
        let hostingController = NSHostingController(
            rootView: ContentView()
                .environmentObject(AudioEngine.shared)
        )
        win.contentViewController = hostingController
        self.window = win
    }
    
    func adjustWindowHeight(expanded: Bool) {
        guard let win = window else { return }
        var frame = win.frame
        let targetHeight: CGFloat = expanded ? 550 : 310
        let diff = targetHeight - frame.size.height
        guard abs(diff) > 10 else { return }
        
        // In Cocoa screen coordinates, the origin is bottom-left.
        // Decreasing origin.y keeps the window's top-left corner stable on screen while expanding downward.
        frame.origin.y -= diff
        frame.size.height = targetHeight
        win.setFrame(frame, display: true, animate: true)
    }
    
    func applyAppMode(menuBarOnly: Bool) {
        setupWindowIfNeeded()
        if menuBarOnly {
            NSApp.setActivationPolicy(.accessory)
            window?.orderOut(nil)
        } else {
            NSApp.setActivationPolicy(.regular)
            showWindow()
        }
    }
    
    func showWindow() {
        setupWindowIfNeeded()
        if AudioEngine.shared.runInMenuBarOnly {
            // When opened from menu bar in accessory mode, order front and activate
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.setActivationPolicy(.regular)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func hideWindow() {
        window?.orderOut(nil)
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - Menu Bar Controller

class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private let engine = AudioEngine.shared
    
    func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        
        self.statusItem = item
        updateStatusItemAppearance()
        
        // Observe engine changes to refresh status bar icon / tooltip
        engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemAppearance()
                }
            }
            .store(in: &cancellables)
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        sender.isHighlighted = true
        menuNeedsUpdate(menu)
        
        // Present the menu anchored with a 5pt margin below the status button,
        // matching the native macOS menu bar dropdown spacing (similar to Stats' 3-5pt offset)
        let point = NSPoint(x: 0, y: sender.bounds.height + 5)
        menu.popUp(positioning: nil, at: point, in: sender)
        
        sender.isHighlighted = false
    }
    
    func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        
        let symbolName: String
        if engine.isSystemSleeping {
            symbolName = "moon.zzz.fill"
        } else if !engine.isUniversalEnabled {
            symbolName = "waveform.slash"
        } else if engine.isAutoRunActive {
            symbolName = "waveform.circle.fill"
        } else if engine.isRunning {
            symbolName = "waveform.circle.fill"
        } else {
            symbolName = "waveform"
        }
        
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Keep Mac Audio Alive")?.withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
        }
        
        if engine.isSystemSleeping {
            button.toolTip = "KeepMacAudioAlive: Paused (Mac Sleeping)"
        } else if engine.isAutoRunActive {
            button.toolTip = "KeepMacAudioAlive: Auto Run Active (\(engine.currentSystemOutputName ?? "Active"))"
        } else if engine.isRunning {
            button.toolTip = "KeepMacAudioAlive: Active (\(engine.currentlyActiveDeviceName ?? "Active"))"
        } else if engine.isAutoRunEnabled {
            button.toolTip = "KeepMacAudioAlive: Auto Run Standby (\(engine.currentSystemOutputName ?? "Standby"))"
        } else if !engine.isUniversalEnabled {
            button.toolTip = "KeepMacAudioAlive: Universal Off"
        } else {
            button.toolTip = "KeepMacAudioAlive: Standby"
        }
    }
    
    // MARK: - NSMenuDelegate (Dynamic Dropdown)
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        
        // 1. Status Info Header
        let statusTitle: String
        if engine.isSystemSleeping {
            statusTitle = "Status: Paused (Mac Sleeping)"
        } else if !engine.isUniversalEnabled {
            statusTitle = "Status: Disabled (Universal Off)"
        } else if engine.isAutoRunActive {
            statusTitle = "Status: Active (Auto Run Running)"
        } else if engine.isRunning {
            statusTitle = "Status: Active (Manual)"
        } else {
            statusTitle = "Status: Standby"
        }
        let headerItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        
        let curOutput = engine.currentSystemOutputName ?? "None detected"
        let outputItem = NSMenuItem(title: "System Output: \(curOutput)", action: nil, keyEquivalent: "")
        outputItem.isEnabled = false
        menu.addItem(outputItem)
        
        let autoRunStatusText: String
        if engine.isSystemSleeping {
            autoRunStatusText = "Auto Run: Paused (Mac Sleeping)"
        } else if !engine.isUniversalEnabled {
            autoRunStatusText = "Auto Run: Paused (Universal Off)"
        } else if !engine.isAutoRunEnabled {
            autoRunStatusText = "Auto Run: Off"
        } else if engine.isAutoRunActive {
            autoRunStatusText = "Auto Run: Active (Keeping Output Alive)"
        } else {
            autoRunStatusText = "Auto Run: Standby (Output not selected)"
        }
        let autoRunStatusItem = NSMenuItem(title: autoRunStatusText, action: nil, keyEquivalent: "")
        autoRunStatusItem.isEnabled = false
        menu.addItem(autoRunStatusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Nested Dropdown: Outputs to Keep Alive
        let outputsMenuItem = NSMenuItem(title: "Outputs to Keep Alive", action: nil, keyEquivalent: "")
        let subMenu = NSMenu(title: "Outputs to Keep Alive")
        
        let hintItem = NSMenuItem(title: "Select outputs to keep alive:", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        subMenu.addItem(hintItem)
        subMenu.addItem(NSMenuItem.separator())
        
        // Connected devices
        for device in engine.devices {
            var title = device.name
            if device.uid == engine.currentSystemOutputUID {
                title += " (System Output)"
            }
            let item = NSMenuItem(title: title, action: #selector(toggleDeviceItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = engine.selectedDeviceUIDs.contains(device.uid) ? .on : .off
            subMenu.addItem(item)
        }
        
        // Disconnected remembered devices
        let disconnectedUIDs = engine.selectedDeviceUIDs.filter { uid in
            !engine.devices.contains(where: { $0.uid == uid })
        }
        if !disconnectedUIDs.isEmpty {
            subMenu.addItem(NSMenuItem.separator())
            let discHeader = NSMenuItem(title: "Remembered Disconnected Outputs:", action: nil, keyEquivalent: "")
            discHeader.isEnabled = false
            subMenu.addItem(discHeader)
            
            for uid in disconnectedUIDs.sorted() {
                let name = engine.knownDeviceNames[uid] ?? "Unknown Device"
                let title = "\(name) (Disconnected)"
                let item = NSMenuItem(title: title, action: #selector(toggleDeviceItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = uid
                item.state = .on // Currently remembered
                subMenu.addItem(item)
            }
        }
        
        subMenu.addItem(NSMenuItem.separator())
        let selectAllItem = NSMenuItem(title: "Select All Available", action: #selector(selectAllAction), keyEquivalent: "")
        selectAllItem.target = self
        subMenu.addItem(selectAllItem)
        
        let deselectAllItem = NSMenuItem(title: "Deselect All", action: #selector(deselectAllAction), keyEquivalent: "")
        deselectAllItem.target = self
        subMenu.addItem(deselectAllItem)
        
        outputsMenuItem.submenu = subMenu
        menu.addItem(outputsMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Options following nested dropdown
        // Auto Run Toggle
        let autoRunItem = NSMenuItem(title: "Auto Run (Output Matching)", action: #selector(toggleAutoRunAction), keyEquivalent: "")
        autoRunItem.target = self
        autoRunItem.state = engine.isAutoRunEnabled ? .on : .off
        menu.addItem(autoRunItem)
        
        // Universal On / Off
        let universalItem = NSMenuItem(title: "Universal Keep Alive: \(engine.isUniversalEnabled ? "On" : "Off")", action: #selector(toggleUniversalAction), keyEquivalent: "")
        universalItem.target = self
        universalItem.state = engine.isUniversalEnabled ? .on : .off
        menu.addItem(universalItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Run in Menu Bar Toggle
        let menuBarOnlyItem = NSMenuItem(title: "Run in Menu Bar Only (Hide Dock Icon)", action: #selector(toggleMenuBarOnlyAction), keyEquivalent: "")
        menuBarOnlyItem.target = self
        menuBarOnlyItem.state = engine.runInMenuBarOnly ? .on : .off
        menu.addItem(menuBarOnlyItem)
        
        // Open Window Option
        let openWindowItem = NSMenuItem(title: "Open Window...", action: #selector(openWindowAction), keyEquivalent: "")
        openWindowItem.target = self
        menu.addItem(openWindowItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit App
        let quitItem = NSMenuItem(title: "Quit KeepMacAudioAlive", action: #selector(quitAppAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    // MARK: - Actions
    
    @objc private func toggleDeviceItem(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            engine.toggleDeviceSelection(uid: uid)
        }
    }
    
    @objc private func selectAllAction() {
        engine.selectAllConnectedDevices()
    }
    
    @objc private func deselectAllAction() {
        engine.deselectAllDevices()
    }
    
    @objc private func toggleAutoRunAction() {
        engine.toggleAutoRun()
    }
    
    @objc private func toggleUniversalAction() {
        engine.toggleUniversalEnabled()
    }
    
    @objc private func toggleMenuBarOnlyAction() {
        engine.toggleRunInMenuBarOnly()
    }
    
    @objc private func openWindowAction() {
        WindowManager.shared.showWindow()
    }
    
    @objc private func quitAppAction() {
        NSApp.terminate(nil)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = AudioEngine.shared
        MenuBarController.shared.setupMenuBar()
        WindowManager.shared.setupWindowIfNeeded()
        
        if engine.runInMenuBarOnly {
            NSApp.setActivationPolicy(.accessory)
            WindowManager.shared.hideWindow()
        } else {
            NSApp.setActivationPolicy(.regular)
            WindowManager.shared.showWindow()
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowManager.shared.showWindow()
        }
        return true
    }
}

// MARK: - SwiftUI Views

struct ContentView: View {
    @EnvironmentObject var engine: AudioEngine
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header: Status Icon & Universal Toggle
            HStack(spacing: 12) {
                Image(systemName: headerIconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .foregroundColor(headerIconColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Mac Audio Alive")
                        .font(.headline)
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Toggle("Universal", isOn: Binding(
                    get: { engine.isUniversalEnabled },
                    set: { _ in engine.toggleUniversalEnabled() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.bottom, 2)
            
            Divider()
            
            // Auto Run Card & Indicators
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto Run Mode")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Keep alive current output if it matches selected interfaces")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("Auto Run", isOn: Binding(
                        get: { engine.isAutoRunEnabled },
                        set: { _ in engine.toggleAutoRun() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                
                // Auto Run Status Indicator Banner
                HStack(spacing: 8) {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 9, height: 9)
                    Text(indicatorTitle)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let cur = engine.currentSystemOutputName {
                        Text("Current: \(cur)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            
            // Collapsible Section for Outputs to Keep Alive with Triangle Dropdown
            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        engine.toggleOutputsExpanded()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(engine.isOutputsExpanded ? 90 : 0))
                            .foregroundColor(.secondary)
                        
                        Text("Outputs to Keep Alive")
                            .font(.system(size: 13, weight: .semibold))
                        
                        Text("(\(engine.selectedDeviceUIDs.count) selected)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if engine.isOutputsExpanded {
                            Button("Select All") {
                                engine.selectAllConnectedDevices()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            
                            Text("•")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            
                            Button("Deselect All") {
                                engine.deselectAllDevices()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                if engine.isOutputsExpanded {
                    ScrollView {
                        VStack(spacing: 4) {
                            // Connected devices
                            ForEach(engine.devices) { device in
                                DeviceRowView(
                                    name: device.name,
                                    uid: device.uid,
                                    isConnected: true,
                                    isSystemOutput: device.uid == engine.currentSystemOutputUID,
                                    isActive: engine.isRunning && device.uid == engine.currentlyActiveDeviceUID,
                                    isSelected: engine.selectedDeviceUIDs.contains(device.uid)
                                ) {
                                    engine.toggleDeviceSelection(uid: device.uid)
                                }
                            }
                            
                            // Disconnected remembered devices
                            let disconnectedUIDs = engine.selectedDeviceUIDs.filter { uid in
                                !engine.devices.contains(where: { $0.uid == uid })
                            }.sorted()
                            
                            if !disconnectedUIDs.isEmpty {
                                HStack {
                                    Text("Disconnected (Remembered)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.top, 6)
                                
                                ForEach(disconnectedUIDs, id: \.self) { uid in
                                    DeviceRowView(
                                        name: engine.knownDeviceNames[uid] ?? "Unknown Device",
                                        uid: uid,
                                        isConnected: false,
                                        isSystemOutput: false,
                                        isActive: false,
                                        isSelected: true
                                    ) {
                                        engine.toggleDeviceSelection(uid: uid)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 150, idealHeight: 190, maxHeight: 320)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
            
            // Manual Controls (when Auto Run is disabled)
            if !engine.isAutoRunEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Manual Control")
                        .font(.system(size: 13, weight: .semibold))
                    HStack {
                        Button(action: {
                            if engine.isRunning {
                                engine.manualStop()
                            } else {
                                engine.manualStart()
                            }
                        }) {
                            Text(engine.isRunning ? "Stop" : "Start")
                                .frame(width: 50)
                        }
                        
                        Picker("Device", selection: $engine.manualSelectedDeviceUID) {
                            ForEach(engine.devices) { device in
                                Text(device.name).tag(device.uid as String?)
                            }
                        }
                        .labelsHidden()
                        .disabled(engine.isRunning)
                    }
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Divider()
            
            // App Run Mode: Menu Bar vs Docked
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run in Menu Bar Only")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Runs in the menu bar dropdown and hides from the macOS Dock. You can reopen this window anytime from the menu bar.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("Run in Menu Bar Only", isOn: Binding(
                    get: { engine.runInMenuBarOnly },
                    set: { engine.setRunInMenuBarOnly($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(18)
        .frame(minWidth: 420, maxWidth: 620)
    }
    
    private var headerIconName: String {
        if engine.isSystemSleeping {
            return "moon.zzz.fill"
        } else if engine.isRunning {
            return "waveform.circle.fill"
        } else {
            return "waveform.circle"
        }
    }
    
    private var headerIconColor: Color {
        if engine.isSystemSleeping {
            return .purple
        } else if engine.isRunning {
            return .green
        } else if engine.isUniversalEnabled {
            return .blue
        } else {
            return .secondary
        }
    }
    
    private var headerSubtitle: String {
        if engine.isSystemSleeping {
            return "Paused while Mac is sleeping"
        } else if !engine.isUniversalEnabled {
            return "Universal Keep Alive is Off"
        } else if engine.isRunning {
            return "Actively keeping audio alive"
        } else {
            return "Standby"
        }
    }
    
    private var indicatorColor: Color {
        if engine.isSystemSleeping {
            return .purple
        } else if !engine.isUniversalEnabled {
            return .secondary
        } else if engine.isAutoRunActive {
            return .green
        } else if engine.isAutoRunEnabled {
            return .orange
        } else {
            return .secondary
        }
    }
    
    private var indicatorTitle: String {
        if engine.isSystemSleeping {
            return "Paused (Mac Sleeping)"
        } else if !engine.isUniversalEnabled {
            return "Universal Off"
        } else if engine.isAutoRunActive {
            return "Auto Run Active (Keeping Alive)"
        } else if engine.isAutoRunEnabled {
            return "Auto Run Standby (Waiting for Selected Output)"
        } else {
            return "Auto Run Disabled"
        }
    }
}

struct DeviceRowView: View {
    let name: String
    let uid: String
    let isConnected: Bool
    let isSystemOutput: Bool
    let isActive: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 14))
                
                Text(name)
                    .font(.system(size: 13))
                    .foregroundColor(isConnected ? .primary : .secondary)
                    .lineLimit(1)
                
                Spacer()
                
                if isActive {
                    Text("Active")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }
                
                if isSystemOutput {
                    Text("System Output")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                
                if !isConnected {
                    Text("Disconnected")
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App Entry Point

@main
struct AudioKeepAliveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
