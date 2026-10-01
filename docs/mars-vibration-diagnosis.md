# Vibration runaway on mars — findings after the user confirmed the trigger

## The confirmed trigger

Asked directly, the user reported:

* **When**: dragging the **touch-feedback strength slider** (「触感反馈强度」) in
  Settings.
* **Otherwise**: "只要不触发震动就没事" — nothing happens as long as no vibration
  is triggered.

That matches the framework evidence exactly (`dumpsys vibrator_manager`):

```
36  opPkg: com.android.settings
38  reason: TAG=haptic_feedback_config_strength
26  cancelled_superseded
```

`haptic_feedback_config_strength` is that slider's setting, and each drag step
fires a preview vibration that `cancelled_superseded`-cancels the previous one.

## What the hardware is doing — measured

While the user dragged the slider and felt the motor running, the chip was
sampled directly over I2C (bus 0, address `0x5A`) and read from the driver's own
sysfs surface:

| Measurement | Result |
| --- | --- |
| 600 I2C samples during the drag | **0 active** — `GO=0x00 GLB=0x00` throughout |
| 400 rapid samples of GLB/GO/RTP/CONT/0x0b | **zero changes**, all idle |
| Full register snapshot (26 registers) | all nominal; `0x05=0x00`, `0x46=0x00` |
| driver `activate` | `0` |
| driver `loop` (all 8 sequences) | `0x00` |
| driver `duration` | `0` |
| `do not enter standby` (the real error) | **0** for the whole session |
| `haptic_start` during a full drag window | 13 |

So **the aw8697 driver is not driving the motor while it is felt spinning.**

## What was ruled out

* **The chip is healthy and obedient.** `ID=0x97`; during a *commanded* vibration
  it follows exactly: `GO=0x01 GLB=0x07` → `GO=0x00 GLB=0x07` → `GO=0x00 GLB=0x00`
  (~0.4 s). A 5-second oneshot, continuous mode with `duration=0`, and ten
  back-to-back requests all returned to rest and stayed there.
* **The `glb_state=0x07` log spam is not the fault.** The driver polls up to
  100 × 2 ms = 200 ms while the chip settles in ~100 ms, and the loop always
  succeeds — the error line `do not enter standby` never appears.
  It is visible only because `aw8697.c:15` has a bare `#define DEBUG`, so
  `printk.h`'s `#elif defined(DEBUG)` branch turns `pr_debug` into a real
  `printk`. `CONFIG_DYNAMIC_DEBUG` and `CONFIG_DEBUG_FS` are both unset. Not a
  KernelSU effect and not silenceable from our side.
* **`aw8976_vibrator` is not a second device.** That thread name comes from
  `aw8697.c:4733`, `create_singlethread_workqueue("aw8976_vibrator_work_queue")`
  — a typo in the vendor driver.
* **Only one FF device exists.** `event2 = "aw8697_haptic"` is the sole input
  device with `FF_*` capability. The PM8350B `qcom,hv-haptics@f000` node exists
  but its `driver` symlink is absent, so it is not bound.
* **The MIUI haptic props are not the gate.** `sys.haptic.infinitelevel`,
  `.dynamiceffect` and `.dynamiceffect.richtap` were all set to `false` live; the
  runaway still occurred.
* **Disabling touch feedback does not stop it.** `haptic_feedback_enabled` was
  `0` throughout, and the runaway still occurred — so the slider preview does not
  go through the AOSP `VibratorManagerService` path. The vendor HAL
  `vendor.xiaomi.hardware.vibratorfeature.service` holds
  `/dev/input/event2`, `/sys/bus/i2c/drivers/aw8697_haptic` and the
  `0-005a/custom_wave` node open, i.e. it drives the chip directly.
* **Writing the setting from a shell does not reproduce it.**
  `settings put system haptic_feedback_config_strength N` 200 times produced
  0/200 active samples. The effect requires the real Settings UI and a real
  touch, so it cannot be reproduced over ADB.
* **`haptic_feedback_infinite_intensity` regenerates.** It was deleted
  (`1.02` → gone) and reappeared as `0.84`, so the Settings UI rewrites it; it is
  a symptom of that screen being opened, not the cause.

## Where that leaves it

Everything observable from the kernel and from root says the aw8697 is idle while
the motor is felt running. The remaining explanation is that the felt drive comes
through the **vendor HAL's `custom_wave` / RTP path**, which streams a waveform
straight to the chip without the driver's FF work routines running — that is
consistent with `activate=0` and all-idle registers, because in RTP mode the chip
is fed continuously rather than started and stopped per effect.

The HAL is closed source (`/vendor/bin/hw/vendor.xiaomi.hardware.vibratorfeature.service`,
`/vendor/lib64/libaachaptics.so`), so this cannot be fixed from the kernel side.

**This is a MIUI userspace/vendor-HAL defect, not a kernel or KernelSU defect.**
The kernel driver, the chip, and the kernel's own logs all show correct
behaviour; nothing we changed is implicated, and no kernel-side change can
address it.

## Practical options for the user

1. **Stop using that slider** — the only confirmed trigger, and the only fix with
   no downside. Set the strength once by *tapping* rather than dragging; a tap
   writes one value, whereas dragging streams a preview vibration per step.
2. **Clear Settings' state** so the page starts fresh:
   `pm clear com.android.settings` (this resets other Settings preferences too).
3. **Last resort — stop the vendor HAL.** Verified to work:

   ```sh
   su -c 'setprop ctl.stop vibratorfeature-hal-service'
   ```

   (note the exact service name; `vibratorfeature-hal-service`, not the process
   name). Confirmed `running` → `stopped` with the process gone.

   **But this disables ALL haptics**, not just the slider: with the HAL stopped, a
   normal `cmd vibrator_manager synced oneshot 255` no longer reaches the driver
   at all (`haptic_start` stayed at 13). It is also not persistent — a reboot
   restarts the service. Worth knowing as an escape hatch, not as a fix.
4. **Report it to Xiaomi.** The mechanism — one preview vibration per drag step,
   each superseding the last — is MIUI Settings behaviour against a closed-source
   vendor HAL, so there is no kernel-side remedy.
