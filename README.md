# Elsewhere Mobile

**English** | [简体中文](README.zh-CN.md)

Elsewhere Mobile is a native location tool for iPhone and iPad. Set a simulated location on this device or another paired device on the same LAN. Choose your proxy exit, a favorite city, or a point on the map. Tap **Use Real Location** to clear it. You need a computer for initial pairing. After that, you can work from the mobile app.

## Features

- **Follow your proxy exit.** Look up the exit IP over the host’s network or a specified HTTP proxy and use its estimated location. Choose an alert or an automatic move when the exit changes. Auto-follow applies only to devices last set to follow the exit, preserving manually chosen cities and pins. The system schedules background checks.
- **Pick a point on the map.** Drop a pin on the full-size map, enter coordinates, or search Apple Maps and OpenStreetMap for a place. A mainland China polygon determines where to convert between GCJ-02 map coordinates and WGS-84 device coordinates. Seoul now keeps its original coordinates, and central Shenzhen gets the conversion it needs. Hong Kong, Macao, Taiwan, and overseas locations keep their original coordinates.
- **Favorites and multiple devices.** Start with 11 cities. Add, delete, or drag to reorder them. Each device has its own pairing record and last-set location. Select one device, or enable the option to change all ready devices together.
- **Restore on reconnect and check the time zone.** Restarting the target clears its simulated location. With restore on reconnect enabled, the app can reapply the last location when it detects the device is ready again. “Last set” shows a recorded operation. The app also compares the device’s time zone offset with the location’s and suggests how to adjust it.
- **Shortcuts and widgets.** Four App Intents let you follow the exit, move to a favorite city, set coordinates, or restore the real location. The medium interactive widget offers follow and restore buttons. Both actions are also available in Control Center on iOS / iPadOS 18+.
- **Demo and languages.** Open Demo from setup or Settings to try a simulated device and sample exit. Place lookups and some messages support English and Simplified Chinese. Parts of the current interface are available only in Chinese.

## How it works and system requirements

| Device role | System version | Capability |
| --- | --- | --- |
| Host running the app | iOS / iPadOS 17.0+ | Install the app, manage pairings, or run Demo. To change its own location, the host must also meet the target requirements. |
| Target receiving a location | iOS / iPadOS 17.4+ | Implements Lockdown → CoreDeviceProxy → RSD → `com.apple.coredevice.locationservice`. Enable Developer Mode on the target. |
| Target receiving a location | iOS / iPadOS 17.0–17.3 | Requires a separate RemotePairing protocol path. Currently unsupported. |

The app links the Rust static library `ElsewhereCore.xcframework`. The `TcpProvider` from `idevice 0.1.68` connects to Lockdown on the target. The app then discovers the location service through a CoreDevice software tunnel and sends a set or clear request. The first set may require a developer disk image (DDI). The table describes protocol availability. Individual hardware, OS, and image combinations still need verification on a physical device. [Architecture notes](ARCHITECTURE.md)

## First-time pairing and setup

1. Connect the target to a computer over USB, unlock it, and tap **Trust**. On that trusted computer, open `idevice_pair`, select the target, and export its **Lockdown** pairing record. Save the `.mobiledevicepairing` or `.plist` file in Files on the host. RemotePairing uses an incompatible credential format, even if you rename the file. [idevice_pair](https://github.com/jkcoxson/idevice_pair)
2. On the target, open **Settings › Privacy & Security › Developer Mode**, enable it, restart when prompted, then unlock and confirm.
3. In the setup wizard, enter the target IP and pick the pairing file from Files. You can also select Elsewhere in the Files share sheet, then open the main app to finish importing. Review or edit the address under **Settings › Devices and Pairing**.
4. Choose a channel below, allow local network access on the host, and tap **Test Connection**. Once it succeeds, set a recognizable location and check it in Maps **on the target**. Tap **Use Real Location** to verify that clearing works too.

Pairing files contain private keys. The app encrypts each imported record at rest with a separate AES-256-GCM key. It stores the ciphertext in its private directory and the key in a `WhenUnlockedThisDeviceOnly` Keychain item. Keep the original export private and leave it out of issue reports.

## Connection channels and proxy apps

**Option A · Existing route (recommended default).** Select the existing route in setup. For the host itself, enter the peer address of a configured LocalDevVPN, StosVPN, or WireGuard loopback (the default example is `10.7.0.1`). For another device, enable wireless pairing and enter its LAN IP on the same Wi-Fi network. Leave your usual proxy running during the connection test.

Elsewhere uses no VPN slot of its own in this mode. If the target is directly reachable over the LAN, or your existing Surge, Shadowrocket, Loon, or Clash configuration routes traffic to it, you can keep that proxy connected. Starting a separate loopback VPN can still take the same slot. The route must reach Lockdown on TCP port 62078 and the service ports negotiated afterward. Confirm it by setting and clearing a location on the target.

**Option B · Built-in loopback (optional).** To reach the host itself without an existing route, select the built-in channel and approve the system VPN configuration in the foreground on first use. Its `NEPacketTunnelProvider` routes only the virtual peer (IPv4 `/32` or IPv6 `/128`). It still occupies the system VPN slot while connected.

To follow a proxy exit, connect the proxy first. Elsewhere looks up the exit before starting its built-in channel. Turn on **Disconnect automatically after operations** to stop the channel Elsewhere started and release the slot when the operation finishes. The third-party proxy can reconnect under its own on-demand rules, or you can reconnect it manually.

## Build from source and sideload

Use a Mac with Xcode 16+ and an iOS Simulator runtime. The script builds arm64 slices for physical devices and Apple Silicon simulators. Install the tools, then run these commands from the repository root. If the example simulator is unavailable, change `name` to an installed model.

```sh
brew install rustup xcodegen cbindgen
export PATH="$(brew --prefix rustup)/bin:$PATH"
rustup toolchain install 1.94.0 --profile minimal
rustup target add --toolchain 1.94.0 aarch64-apple-ios aarch64-apple-ios-sim

cargo +1.94.0 test --locked --manifest-path elsewhere-core/Cargo.toml
scripts/build-rust-ios.sh --all
xcodegen generate
xcodebuild -project ElsewhereMobile.xcodeproj -scheme ElsewhereMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' build test
```

To sideload, open the generated project in Xcode. Select your team, available bundle IDs, and matching provisioning profiles for the host and extensions. Choose the device and run. If you change identifiers, update the tunnel bundle ID and App Group IDs referenced in the source as well.

- **With the built-in channel.** Both the host and `ElsewhereTunnel` need `com.apple.developer.networking.networkextension` with the value `packet-tunnel-provider`. App Groups serve the other two extensions. The host shares `group.com.elsewhere.mobile.snapshot` with the widget and `group.com.elsewhere.mobile.import` with the share extension.
- **Option A only.** If a free Personal Team profile lacks Network Extension access, remove the `ElsewhereTunnel` target and its embedded dependency from the host in your own `project.yml`. Remove the Network Extension entitlement from the host and regenerate the project. Keeping the widget or share extension still requires signing access to its App Group. Select the existing route after installation. [Apple’s account capability table](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)

## Troubleshooting

- **Locked device, invalid pairing, or Developer Mode off?** Unlock the host and target, then retry. For an invalid pairing, trust the computer again on the target, export a fresh record for that device, and import it. If Developer Mode is off, check that you unlocked and confirmed it after the restart.
- **DDI download, signing, or mount failed?** For download or verification errors, check that the host can reach the image mirror, then retry. The app verifies the image’s SHA-384 against its manifest. For personalization errors, check access to Apple TSS. For upload or mount errors, keep the target unlocked, check the channel, and read the raw output to identify the failing stage. [DDI mirror](https://github.com/doronz88/DeveloperDiskImage)
- **A Wi-Fi-only iPad still shows the old location?** After clearing simulation, an iPad without GPS needs nearby Wi-Fi to obtain a new fix. Give it time. If it stays stale, toggle **Settings › Privacy & Security › Location Services** off and on.
- **The time zone differs from the location?** Check **Settings › General › Date & Time** on the target. On Wi-Fi-only devices, enable **Set Automatically**. Cellular devices may use the carrier’s time zone. To match the simulated location, turn off automatic time and choose a city in the target zone.
- **Where is the raw error?** Expand **原始输出** (Raw Output) in the failure message and tap **拷贝** (Copy). Include the failing stage, host and target OS versions, and channel when reporting a problem. Redact private keys and device identifiers before sharing.

## Project layout

```text
.
├── App/                    App entry point, state, and lifecycle
├── Features/               Location, map, favorites, settings, and setup
├── DesignSystem/           Shared UI components and wordmark
├── Domain/                 Coordinates, cities, device state, and exit rules
├── Engine/                 Swift/Rust bridge, device and Demo engines
├── Services/               Pairing, channels, DDI, search, coordinates, and time zones
├── Intents/                Shortcuts actions
├── Widgets/                Widget and Control Center controls
├── TunnelExtension/        Built-in loopback channel
├── PairingImportExtension/ Share sheet import
├── elsewhere-core/         Rust static library, C interface, and Rust tests
├── scripts/build-rust-ios.sh
├── project.yml             XcodeGen project and test scheme
├── Tests/                  Swift XCTest
└── Licenses/               Wordmark license
```

## Data sources and licenses

- The project code uses the MIT License. The ELSEWHERE wordmark uses glyphs from Jost Light under the SIL Open Font License 1.1. [MIT License](LICENSE) · [Jost license](Licenses/Jost-OFL.txt)
- Place searches combine Apple Maps and OpenStreetMap (Photon for suggestions, Nominatim for submitted searches). Selected coastlines and island outlines also come from © OpenStreetMap contributors. The derived vertices are available under ODbL 1.0. [OpenStreetMap copyright and license](https://www.openstreetmap.org/copyright)
- The Shenzhen–Hong Kong boundary comes from the Hong Kong SAR Government Home Affairs Department’s open dataset *District boundary*. The mainland outline comes from Natural Earth v5.1.2 Admin 0 Map Units, in the public domain. The simplified polygons are used only to select the coordinate conversion region. [Hong Kong open data](https://data.gov.hk/en-data/dataset/hk-had-json1-hong-kong-administrative-boundaries) · [Government data terms](https://data.gov.hk/en/terms-and-conditions) · [Natural Earth](https://www.naturalearthdata.com/)

**Disclaimer.** Use this tool on devices you are authorized to manage and follow local law and applicable app terms. Simulated locations can affect Find My, Weather, and ride-hailing services. Restore the real location when you finish.
