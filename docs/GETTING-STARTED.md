<!-- generated-by: gsd-doc-writer -->
# Getting Started with NOOP

NOOP is a free, offline-first companion app for WHOOP 4.0 and 5.0 straps. It reads your biometric data directly from the strap over Bluetooth, stores everything locally on your device, and never sends anything to a server or cloud.

This guide is for **users who want to install and use the app**. If you want to build NOOP from source, see [BUILD.md](BUILD.md).

---

## Prerequisites

Before you start, make sure you have:

- A **WHOOP 4.0 or 5.0 / MG strap** (the strap you already own — no WHOOP account required)
- **Bluetooth** enabled on your Mac or Android device
- **macOS 13 (Ventura) or newer** — for the macOS app
- **Android 8.0 (API 26) or newer** — for the Android app

No WHOOP account, no internet connection, and no subscription are required to use NOOP.

---

## Installing on macOS

### 1. Download the app

Go to the [Releases page](../../releases) and download `NOOP.app` (a `.zip` containing the macOS app). Extract it and drag `NOOP.app` to your **Applications** folder.

### 2. Get past Gatekeeper (first launch only)

NOOP is **not notarized** by Apple — notarization requires a paid Apple Developer ID tied to a real identity, which doesn't fit an anonymous, free project. The app is sandboxed and ad-hoc code-signed, and the full source is here to inspect.

Because it is not notarized, macOS Gatekeeper blocks it on the first open. You may see a message saying the app is "damaged" or from an "unverified developer" — that is the quarantine flag macOS applies to downloaded apps, not actual damage.

To open NOOP for the first time, do **one** of the following:

**Option A — Terminal (most reliable):**

```bash
xattr -dr com.apple.quarantine /Applications/NOOP.app
```

After running that command, open NOOP normally from Applications.

**Option B — System Settings (no Terminal):**

1. Double-click NOOP. macOS will block it.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the bottom and click **"Open Anyway"** next to NOOP.
4. Confirm when prompted.

After you accept it once, NOOP opens normally from then on.

### 3. Grant Bluetooth permission

On the first launch, macOS will ask for Bluetooth access. Grant it — NOOP needs Bluetooth to talk to your strap. The permission prompt explains that data stays on-device.

---

## Installing on Android

### 1. Download the APK

Go to the [Releases page](../../releases) and download one of:

- **`NOOP-full.apk`** — the full app, starts empty; pair a strap or import existing data.
- **`NOOP-demo.apk`** — preloaded with 120 days of sample data so you can explore every screen without a strap. Installs alongside the full app.

### 2. Enable installation from unknown sources

Android blocks apps installed outside the Play Store by default. To sideload NOOP:

1. Open your device **Settings**.
2. Search for **"Install unknown apps"** (the exact path varies by manufacturer — it is often under **Apps**, **Special app access**, or **Security**).
3. Find your browser or file manager and toggle **"Allow from this source"**.

### 3. Install the APK

Open the downloaded `.apk` file and tap **Install**. You can re-disable "unknown sources" afterwards if you prefer.

### 4. Grant Bluetooth permissions

On first launch, Android will request Bluetooth and (on Android 12+) nearby devices permissions. Grant them — NOOP needs Bluetooth to connect to your strap.

---

## First launch — pairing with your WHOOP strap

### WHOOP 4.0

1. Open NOOP and go to **Live**.
2. Make sure the strap is **charged and on your wrist** (it needs a non-zero heart rate to respond).
3. Tap **Scan & Connect**. NOOP will find and pair with the strap automatically.
4. The first connection offloads the last ~14 days of history from the strap — this takes a few minutes over Bluetooth.

### WHOOP 5.0 / MG — read this first

The WHOOP 5.0 and MG straps hold an encrypted Bluetooth bond with only one device at a time. If your strap is still bonded to the official WHOOP app on your phone, NOOP's pairing will be refused.

**To pair properly:**

1. **Close the official WHOOP app** on your phone — fully quit it, or turn that phone's Bluetooth off.
2. **Put the strap in pairing mode** — tap the band firmly and repeatedly on the sensor side until the LEDs flash blue.
3. In NOOP: go to **Live**, select **"WHOOP 5.0 / MG"**, then tap **Scan & Connect**.

A successful connection shows `CLIENT_HELLO acked — link established` in the strap log. It may take a couple of attempts.

> **Note:** The strap can only hold one bond at a time. If live heart rate is showing but buzz, alarm, double-tap, and history are not working, the strap is not truly bonded to this device — free it from everything else and pair again.

### What to expect after pairing

- **Live heart rate** appears as soon as the strap connects.
- **Strain and sleep** fill in after the first history offload (a few minutes).
- **Recovery** sharpens over the first few nights as NOOP learns your personal baseline — the same warm-up period WHOOP itself requires.
- **In a hurry?** Import your WHOOP export (see below) and your full history fills in in about a minute.

---

## Importing existing data

If you already have months or years of data in the official WHOOP app or in Apple Health, you can bring it into NOOP in one step.

### From the WHOOP app (CSV export)

1. In the official WHOOP app, go to **Account → Privacy → Export Data** and request a data export. WHOOP emails you a `.zip` file.
2. In NOOP, open **Data Sources**.
3. Tap **Import WHOOP Export** and select the `.zip` file you received.

NOOP supports the WHOOP export format for 4.0, 5.0, and MG straps.

### From Apple Health (macOS only)

1. On your iPhone, open the **Health** app → your profile picture → **Export All Health Data**. This creates an `export.zip`.
2. Transfer `export.zip` to your Mac (AirDrop, iCloud, cable).
3. In NOOP on macOS, open **Data Sources** and tap **Import Apple Health Export**.

The Apple Health import uses a streaming parser — even exports larger than 1 GB are handled without issues.

---

## Exploring without a strap

The Android **NOOP Demo** APK (`NOOP-demo.apk`) comes preloaded with 120 days of synthetic data and lets you explore every screen — Today, Sleep, Trends, Workouts, Health, Readiness, and more — without any strap. It installs alongside the full app and shows a visible DEMO badge.

On macOS, you can import a WHOOP CSV or Apple Health export to populate the app with your own data before ever pairing a strap.

---

## Next steps

- **[BUILD.md](BUILD.md)** — building NOOP from source (macOS and Android)
- **[docs/CONTRIBUTING.md](CONTRIBUTING.md)** — contributing to the project
- **[DISCLAIMER.md](../DISCLAIMER.md)** — medical and legal notice
- **[docs/DONATIONS.md](DONATIONS.md)** — optional support for the project
