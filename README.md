This is a modified fork of **mspeedo** shader for G8 G85SB (should work for other 3rd gen TB400 QDs in Peak1000) to include color preserving boost slider. EOTF_BoostMod1.5.

Second version made for Aorus FO32U/2/2P QD-OLED based on approximated and aggregated values from TFT review. Ramped down from high values. Based on F03/4 firmware, newer firmware may not behave identically. This should be somewhat accurate if your Windows Calibration Tool clips at 1080 nits. EOTF_BoostMod1.5_FO32.

# EOTF Boost for QD-OLED

This shader is based on the original [QD-OLED-APL-FIXER](https://github.com/DespairArdor/QD-OLED-APL-FIXER) project by **DespairArdor**.

This fork is VIBECODED.

This version is made for **QD-OLED monitors running in Peak 1000 / High Brightness mode**, and it is **modeled around the measured behavior of the specific monitor (Samsung Odyssey OLED G8 G85SB)**.

It is meant to help compensate for the stronger brightness limiting / ABL behavior that happens in this mode, especially in brighter HDR scenes.

## What this shader does

OLED displays can look very bright in small highlights, but they often get dimmer when a large part of the screen is bright at the same time.

This shader helps counter that by applying a controlled HDR brightness boost based on **real measured APL behavior**, instead of using a simple generic HDR boost.

In simple terms, the shader looks at how bright the overall scene is, then adjusts the boost based on that scene brightness level.

## Important

This shader is designed for **Peak 1000 / High Brightness mode** on **QD-OLED monitors**.

It is **not a universal preset for every display**. Even if it may still be usable on other QD-OLED screens, the built-in behavior is specifically modeled around the specific monitor.

## Monitor data used in this shader

The shader includes built-in measured brightness data for this monitor, including approximately:

- **100% screen / full field:** 252 nits
- **50% window:** 299 nits
- **25% window:** 356 nits
- **15% window:** 408 nits
- **10% window:** 465 nits

It also includes built-in APL compensation points from **3% to 50% APL**.

## Recommended starting settings

These are the default settings in this release and are a good place to start:

- **APL Input Mode:** PQ Decoded Normalized
- **APL_DECODE_SIZE:** 32
- **APL Reference White (nits):** 1000
- **APL Trigger:** 0.00
- **Max APL Boost Strength:** 0.4
- **Boost roll off end:** 1000
- **BT.2390 roll off shape:** 1.25
- **Shadow Protection Floor:** 1.0
- **APL Smoothing Time (s):** 0.25
- **Saturation Compensation:** 1.0

## Shader controls guide

### APL Input Mode
Choose how the shader reads HDR brightness.

- **PQ Decoded Normalized** = correct for most HDR setups
- **scRGB Normalized** = only use this if your HDR pipeline is scRGB

For most users, leave this on **PQ Decoded Normalized**.

### APL_DECODE_SIZE
Controls how many points the shader checks to estimate overall screen brightness.

- **Higher value** = more stable result
- **Lower value** = a little lighter to run, but less stable

Default **32** is a good choice.

### APL Reference White (nits)
Controls how the shader judges overall scene brightness. 

- **Higher value** = boost feels more conservative
- **Lower value** = boost feels more aggressive

Default **1000** is the intended starting point for this shader.

### APL Trigger
Controls when the shader starts kicking in.

- **Lower value** = boost starts earlier
- **Higher value** = boost waits for brighter scenes

Default is **0.00**, so the effect can work across the full range.

### Max APL Boost Strength
This is the main strength slider.

- **Higher value** = stronger brightness boost
- **Lower value** = weaker effect

If you only change one setting, this is usually the first one to try. I do not recommend values above 0.4 for 1000nit content, otherwise there is too much compression of HDR input vs real monitor brightness output, which causes overblown highlights.

### Boost roll off end
This sets the **target max nits for highlight roll-off**.

For this preset, **1000 nits** is the intended starting point because it is designed for **Peak 1000 / High Brightness mode**.

- **Higher value** = brighter highlights
- **Lower value** = safer highlight control

In simple terms: this should match the HDR peak target you want the shader to roll into.

### BT.2390 roll off shape
Controls how softly or strongly bright highlights are compressed near the top end.

- **Lower value** = highlights stay brighter longer
- **Higher value** = highlights are compressed earlier

Default **1.25** is a good balanced setting.

### Shadow Protection Floor
Controls how much of the boost is allowed into darker parts of the image.

- **Higher value** = more full-image boosting
- **Lower value** = more protection for dark areas

Lower it if dark scenes start looking too lifted.

### APL Smoothing Time (s)
Controls how quickly the shader reacts when scene brightness changes.

- **Higher value** = slower, smoother changes
- **Lower value** = faster reaction

A higher value can help reduce visible brightness flicker caused by the shader when scenes change quickly.

### Saturation Compensation
Adjusts color intensity after brightness is boosted.

- **1.0** = neutral
- **Higher value** = stronger color
- **Lower value** = less color intensity

Leave it at **1.0** unless colors look too weak or too strong after boosting.

### scRGB Signal Reference (nits)
Only matters if you use **scRGB Normalized** mode.

Most users can ignore this.

### Show APL / Metric Stats
Shows a small on-screen info display with live shader values.

This is optional and not needed for normal use.

### OSD Brightness
Changes the brightness of the on-screen info display only.

It does **not** change the shader effect itself.

## Simple tuning tips

- Want a stronger effect? Increase **Max APL Boost Strength**
- Highlights look wrong? Check **BT.2390 roll off shape** first
- Shadows look too lifted? Lower **Shadow Protection Floor**
- Image brightness changes feel too twitchy or flickery? Increase **APL Smoothing Time**

## Using measurements from another monitor

This shader can be adapted to another **QD-OLED** if you have your own measured APL behavior.

### What data you need

For the **live boost logic**, the most important data is a **1D APL compensation LUT**:

- a list of **APL points** in percent  
  example: `3, 5, 7, 10, 14, 18, 22, 25, 35, 50`
- a matching list of **compensation values** for those APL points  
  example: `1.0, 1.35, 1.67, ...`

In this shader, those are stored in:

- `APL_POINTS`
- `COMP_APL_1D`

### What the compensation values mean

The compensation values describe how much darker the monitor measured than the requested HDR target at a given APL.

- **1.0** = no compensation needed
- **Higher than 1.0** = the monitor dimmed more, so the shader boosts more

### If you only have a larger 2D measurement table

This shader’s live path does **not** use the full 2D table directly.

Instead, it uses a **collapsed 1D LUT** made from one representative value per APL row.

So if you measured another monitor with a 2D table, the easiest way to adapt this shader is:

1. Keep your chosen APL points
2. Pick one representative compensation value for each APL row
3. Replace the values in `COMP_APL_1D`
4. Keep the values in ascending APL order
5. Make sure both arrays have the same number of entries

### Minimum changes needed for another monitor

For basic retuning, you only need to replace:

- `APL_POINTS`
- `COMP_APL_1D`
- `COMP_MAX`

That is enough to change the shader’s live APL-based boosting behavior.

### Optional extra data

The shader also contains built-in full-field / window measurement data for specific monitor:

- **100% window**
- **50% window**
- **25% window**
- **15% window**
- **10% window**

These are useful if you also want the built-in model or graph overlays to better match another monitor.

But for simple live retuning, the main thing you need is the **1D APL LUT**.

## Graphs

This shader can also include an optional **APL EOTF debug graph**.

The graph is only for analysis and tuning. It is not needed for normal use.

It can show:

- a normal **APL-based curve view** for a selected APL value
- or a **window projection view** using the built-in **100%, 50%, 25%, 15%, or 10%** window measurements


## Final note

This shader is designed for **QD-OLED Peak 1000 / High Brightness mode**, and this specific preset is modeled around the specific monitor.

It is not meant as a one-size-fits-all HDR preset, but it can be adapted for other displays if you have matching measured APL data.


