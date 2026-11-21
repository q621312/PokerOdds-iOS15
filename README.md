# PokerOdds — iOS 15+ / TrollStore build

SwiftUI Texas Hold'em flop equity calculator. Minimum deployment target: iOS 15.0.

## Build a TrollStore IPA without owning a Mac
1. Create a **public** GitHub repository (public standard GitHub-hosted macOS runners are free for this workflow).
2. Upload the contents of this folder to the repository root (including `.github/workflows`).
3. Open the repository's **Actions** tab → **Build TrollStore IPA** → **Run workflow**.
4. Wait for the workflow to finish successfully, open the completed run, and download the artifact named `PokerOdds-iOS15-unsigned-IPA`.
5. Extract the artifact ZIP to find `PokerOdds-unsigned.ipa`.
6. Transfer the IPA to the iPhone, open TrollStore → Apps → `+` → Install IPA File, and select it.

The workflow creates an unsigned device IPA (no Apple Developer account or provisioning profile). TrollStore is intended to install unsigned IPAs. The workflow has not yet been run, so the build must be confirmed successful in Actions before installation.

