# KeepMacAudioAlive
Keep Mac audio alive to prevent delays, clicks, or pops with external DACs, headphones, and audio interfaces.

## Features

- **Menu Bar App & Docked Mode**: Run entirely in the macOS menu bar (without showing in the Dock) or toggle on the normal docked window interface.
- **Dynamic Dropdown Menu**: Access all controls right from the system menu bar:
  - **Outputs to Keep Alive (Nested Submenu)**: Multi-select audio interfaces with checkmarks.
  - **Auto Run**: Automatically monitors system audio output and keeps audio alive whenever macOS switches to any of your selected interfaces.
  - **Auto Run Status Indicator**: Visual real-time indicator showing when Auto Run is active, standby, paused, or off.
  - **Universal On / Off**: Master switch to enable or pause all keep-alive audio streaming.
  - **Run in Menu Bar Only Toggle**: Seamlessly switch between menu-bar-only (dockless) and standard docked window mode.
  - **Quit App**: Cleanly exit at any time.
- **Multi-Select Auto Run**: Select multiple audio interfaces. When macOS switches its active output to any selected device, KeepMacAudioAlive immediately streams silence to that interface to keep its DAC clock and hardware awake.
- **Remember Disconnected Interfaces**: Disconnected interfaces remain saved in your selection list. When reconnected, if macOS switches back to them as the audio output, KeepMacAudioAlive automatically resumes keeping them alive without requiring manual reconfiguration.
- **Sleep & Power Friendly**:
  - **Allows System Idle Sleep**: Sets CoreAudio's `kAudioHardwarePropertySleepingIsAllowed` so that streaming silence does not prevent your Mac or displays from naturally entering idle sleep.
  - **Auto-Pause on Sleep**: Automatically pauses and destroys active IOProcs when macOS enters sleep (`NSWorkspace.willSleepNotification`), allowing DACs and system hardware to power down cleanly.
  - **Auto-Resume on Wake**: Seamlessly restores keep-alive streaming when your Mac wakes up (`NSWorkspace.didWakeNotification`), including retry polling for external USB DACs or Bluetooth devices that take a second to re-enumerate.
- **Zero Audio Overhead**: Streams pure silence (`0s`) directly through CoreAudio IOProc without audible noise or CPU penalty.

---

## How to Use

### 1. Menu Bar Mode (Default or via Toggle)
Click the KeepMacAudioAlive icon in the menu bar:
- Hover over **Outputs to Keep Alive** to check or uncheck which audio interfaces to keep alive.
- Check **Auto Run** so KeepMacAudioAlive automatically activates whenever macOS uses any of your checked interfaces.
- Use **Universal Keep Alive: On / Off** as a global pause/play toggle.
- Toggle **Run in Menu Bar Only (Hide Dock Icon)** to switch between running purely in the menu bar or displaying the app in the macOS Dock with its control window.
- Click **Open Window...** to view the full control panel at any time.

### 2. Docked Control Window
When running in docked mode (or opened from the menu bar), the control window provides:
- Real-time status indicators (Active, Standby, Paused during Sleep, Universal Off).
- Auto Run toggle and live status badge displaying the current macOS output.
- Full multi-select list of connected and remembered disconnected audio interfaces.
- "Select All" and "Deselect All" quick buttons.
- Manual control mode (when Auto Run is disabled).
- "Run in Menu Bar Only" toggle to hide the app into the menu bar.

---

## How to Build

1. Clone this repository:
   ```bash
   git clone https://github.com/openmac/KeepMacAudioAlive.git
   cd KeepMacAudioAlive
   ```
2. Build app bundle via command line:
   ```bash
   ./build.sh && open KeepMacAudioAlive.app
   ```
3. Or build via Xcode:
   - Open `KeepMacAudioAlive.xcodeproj` in Xcode.
   - Select your development team in Signing & Capabilities if desired.
   - Build and run (Cmd+R).

---

## Credits
Based on the original KeepMacAudioAlive project by openmac.
