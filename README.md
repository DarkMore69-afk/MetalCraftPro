# MetalCraft Pro

iOS app for metal construction workflows, including CAD drawing, 3D assembly visualization, material/cut-list calculations, welding documentation, and project export.

## Project

- Xcode project: `MetalCraftPro.xcodeproj`
- Main app source: `MetalCraftPro/`
- Unit tests: `MetalCraftProTests/`
- UI tests: `MetalCraftProUITests/`
- CI workflow: `.github/workflows/build-ipa.yml`

## Build

Open `MetalCraftPro.xcodeproj` in Xcode, select the `MetalCraftPro` scheme, choose an iOS Simulator or a connected device, then build. A signed device build requires a valid Apple Development team and provisioning configuration.

The GitHub Actions workflow attempts an unsigned archive and packages the compiled app as an unsigned IPA; an unsigned IPA is not directly installable on a normal iPhone without an appropriate signing/sideloading process.

## Repository hygiene

Generated IPA files, local Xcode user state, Git history bundled inside the source archive, and Milq project conversation metadata are intentionally excluded. Do not commit certificates, provisioning profiles, API keys, or other secrets.

## Validation status

This source package has been prepared for repository upload. A successful Xcode build and XCTest run must be confirmed by macOS/Xcode CI before treating it as build-verified.

