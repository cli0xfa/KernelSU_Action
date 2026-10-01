# Vibration ("motor running away") on mars — diagnosis

## Conclusion up front

**The kernel is not at fault.** The aw8697 haptics driver is original and
unmodified, it is loaded and bound, and the chip follows every command correctly.
The runaway comes from the **Android framework re-issuing vibration requests**,
which is a userspace matter entirely unrelated to KernelSU or to the custom
kernel.

## Evidence

### 1. The chip is healthy — read directly over I2C

`i2cget` is present on the device, so the chip (I2C bus 0, address `0x5A`) can be
read without going through the driver:

```
ID        = 0x97   <- correct AW8697 id; the bus and the chip both work
GO        = 0x00   <- not playing
GLB_STATE = 0x00   <- standby, exactly what the driver wants
```

Sampling during a vibration shows the chip following commands normally:

```
GO=0x01 GLB=0x07    <- motor starting
GO=0x01 GLB=0x07
GO=0x00 GLB=0x07    <- stop commanded (GO cleared)
GO=0x00 GLB=0x07
GO=0x00 GLB=0x00    <- standby reached, ~0.4s after start
```

And in every stress case the motor returns to rest and **stays** there — 5-second
oneshot, continuous mode with `duration=0`, and ten back-to-back requests all
ended with `GO=0x00 GLB=0x00`.

### 2. `glb_state=0x07` in dmesg is not a fault

The log fills with:

```
aw8697_haptic_stop_delay wait for standby, reg glb_state=0x07
```

but that line is harmless. The driver's own source
(`drivers/input/misc/aw8697_haptic/aw8697.c`) shows it comes from a polling loop:

```c
static int aw8697_haptic_stop_delay(struct aw8697 *aw8697)
{
    unsigned int cnt = 100;
    while (cnt--) {
        aw8697_i2c_read(aw8697, AW8697_REG_GLB_STATE, &reg_val);
        if ((reg_val & 0x0f) == 0x00)   /* standby */
            return 0;
        msleep(2);
        pr_debug("%s wait for standby, reg glb_state=0x%02x\n", ...);
    }
    pr_err("%s do not enter standby automatically\n", __func__);
    return 0;
}
```

The loop polls up to 100 × 2 ms = **200 ms**, while the chip actually settles in
about 100 ms, so a transient `0x07` reading is expected. The decisive counter is
`do not enter standby` — the real error — which was **0** across the entire log
while `wait for standby` had printed 1500+ times. The loop always succeeded.

**Why the message is visible at all** (this is the vendor's doing, not ours): it
is a `pr_debug`, which normally compiles away, but `aw8697.c:15` starts with

```c
#define DEBUG
```

so the `#elif defined(DEBUG)` branch of `include/linux/printk.h` applies and
`pr_debug` becomes a real `printk(KERN_DEBUG ...)`. Neither
`CONFIG_DYNAMIC_DEBUG` nor `CONFIG_DEBUG_FS` is set on this kernel, so the
dynamic-debug route is not in play. Turning `CONFIG_KSU_DEBUG` off would
therefore **not** silence these lines — they are independent of KernelSU. Only
editing the vendor driver would, which is not worth doing for log cosmetics.


### 3. The real source: `com.android.settings` in a supersede loop

`dumpsys vibrator_manager` names the requester and the trigger:

```
36  opPkg: com.android.settings
38  reason: TAG=haptic_feedback_config_strength
26  cancelled_superseded
```

with a run of entries like:

```
startTime: 22:00:56.525, durationMs:  25, status: cancelled_superseded
startTime: 22:00:56.550, durationMs: 297, status: cancelled_superseded
startTime: 22:00:56.567, durationMs: 284, status: cancelled_superseded
startTime: 22:00:56.850, durationMs:  74, status: finished
```

`haptic_feedback_config_strength` is the **touch-feedback strength slider** in
MIUI sound settings (`com.android.settings/.MiuiSoundSettingsActivity`). Each
change fires a vibration and each new request supersedes the last, so the motor
is re-driven continuously and never gets to finish a pulse. That is what "the
motor is running away" feels like.

Consistent with that, the device also carries:

```
haptic_feedback_infinite_intensity=1.02
```

### 4. The loop is not active when idle

Measured over 15 s with the desktop in front:

```
upload_effect       : +0
cancelled_superseded: +0
GO=0x00 GLB=0x00   (five samples over five seconds, all at rest)
```

So this is **triggered**, by interacting with that settings page (or whatever
re-issues the same tag), not a permanent kernel-side condition.

## What this means

* Nothing in the KernelSU work, and nothing in the custom kernel, causes it. The
  aw8697 driver was never touched, and its chatty logging is a consequence of its
  own `#define DEBUG`, not of any config we set.
* The fix, if the behaviour persists, is on the userspace side: stop MIUI from
  re-issuing `haptic_feedback_config_strength` in a loop. Practical options are
  to turn the touch-feedback slider to its minimum, disable touch feedback
  entirely, or clear Settings' state — not a kernel change.
* There is no kernel knob to quiet the `glb_state` lines, and none is needed:
  `do not enter standby` is the only line that would indicate a real fault, and
  it has never appeared.

## Useful commands for future checks

```sh
# chip state, bypassing the driver entirely
i2cget -y -f 0 0x5a 0x05   # GO:      bit0 = playing
i2cget -y -f 0 0x5a 0x46   # GLB_STATE: low nibble 0 = standby

# who is asking for vibrations
dumpsys vibrator_manager | grep -E 'opPkg|reason|cancelled_superseded'

# is the driver actually driving the motor?
dmesg | grep -c 'haptic_start enter'

# does the driver ever fail to stop?
dmesg | grep -c 'do not enter standby'   # must be 0
```
