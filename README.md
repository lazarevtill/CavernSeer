<img src="/docs/icons/icon-167.png" align="right">

# CavernSeer
> An iPadOS and iOS application for scanning 3D spaces

CavernSeer uses ARKit and RealityKit scene reconstruction to record a local triangle mesh on LiDAR-equipped iPhones and iPads. It works with individual scan segments. It is not a safety tool, a georeferenced survey, or a substitute for validating scale and drift.

## Reliable local LiDAR capture

This version saves captured LiDAR geometry directly into the existing
`.cavernseerscan` format, without requiring ARKit to build a relocalizable
world map. The viewer uses bounds from the captured mesh. When there is no
usable mesh or writing fails, the capture stays open so you can try again.
- **Recovery:** while a usable mesh is present, the scanner writes a local
  checkpoint soon after capture begins and at roughly 25–30 second intervals
  when the mesh changes. It also attempts a checkpoint on backgrounding,
  interruption, and stopping. The scanner shows when a write has completed.
  Open the **Scan List** to find a separate **Recovery** entry. It is a partial
  scan, not a tracking session you can resume. A final save does not delete it. If spatial tracking loses previously recorded mesh, keep the earlier recovery and record the available geometry separately.
- **Keep two copies:** on the scan detail page choose **Export scan → Backup
  ZIP (original + mesh)**. Keep the original native archive for reopening in
  CavernSeer and the OBJ for Blender or other mesh tools. Copy the ZIP to
  another device before deleting any app data. See
  [backup and verification workflow](docs/portable-scan-backups.md).
- A checkpoint is not protection against loss of the phone, uninstalling the
  app, running out of disk space, or termination before the next completed
  write. After a hard interruption, expect at most the last successful local
  checkpoint, not the last frame. An interrupted coordinate frame is not
  resumed into the same scan.

**Physical iPhone check:** sign and run `CavernSeer.xcodeproj` via Xcode on a
LiDAR iPhone. Use Airplane Mode with Wi-Fi off and scan a well-lit room.
Wait for **Recovery copy saved**, close the app from the app switcher, reopen
and confirm that the Recovery entry renders. Take a second scan, save it
normally, then export the ZIP to Files and copy it to a Mac. Verify it with
`unzip -t`; reopen the native scan and open the OBJ in Blender, then compare
one dimension with a tape measure. The simulator cannot validate LiDAR
capture. Do not use a phone scan as your only means of navigation.

### App Usage ###

Devices on iOS/iPadOS 15 or later can run the app and view existing scans shared by others, but devices with a LiDAR scanner (currently iPhone 12 Pros and newer iPad Pros) can capture new scans.

### Viewing ###

Scans created by the user or imported from elsewhere will appear in the "Scan List" tab, which lists out the names and the starting photo of the scan.

Selecting a scan displays the start and end photos (if available), *export* options for the scan file as well as a plaintext .OBJ render, as well as the following:
 * Advanced - underlying information about the scan.
 * 3D Render - a 3D perspective rendering view navigable based on the setting "3D render interaction mode".
 * Plan Projected Render - a "top-down" orthographic projection complete with scale bar. Defaults to local scan orientation; do not interpret it as north. The height control allows for raising or lowering the camera to show or hide obstructions.
 * Elevation Projected Render - a "side-view" orthographic projection with scale bar, compass, and various controls. The angle controls change the direction the camera is facing relative to the local scan axes. The depth control is similar to the plan-projected height control, allowing for pushing the camera through obstructions.
 * Cross Section Render - an elevation projection (see above) with an inset plan-projection indicating the position and size of the camera, and adjustable cross-section depth.

All of the renders support high-resolution screenshots scaled to higher detail than the device itself.

### Scanning ###

Devices with a LiDAR scanner can capture new scans in the "Scanner" tab.

Pressing the center button starts a scan, after which you can enable Apple's debugging overlays, either showing _Debug_ information or a _Mesh_ preview which displays the currently captured mesh on screen, as well as enabling the device's flashlight.

Clicking the center button again will complete and save the scan, which will appear in the scan list.

### Settings ###

 * Three settings for mesh color change the way that the meshes in the various viewers are displayed.
 * Switch for changing between meters and decimal-feet in any distance contexts.
 * Setting for changing the interaction mode in the 3d Render view. The recommended option is "Orbit angle mapping".
 * Debugging options where appropriate.


## Install and test

The app targets **iOS 15 or later** and was built with **Xcode 26.3**.
No external dependencies are required, so you should be able to clone the repo into Xcode and build to your device.

Select your own signing team to install on iPhone. The project uses `io.github.lazarevtill.CavernSeer` as its distinct bundle identifier. Open the exact signed build online first and check its provisioning expiry before relying on it offline. For the field rehearsal, relaunch from the Home Screen with Xcode's debugger detached and test lock, backgrounding, and force quit separately. See [device acceptance](docs/device-acceptance.md).

The Simulator supports testing native scan fixtures, rendering, backup export, and scan list operations. It cannot generate or validate LiDAR captures. Run the isolated simulator workflow with `scripts/simulator-smoke.sh SIMULATOR_UDID`. This smoke test uses a separate app identifier and disposable scans, not the main app’s storage.

## _More to come!_
