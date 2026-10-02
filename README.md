# Volta

Rootless tweak for iOS 15 – 17 (Dopamine, palera1n rootless). Adds a **Volta** pane to Settings with a card dashboard and four pages, each with a live preview:

**Battery** (status bar, in every app)
- Animated pictures: add Pulse, Bounce, Wobble, Spin, Blink or Shake to any still picture, or build your own in the Animation Creator (draw 16 × 16 pixel frames, add photos, or import a GIF; up to 24 frames), with named save slots
- Replace the icon with a picture: built-in Pumpkin, Ghost, Candy Corn, Bat, Heart, Star and Firefly, or any image from Photos or Files; optionally filling up with the charge level
- Fake percentage, custom text instead of the number, hide the percentage, hide the % symbol
- Force the number inside the icon on or off (iOS 16+)
- Hide the icon, hide the tip, resize the icon (50 – 150 %)
- Force the charging bolt or the yellow Low Power look on or off
- Custom fill, outline, tip, bolt and text colors, or color by charge level
- Live preview at the top of the page

**Control Center**
- Background blur amount, background tint color and strength
- Hide the status bar strip, haptic on open
- Module corner radius, background opacity, tint, border color and width
- Active color and roundness of the round toggles

**Apps for iPad** (installed with the tweak, shown on the Home Screen)
- Phone: keypad with touch tones, favorites and recents. It cannot place cellular calls; "calling" ends by offering FaceTime Audio
- Calculator: a working four-function calculator
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

Download [`com.notpreston.volta_1.9.0_iphoneos-arm64.deb`](releases/com.notpreston.volta_1.9.0_iphoneos-arm64.deb) from the `releases` folder, open it with Sileo, Zebra or Filza, then respring.
For rootless jailbreaks (Dopamine, palera1n rootless) on iOS 15 – 17.
Requires ElleKit (or another Substrate-compatible injector) and PreferenceLoader.

## Build

    export THEOS=~/theos
    make package FINALPACKAGE=1        # add "install" with THEOS_DEVICE_IP set to push to a device

## Layout

    Tweak.x              hooks: battery (all apps) and Control Center (SpringBoard)
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
    voltaprefs/          Settings pane
      VLTControllers.m   the pages, color picker, respring, reset
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

    { "version": "1.9.0", "notes": "What changed", "url": "https://where-to-download" }

Volta checks it once a day and compares `version` with its own. When you release a new
build, bump `Version` in `control` and `VLT_VERSION` in `VLTShared.h`, then update the file.
