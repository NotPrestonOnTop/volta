# Volta

Rootless tweak for iOS 15 – 17 (Dopamine, palera1n rootless). Adds a **Volta** pane to Settings with a dashboard of six cards (Status Bar, Home Screen, Lock & Alerts, Control Center, Fun, More). A card with several pages opens a short list of them; most pages have a live preview:

**Battery** (status bar, in every app)
- Animated pictures: add Pulse, Bounce, Wobble, Spin, Blink or Shake to any still picture, or build your own in the Animation Creator (draw 16 × 16 pixel frames, add photos, or import a GIF; up to 24 frames), with named save slots
- Replace the icon with a picture: built-in Pumpkin, Ghost, Candy Corn, Bat, Heart, Star and Firefly, or any image from Photos or Files; optionally filling up with the charge level
- Fake percentage, custom text instead of the number, hide the percentage, hide the % symbol
- Force the number inside the icon on or off (iOS 16+)
- Hide the icon, hide the tip, resize the icon (50 – 150 %)
- Force the charging bolt or the yellow Low Power look on or off
- Custom fill, outline, tip, bolt and text colors, or color by charge level
- Live preview at the top of the page

**Status Bar** (in every app)
- Clock: seconds, 24-hour, weekday, date, or your own format
- Date (iPad): replace it with any text, or hide it; custom carrier name on cellular devices
- Hide single items: Wi-Fi, cellular, location, Focus, rotation lock, alarm, airplane mode, VPN, headphones
- Fake cellular: signal bars, a network type (5G, LTE...) and a carrier name for an iPad with no cellular
- Fake hardware: an iPhone-style notch or Dynamic Island at the top of the screen (the island stretches to show the charge when you plug in), and a fake home bar. Pictures only; touches pass through

**Home Screen**
- Icon size, hide app names, hide page dots
- Custom rows and columns per orientation (experimental, needs a respring)

**Icons**
- Shapes: circle, hexagon, octagon, leaf, star, heart, diamond
- Tints: colorize, wash, grayscale, invert, with a strength slider
- Icon packs: import a .zip of PNGs named by bundle id, or give one app a picture from Photos

**App Switcher**
- Card corner radius, a border, and hiding the app name and icon above each card

**Keyboard** (in every app)
- Always dark or always light keys, a color wash behind the keys, or a rainbow that cycles

**Volume & Charging**
- A custom volume indicator (pill, slim bar or side bar) in your color, optionally for brightness too
- A full-screen charging animation when you plug in: ring, battery filling up, or lightning bolt

**Notifications**
- Tint color and strength, corner radius, border, remove the blur

**Profiles**
- Save every Volta setting as a named profile, switch in one tap, share a profile as a `.voltaprofile` file and import one

**Control Center**
- Background blur amount, background tint color and strength
- Hide the status bar strip, haptic on open
- Module corner radius, background opacity, tint, border color and width
- Active color and roundness of the round toggles

**Apps for iPad** (installed with the tweak, shown on the Home Screen)
- Phone: keypad with touch tones, favorites and recents. It cannot place cellular calls; "calling" ends by offering FaceTime Audio
- Calculator: a working four-function calculator
- Weather: real current conditions, the next 24 hours and a 7-day forecast for a city you pick (data from Open-Meteo)
- Compass: a working compass with a bubble level
- Voice Memos: record, play back, rename, share and delete recordings
- Wallet: a card and pass holder for looks, with QR passes. It cannot pay, and never asks for a full card number
- Saved: a watch-later list for YouTube videos that needs no account. It keeps links (with title and thumbnail), not the videos; Volta adds a Save to Volta button to share sheets whenever a YouTube link is shared
- **Voltweaks**: a tweak manager. Lists every tweak the jailbreak loads, with the package it came from, its version and author, and what it loads into; switch any tweak off or on (takes effect after a respring, nothing is deleted), turn everything off at once to hunt down a misbehaving tweak, search, and respring from the app
- Each app has an on/off switch on the main Volta page

**Fun** (all off by default)
- Chaos Mode turns everything on at once; Calm Down turns it all off
- App switcher: wobbly, rainbow, upside-down, spinning and tiny cards
- Icons: dancing, heartbeat, random sizes, disco, spin when tapped, Icon Gravity (icons fall and slide as you tilt), Explode Icons
- Touch: sparkles, rainbow finger trail, screen shake, tap sounds
- Home Screen: emoji rain (your emoji), disco lights, cracked screen, googly eyes that follow your finger, a bouncing firefly, tilted / upside-down / mirrored screen
- Dock: rainbow, hopping, and throwable (two fingers) with bounciness and gravity sliders
- Status bar, in every app: wiggly, jumpy, pulsing, upside down
- Elsewhere: confetti and a fortune on unlock, jelly Control Center, dizzy Lock Screen clock, silly app names (backwards, sPoNgE cAsE, everything is Bob)

**About page**
- Credits, and an update checker that reads a small file you host (see "Updates" below)

**Control Center layout and custom controls** (Control Center > Layout & Custom Controls)
- Reorder, resize (1×1 up to 4×2) or hide any module, including the fixed ones; change tile size and spacing (needs a respring)
- Your own row of up to 8 buttons under the modules: open an app, a link or a shortcut, toggle Dark Mode, Low Power Mode or orientation lock, lock, respring
- A custom label with {date}, {time} and {battery}
- One-tap style presets: Glass, Neon, Midnight, Sunset

**Lock Screen**
- Widgets under the clock: weather (from the city chosen in the Weather app), battery, a greeting, week and day of the year, and a countdown to a date
- Clock: typeface (rounded, serif, monospaced, heavy, ultra light), color, size and position; a message under the clock; hide the date, the "Press Home" text, page dots, and the flashlight / camera buttons and padlock on Face ID devices
- Unlock gesture: a classic slide-to-unlock slider (your own text and knob color), swipe up from the bottom edge, or both; it requests a normal unlock, so a passcode is still asked for

**Dock** (iPhone dock and iPad floating dock)
- Background opacity, tint color and strength, corner radius, border color and width
- Hide the divider on iPad

**Animated wallpaper** (iOS 15)
- Built-in scenes drawn live: Aurora, Fireflies, Starfield, Snow, Embers, Bubbles
- Or loop your own video from Photos or Files, silent by default, with optional sound capped at 40 % volume
- Your own sound file (MP3, M4A, WAV…) looping with any scene, in place of a video's own sound
- Or import a .tendies wallpaper; its Locked / Unlock / Sleep states follow the device
- Home Screen, Lock Screen or both; speed; dim; keep your own wallpaper behind the particles
- Pauses while the screen is off or an app is open

Everything is visual only. The real battery level and system behaviour are untouched.

## Install

Download [`com.notpreston.volta_2.3.0_iphoneos-arm64.deb`](releases/com.notpreston.volta_2.3.0_iphoneos-arm64.deb) from the `releases` folder, open it with Sileo, Zebra or Filza, then respring.
For rootless jailbreaks (Dopamine, palera1n rootless) on iOS 15 – 17.
Requires ElleKit (or another Substrate-compatible injector) and PreferenceLoader.

## Build

    export THEOS=~/theos
    make package FINALPACKAGE=1        # add "install" with THEOS_DEVICE_IP set to push to a device

## Layout

    Tweak.x              hooks: battery (all apps) and Control Center (SpringBoard)
    Status.x             hooks: status bar text, hidden items, fake cellular signal (all apps)
    Icons.x              hooks: Home Screen layout and icon themes (SpringBoard only)
    LockLook.x           hooks: Lock Screen clock, message and hidden bits (SpringBoard only)
    Notify.x             hooks: notification styling (SpringBoard only)
    Switcher.x           hooks: App Switcher cards (SpringBoard only)
    Popups.x             the volume / brightness indicator, the charging animation, and the fake notch / Dynamic Island / home bar (SpringBoard only)
    Keyboard.x           hooks: keyboard appearance and color (all apps)
    Share.x              hooks: the Save to Volta share-sheet button (all apps)
    VLTIconTheme.h       icon shapes and tints; shared with the Settings preview
    VLTLook.h            small helpers shared by the look-and-feel hooks
    Home.x               hooks: dock and animated wallpaper (SpringBoard only, separate library)
    Lock.x               hooks: Lock Screen unlock gestures (SpringBoard only)
    VLTSlider.m          the slide-to-unlock and swipe-up controls; shared with the Settings preview
    Fun.x                hooks: switcher cards, dancing icons, sparkles, confetti, throwable dock; app on/off (SpringBoard only)
    Layout.x             hooks: Control Center module layout and custom controls (SpringBoard only)
    VLTActions.h         what a custom button can do; shared with Settings
    VLTScene.m           the animated scenes; used by the wallpaper and by the Settings preview
    VLTShared.h          preference keys, color helpers, settings hand-off to apps
    Volta.plist          injection filter (com.apple.UIKit)
    layout/              install script and the folder the custom picture is shared from
    voltaphone/          the Phone app
    voltacalc/           the Calculator app; CalcCore.h is its arithmetic, testable on its own
    voltaweather/        the Weather app; also writes weather.plist for the Lock Screen widget
    voltacompass/        the Compass app
    voltamemos/          the Voice Memos app
    voltawallet/         the Wallet app
    voltasaved/          the Saved app; SavedCore.h finds the video id in a link and is tested on its own
    voltweaks/           the Voltweaks app (tweak manager)
    voltweakshelper/     the small set-uid tool Voltweaks uses to rename a tweak's file; it only ever renames
                         <Name>.dylib <-> <Name>.disabled inside the tweak folder
    voltaprefs/          Settings pane
      VLTControllers.m   the pages, color picker, respring, reset
      VLTMore.m          Home Screen, Icons, Status Bar and Notifications pages; icon pack import; profiles
      VLTViews.m         header banner, battery preview, color row
      VLTUnzip.c         zip extractor for .tendies files (plain C, zlib)
      VLTCreator.m       animation creator and pixel editor
      VLTAbout.m         credits page and update checker
      VLTLayout.m        layout page, module editor, button editor, presets
      VLTPreviews.m      dashboard cards, Control Center / Dock / Wallpaper previews
      Resources/*.plist  the rows on each page

Sandboxed apps cannot read the tweak's preferences, so SpringBoard reads them and
republishes the battery settings as Darwin notification state (see `VLTShared.h`).
A custom picture is copied to `/var/jb/Library/Application Support/Volta/battery.png`,
which apps can read. Built-in pictures are drawn in code from the shape lists in `VLTShared.h`.

Hook names were checked against iOS 13 and iOS 17 runtime headers and the iOS 15.6 SDK;
anything iOS 15 might lack is looked up at run time and skipped if absent.

To rename the tweak or change the bundle id, replace `com.notpreston.volta` in
`control`, `VLTShared.h` and `voltaprefs/Resources/*.plist` + `voltaprefs/entry.plist`.

## Updates

Volta has no server. The About page finds new versions by reading a small JSON file over https.
This repository hosts one; paste this link into About > Update link:

    https://raw.githubusercontent.com/NotPrestonOnTop/volta/main/updates.json

For a new version: add the new .deb to `releases/`, then change `version`, `notes` and `url` in
[`updates.json`](updates.json). The file looks like this:

    { "version": "2.3.0", "notes": "What changed", "url": "https://where-to-download" }

Volta checks it once a day and compares `version` with its own. When you release a new
build, bump `Version` in `control` and `VLT_VERSION` in `VLTShared.h`, then update the file.
