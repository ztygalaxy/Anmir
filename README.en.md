# Anmir

[简体中文](README.md) · [English](README.en.md)

Mirror Android devices to your Mac and control them with your keyboard and mouse. Built on [scrcpy](https://github.com/Genymobile/scrcpy), Anmir provides a native macOS interface, device management and wireless pairing. adb is included; no separate Homebrew or Android SDK installation is needed.

> /ˈæn.mɪr/ (AN-mir) · An(droid) + mir(ror)

## Highlights

- **USB and wireless:** automatic device discovery, QR codes, pairing codes and manual addresses. USB and wireless connections for the same device are grouped together.
- **Multiple devices:** each mirror has its own window and Dock entry, with easy access to the device list.
- **Screenshots and recording:** copy device screenshots to your Mac's clipboard, see screen recording duration and choose where to save files.
- **Native macOS interface:** floating controls for Back, Home, Recents, screenshots and recording. The app supports light, dark and system appearance.
- **Live language switching:** English, Simplified Chinese and Traditional Chinese. Settings are saved and shared across mirror windows.
- **Local connections:** mirroring requires no account or cloud relay. ADB connections remain available for debugging and logs.

## Download

[Latest release](https://github.com/laobie/Anmir/releases/latest) · macOS 11+ · Apple Silicon / Intel

Device requirements: Android 5.0+ for USB mirroring; Android 11+ for wireless pairing.

## Screenshots

<img src="doc/images/en/devices.png" alt="Anmir device manager in English" width="760" />

<details>
<summary>Wireless connections and settings</summary>

<img src="doc/images/en/wireless.png" alt="Anmir wireless connection in English" width="500" />

<img src="doc/images/en/settings.png" alt="Anmir settings in English" width="620" />

</details>

## Quick start

1. Open the DMG, drag Anmir into Applications and open it.
2. Enable **Developer options → USB debugging** on your Android device.
3. Connect the device to your Mac with a USB data cable and allow USB debugging on the device. A single ready device opens directly; with multiple devices, choose one from the list.

**Wireless:** connect your Android device and Mac to the same network, then enable **Developer options → Wireless debugging** on the Android device. Click the Wi-Fi add button in Anmir and use the device's **Pair device with QR code** scanner, or switch to a pairing code. Already paired devices can connect manually using an IP address and connection port.

**Everyday controls:** use the floating toolbar to control the Android device, capture screenshots or record its screen. Open Anmir Settings with the gear in either the device list or a mirror window, or press `⌘,`.

If macOS blocks Anmir's first launch, double-click the **Privacy & Security** shortcut in the DMG window or extracted ZIP folder, then choose **Open Anyway** for Anmir. The app is not notarized; see [Apple's instructions](https://support.apple.com/102445).

## Command line

The bundled `anmir` command accepts scrcpy options:

```sh
/Applications/Anmir.app/Contents/MacOS/anmir --help
/Applications/Anmir.app/Contents/MacOS/anmir --serial DEVICE_SERIAL
```

## Documentation and feedback

[Building and LGPL relinking](doc/build-anmir.md) · [Shortcuts](doc/shortcuts.md) · [Connections](doc/connection.md) · [Audio](doc/audio.md) · [macOS architecture](doc/macos-architecture.md)

Report issues in [Issues](https://github.com/laobie/Anmir/issues), including the Anmir version, Mac processor, macOS and Android versions, and connection method.

## Release history

| Version | Date | Changes | Release |
| --- | --- | --- | --- |
| v0.1.0 | 2026-10-25 | Initial release: native device management, USB/wireless mirroring, screenshots, recording and localization. | [Release](https://github.com/laobie/Anmir/releases/tag/v0.1.0) |

## License

Independently maintained, based on upstream scrcpy v4.1. Not an official Genymobile project.

Licensed under [Apache 2.0](LICENSE), with [upstream attribution](NOTICE) preserved. Dependency licenses are listed in [THIRD_PARTY.md](THIRD_PARTY.md).

Android is a trademark of Google LLC.
