# GSI Loader Samsung

Run a GSI (a generic Android system image) in a container on a rooted Samsung phone, without flashing anything. The phone's own system stays untouched and you can switch back to One UI.

Based on [OneLineage](https://github.com/WeWaffles/OneLineage) by WeWaffles.

## Risks — read this first

- **Back up the phone before running a guest.** A guest run can lose data. Nothing here is guaranteed safe.
- **Data corruption is a real risk.** Other GSI loaders and forks have shipped bugs that corrupted user data. This app keeps the guest in a file, flashes nothing, and aborts instead of guessing, which lowers the risk, but it does not remove it.
- **Lockscreen and lock-state risk.** The guest and the host share user 0, so the guest can run into the host's lockscreen and encryption-key protections. If the guest refuses a lock operation, leave it alone — forcing it can put your real lock data at risk.
- Rebooting always returns to working One UI. Temp root does not survive a reboot.

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

Version 6.24. Work in progress. The guest reaches system startup and then stops on a lock/encryption-key error from the system volume service. Guest service isolation work is in progress to stop the guest and host colliding. Not proven booting yet.

## Recent changes

- 6.16–6.18: guest APEX binding and diagnostics that capture why the guest dies instead of a blank screen.
- 6.19–6.22: guest service isolation option and better detection of the guest system.
- 6.23–6.24: isolation patcher rewritten to prove every change is safe before patching, plus a boot-time check that the isolated service comes up.

## License

Apache 2.0. See LICENSE.
