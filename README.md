# AppleLocalizationSwitcher

AppleLocalizationSwitcher is a macOS menu bar utility that makes switching keyboard input sources with the Globe/Fn key reliable.

macOS can sometimes miss the first Globe/Fn press when switching languages, requiring a second or third press. This app listens for a standalone Globe/Fn key press, suppresses the unreliable default handling, and switches directly to the next enabled keyboard input source.

## Install

Download the latest DMG from the GitHub release:

[AppleLocalizationSwitcher 1.1](https://github.com/ForkHorizon/AppleLocalizationSwitcher/releases/tag/v1.1)

DMG SHA-256:

```text
78cbcb565fa632b1c9214ecb2f2f76c796f1c092de54b589fd916b28b2d061bb
```

Open the DMG, drag `AppleLocalizationSwitcher.app` into `Applications`, then launch it.

## Permissions

The app requires macOS Accessibility and Input Monitoring permissions so it can catch the Globe/Fn key globally.

On first run, open the menu bar item and choose `Open Accessibility Settings`, then enable AppleLocalizationSwitcher in:

`System Settings` -> `Privacy & Security` -> `Accessibility`

Then choose `Open Input Monitoring Settings` and enable AppleLocalizationSwitcher in:

`System Settings` -> `Privacy & Security` -> `Input Monitoring`

## Usage

- The app runs only in the menu bar.
- Press Globe/Fn once to switch to the next enabled keyboard input source.
- Use `Switch Now` from the menu to switch manually.
- Use `Enable Fn Switcher` to turn the key handling on or off.
- Use `Launch at Login` to start the utility automatically after login.
- Use `Copy Diagnostics` if Globe/Fn does not behave reliably; it copies monitor and permission state.
- If fewer than two selectable keyboard input sources are enabled, the app shows a disabled status and lets Globe/Fn pass through.

## Build

Build from source with Xcode or:

```sh
xcodebuild -project AppleLocalizationSwitcher.xcodeproj -scheme AppleLocalizationSwitcher -configuration Release build
```

The app is intended as a local macOS utility and is not sandboxed, because global keyboard event handling requires system-level permission.
