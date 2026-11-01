# GSI Loader Samsung

Run a GSI (a generic Android system image) in a container on a rooted Samsung phone, without flashing anything. The phone's own system stays untouched and you can switch back to One UI.

Based on [OneLineage](https://github.com/WeWaffles/OneLineage) by WeWaffles.

## How it works

- The GSI image lives as a file on the phone. Nothing is flashed.
- The app stages the image, starts it in a container on the phone's own kernel, and stops the host system while the guest runs.
- Returning to One UI restores the host system.

## How to use

1. Install the app.
2. Pick a GSI image file and install it into a slot.
3. Tap Boot.
4. To go back, use Return to One UI in the app.

You need temp root on the phone to boot a guest. The app itself opens without it.

## Status

Version 6.15. Work in progress. The guest currently starts but stops early in system startup on one unreadable system file carried over from the host. The fix in progress hides that file from the guest.

## Recent changes

- 6.11: diagnostic shim to trace which process opens the mystery file.
- 6.12 / 6.13: split the starter's output handles to find which one the system rejects.
- 6.14: all starter output goes nowhere; old logs clear on update; version shown in the app and in diagnostics.
- 6.15: the starter now filters the host package list, hiding entries the guest cannot open.

## License

Apache 2.0. See LICENSE.
