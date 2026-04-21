# RimeoAgent — Build & Distribution

## Prerequisites

```bash
pip install flet>=0.21.0
```

macOS `.pkg` requires Xcode Command Line Tools (`xcode-select --install`).

---

## Building

### macOS → `.app` + `.pkg` + `_mac.zip`

```bash
cd /path/to/Rimeo          # parent directory of RimeoAgent/
bash RimeoAgent/build/build_mac.sh
```

Outputs in `dist/`:
| File | Purpose |
|------|---------|
| `RimeoAgent.app` | Run directly / drag to Applications |
| `RimeoAgent.pkg` | One-click installer |
| `RimeoAgent_mac.zip` | Upload to GitHub Release as asset |

### Windows → `.exe` + `_win.zip`

```bat
cd C:\path\to\Rimeo
RimeoAgent\build\build_win.bat
```

Outputs in `dist/`:
| File | Purpose |
|------|---------|
| `RimeoAgent.exe` | Run directly |
| `RimeoAgent_win.zip` | Upload to GitHub Release as asset |

---

## Releasing (auto-update flow)

1. Bump `VERSION` in `RimeoAgent/config.py` (e.g. `"v2.1.0"`).
2. Build on macOS → get `RimeoAgent_mac.zip`.
3. Build on Windows → get `RimeoAgent_win.zip`.
4. Create a GitHub Release tagged `v2.1.0`.
5. Upload both `.zip` files as release assets with **exact names**:
   - `RimeoAgent_mac.zip`
   - `RimeoAgent_win.zip`
6. Publish the release.

Running agents will pick up the update within 24 hours and show an in-app banner.

---

## Auto-update config

Set `GITHUB_REPO` in `RimeoAgent/updater.py`:

```python
GITHUB_REPO = "your-org/rimeo"   # ← change this
```

---

## Bundle size notes

- Build scripts install **CPU-only torch** (~200 MB) instead of the default GPU build (~2 GB).
- The CLAP model (~900 MB) lives in `~/.cache/huggingface/` and is **not bundled** — it is downloaded on first analysis.
- Total expected bundle: ~600–900 MB.
