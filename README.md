# FnSwitcher

FnSwitcher is a macOS menu bar utility that makes switching keyboard input sources with the Globe/Fn key reliable.

macOS can sometimes miss the first Globe/Fn press when switching languages, requiring a second or third press. This app listens for a standalone Globe/Fn key press, suppresses the unreliable default handling, and switches directly to the next enabled keyboard input source.

## Install

Download the latest DMG from the GitHub release:

[FnSwitcher 1.5](https://github.com/ForkHorizon/AppleLocalizationSwitcher/releases/tag/v1.5)

DMG SHA-256:

```text
1e0fae4daaa9e339fd4bda0892a65ca988bcdbe40510bcf03dc61fa345e32f0f
```

Open the DMG, drag `FnSwitcher.app` into `Applications`, then launch it.

## Permissions

The app requires macOS Accessibility and Input Monitoring permissions so it can catch the Globe/Fn key globally. When the Fn switcher is enabled, the app requests missing permissions on launch.

On first run, use `Request Keyboard Permissions` from the menu bar item if macOS does not show the prompts automatically. Then enable FnSwitcher in:

`System Settings` -> `Privacy & Security` -> `Accessibility`

and:

`System Settings` -> `Privacy & Security` -> `Input Monitoring`

## Usage

- The app runs only in the menu bar.
- Reopening the app while it is already running exits the duplicate instance and keeps a single menu bar item.
- Press Globe/Fn once to switch to the next enabled keyboard input source.
- The selected language is shown in a centered macOS-style glass HUD after manual switches.
- Use `Request Keyboard Permissions` if the menu shows `Keyboard permissions required`.
- Use `Switch Now` from the menu to switch manually.
- Use `Enable Fn Switcher` to turn the key handling on or off.
- Use `Settings` to enable language layout persistence globally and per application.
- Use `Launch at Login` to start the utility automatically after login.
- Use `Copy Diagnostics` if Globe/Fn does not behave reliably; it copies monitor and permission state.
- If fewer than two selectable keyboard input sources are enabled, the app shows a disabled status and lets Globe/Fn pass through.

## Build

Build from source with Xcode or:

```sh
xcodebuild -project AppleLocalizationSwitcher.xcodeproj -scheme AppleLocalizationSwitcher -configuration Release build
```

The app is intended as a local macOS utility and is not sandboxed, because global keyboard event handling requires system-level permission.
