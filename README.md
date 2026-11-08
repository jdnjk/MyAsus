# MyASUS

A macOS menu-bar companion for compatible AsusSMC drivers. The UI uses a generic **ASUS notebook** identity and does not include a fixed laptop model identifier.

The app can show locally read sensor, fan, battery, power, and driver status information. It does not upload device telemetry. Hardware controls are capability-gated and require the compatible AsusSMC ABI 5 driver; unsupported functions remain unavailable. Building this app does not validate hardware compatibility.

## Build and test

Requires macOS 13 or later with Xcode Command Line Tools / Swift. Build locally without installing or changing system configuration:

```sh
bash build.sh test
bash build.sh
```

Outputs are placed in `build/`: `MyASUS.app`, a drag-install DMG, and `SHA256SUMS.txt`. The app is ad-hoc signed and neither the app nor the DMG is notarized. Settings are stored in `~/Library/Application Support/ASUSControl/config.json` and survive bundle-identifier changes. If replacing an older installation, quit the old app first and update the login item from the new app.

Alternatively, open `MyASUS.xcodeproj` in Xcode, select the **MyASUS** scheme, and press Run (⌘R). The target uses the same `Info.plist` and is signed to run locally, so no Apple developer team is required.

GitHub Actions runs the hardware-free policy tests and builds the app and DMG on pushes, pull requests, and manual runs. Download them from the workflow run's **Artifacts** section. This workflow does not create a GitHub Release or install the app.

## Privacy and scope

Only this application, its tests, build script, and CI workflow are included in this repository. Personal EFI/OpenCore configuration, ACPI dumps, system reports, SDKs, and local build outputs are not included. Runtime hardware readings stay on the local machine.

## Credits and license

The application source files retain their SPDX license and copyright headers. The app is inspired by asusctl / rog-control-center; no code is taken from that project.
