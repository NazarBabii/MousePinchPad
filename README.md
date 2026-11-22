# MousePinchPad

**Trackpad-style pinch zoom and right-button shortcuts for any mouse on Windows 11.**

An AutoHotkey v2 script that turns your right mouse button into a control layer: while it's held, the wheel and the other buttons do extra things. The main one is smooth **pinch-to-zoom, exactly like on a trackpad**, instead of the usual Ctrl+wheel page scaling.

## Why

Browser extensions and most mouse tools "zoom" by sending Ctrl+wheel, which changes the page scale and reflows the layout. A trackpad pinch does something else: it zooms the rendered image, like on a phone, without reflowing anything.

MousePinchPad creates a virtual Precision Touchpad and performs a real two-finger pinch on it, so Chrome, Edge and other gesture-aware apps get the genuine trackpad gesture.

## Features

| Combination | Action |
|---|---|
| Right button (alone) | Normal right click / context menu |
| Right + wheel up / down | Pinch zoom in / out (centered under the cursor) |
| Right + tilt wheel right / left | Volume up / down |
| Right + wheel click | Play / pause |
| Right + Forward / Back button | Window switcher (like Alt+Tab) forward / back. Release the right button to pick the window |
| Right + left click (short) | Show desktop (Win+D), press again to restore windows |
| Right + left click (hold ~0.8 s) | Lock the PC (like Win+L) |

## Requirements

- **Windows 11** with support for `CreateSyntheticPointerDevice2` (the virtual touchpad API). Quick check:
  ```ahk
  h := DllCall("GetModuleHandle", "Str", "user32", "Ptr")
  MsgBox DllCall("GetProcAddress", "Ptr", h, "AStr", "CreateSyntheticPointerDevice2", "Ptr") ? "Supported" : "Not supported"
  ```
  Note: Microsoft's documentation still marks this API as pre-release, so it may change.
- **AutoHotkey v2, 64-bit**: [autohotkey.com](https://www.autohotkey.com/)

## Installation

1. Install AutoHotkey v2.
2. Download `MousePinchPad.ahk` and double-click it. A green **H** icon appears in the system tray.

**Run at startup:** press `Win+R`, type `shell:startup`, and put a shortcut to the script there.

## Usage

Right-click the **H** tray icon:

- **Reload Script**: apply changes after editing
- **Suspend Hotkeys**: temporarily disable (the right button works normally)
- **Exit**: stop the script

To edit, right-click the file → **Edit script** (or open it in any text editor), save, then **Reload Script**.

To uninstall, choose **Exit**, remove the shortcut from `shell:startup` if you added one, and delete the file. MousePinchPad doesn't change any system settings.

## Configuration

Settings are at the top of the script:

| Setting | Default | What it does |
|---|---|---|
| `ZOOM_STEP` | 1.3 | Zoom per wheel notch. Higher is faster |
| `SMOOTH_MS` | 30 | Motion smoothing, ms. Higher is smoother but with more "inertia" |
| `FRAME_MS` | 4 | Interval between gesture frames, ms |
| `SLOP` | 150 | Gesture recognition threshold. If zoom doesn't start on the first notch, raise it; if the start feels jumpy, lower it |
| `HOLD_MS` | 30 | How long the fingers stay still before lifting |
| `MOVE_PX` | 15 | How far (px) the cursor must move before the zoom center follows it. Raise it if the center jumps from hand jitter |
| `IDLE_MS` | 1500 | How long after zooming the virtual touchpad is removed from the system |

The lock hold time is the number in `KeyWait("LButton", "T0.8")`.
To reverse the volume direction, swap `Volume_Up` and `Volume_Down`.

## How it works

**Zoom.** The script creates a virtual Precision Touchpad in gesture-only mode (`SDCO_TOUCHPAD_GESTURE_ONLY`) and injects two "fingers" moving apart or together. To Windows and the browser this is the same pinch as from a real trackpad, so:

- the image zooms, not the page scale;
- the cursor never hides and no clicks or taps are generated, since a gesture-only touchpad can't click.

The wheel only moves the zoom *target*. A separate loop moves the fingers toward it with two-stage smoothing, so consecutive notches blend into one continuous motion. Zoom is computed logarithmically, so every notch gives the same relative change.

The virtual touchpad exists only while zooming and for `IDLE_MS` afterwards. Between zooms it doesn't interfere with your real trackpad, and removing the device guarantees no "stuck" fingers are left behind.

**Window switching** uses AutoHotkey's built-in `AltTab` / `ShiftAltTab` actions, with the right button acting as the held Alt key.

**Locking** calls `LockWorkStation`. `Send "#l"` doesn't work because Windows ignores a programmatically sent Win+L.

## Limitations

- Pinch zoom works in apps that support trackpad gestures (Chrome, Edge, etc.). Apps without that support won't zoom.
- While the right button is held during a zoom, the real trackpad doesn't respond, because the virtual fingers are "on" the virtual touchpad.
- Right-button dragging (mouse gestures in other apps, right-drag selection) won't work, since the right click fires on release.
- During a long continuous zoom, or when the cursor moves to a new spot, there is a brief pause while the virtual fingers re-grip.
- In windows running as administrator, the script only works if it also runs as administrator.
- Don't run other scripts that also hook the right button: only the last one started will receive it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Не вдалось створити віртуальний тачпад" (failed to create the virtual touchpad) | Your Windows doesn't support the API (see Requirements) |
| `InjectSyntheticPointerInput` error tooltip | Note the error code and restart the script |
| Zoom doesn't start on the first notch | Raise `SLOP` |
| Tilt wheel or side buttons do nothing | Your mouse software (Logi Options+, Razer Synapse, etc.) is intercepting them. Restore their default actions there |
| Page looks blurry or the trackpad stops working after zooming | Release the right button and wait ~1.5 s. If it persists, **Exit** the script |

## License

[MIT](LICENSE)
