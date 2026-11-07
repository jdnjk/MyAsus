# MyAsus Control

A macOS menu-bar companion for compatible AsusSMC drivers. The UI uses a generic **ASUS notebook** identity and does not include a fixed laptop model identifier.

The app can show locally read sensor, fan, battery, power, and driver status information. It does not upload device telemetry. Hardware controls are capability-gated and require the compatible AsusSMC ABI 5 driver; unsupported functions remain unavailable. Building this app does not validate hardware compatibility.

## Build and test

Requires macOS 13 or later with Xcode Command Line Tools / Swift. Build locally without installing or changing system configuration:

```sh
bash build.sh test
bash build.sh
```

Outputs are placed in `build/`: `RogControl.app`, a drag-install DMG, and `SHA256SUMS.txt`. The app and DMG are ad-hoc signed and are not notarized.

GitHub Actions runs the hardware-free policy tests and builds the app and DMG on pushes, pull requests, and manual runs. Download them from the workflow run's **Artifacts** section. This workflow does not create a GitHub Release or install the app.

## Privacy and scope

Only this application, its tests, build script, and CI workflow are included in this repository. Personal EFI/OpenCore configuration, ACPI dumps, system reports, SDKs, and local build outputs are not included. Runtime hardware readings stay on the local machine.

## Credits and license

The application source files retain their SPDX license and copyright headers. The app is inspired by asusctl / rog-control-center; no code is taken from that project.
