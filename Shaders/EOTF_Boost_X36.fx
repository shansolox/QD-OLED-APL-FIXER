/*
    EOTF Boost v8.8 - 1D APL Lookup + Optional High APL Adaptive Boost
	Calibrated for monitor MSI MPG 341CQR QD-OLED X36
    ================================================================

    Purpose
    -------
    This shader boosts HDR luminance to compensate for OLED / display ABL behavior
    using a simplified measured 1D APL lookup table, a hybrid pixel participation model,
    and an optional High APL adaptive boost modifier for lower-nit content.

    This version applies compensation as a multiplicative gain in absolute nits:

        base_scene_gain  = measured_compensation(APL) shaped by LUT weight and strength
        final_scene_gain = base_scene_gain optionally modified by the High APL adaptive boost logic
        pixel_gain       = final_scene_gain ^ participation

    where:
        - APL is the scene average picture level metric (0..1, shown as 0..100%)
        - High APL % is a secondary bright-area coverage metric built from a configurable nit range
        - compensation > 1 means the display measured darker than the requested target

    This version collapses the original measured 2D APL x nits LUT into a single
    representative compensation value per APL row (anchored near 109 nits), because
    the per-row variation across target nits was small.

    The lookup table is NOT used as a direct inverse solve.
    Instead, it is used as a shape / weight map that drives a capped boost model.

*/

#include "ReShade.fxh"

// --- COMPILE-TIME DEBUG FEATURE SWITCHES ---
// Set to 1 to compile the graph feature in, or 0 to strip it out completely.
// Variant: built-in window projection graph + BT.2390-style reference rolloff overlay.
#ifndef ENABLE_APL_GRAPH
    #define ENABLE_APL_GRAPH 0
#endif

#ifndef ENABLE_UI_TOOLTIPS
    #define ENABLE_UI_TOOLTIPS 0
#endif

// APL decode grid resolution.  Total parallel decode threads = APL_DECODE_SIZE^2.
// Must be a power of two between 8 and 64.  32 (1024 samples) is the recommended default.
// Override at compile time with: #define APL_DECODE_SIZE 16
#ifndef APL_DECODE_SIZE
    #define APL_DECODE_SIZE 32
#endif

#if ENABLE_UI_TOOLTIPS
    #define UI_TOOLTIP(text) ui_tooltip = text;
#else
    #define UI_TOOLTIP(text)
#endif

// --- UI SETTINGS ---

uniform int APLInputMode <
    ui_type = "combo";
    ui_items = "scRGB Normalized\0PQ Decoded Normalized\0";
    ui_label = "APL Input Mode";
    UI_TOOLTIP("Selects how the shader interprets scene luminance for the APL metric. scRGB uses BT.709 luma scaled by Reference White. PQ uses ST.2084-decoded BT.2020 luma scaled by Reference White.")
> = 1;

uniform float APLReferenceWhiteNits <
    ui_type = "slider";
    ui_min = 10.0; ui_max = 1500.0; ui_step = 1.0;
    ui_label = "APL Reference White (nits)";
    UI_TOOLTIP("Reference white used only for the APL metric normalization. It does not directly clamp output nits or change the graph axes.")
> = 1350.0;

uniform float APLTrigger <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.95; ui_step = 0.01;
    ui_label = "APL Trigger";
    UI_TOOLTIP("Fade-in threshold for the boost based on the smoothed APL metric. Below this level the effect is reduced or disabled. 10% APL on the graph is exactly the threshold when this is set to 0.10.")
> = 0.00;

uniform float CompensationFreezeAPLPercent <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 50.0; ui_step = 0.1;
    ui_label = "Compensation Freeze APL %";
    UI_TOOLTIP("Freezes the measured compensation lookup above the selected APL percentage. Example: 10.0 means APL values above 10% keep using the 10% compensation row. 0 = disabled.")
> = 0.0;

uniform float MaxAPLBoostStrength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "Global APL Boost Strength";
    UI_TOOLTIP("Scales the measured APL compensation in log-gain space before per-pixel participation is applied. 1.0 means full measured compensation at maximum LUT weight. Values below 1.0 under-compensate. Values above 1.0 intentionally over-compensate.")
> = 0.5;


uniform bool EnablePerAPLBoostStrength <
    ui_label = "Enable Per-APL Boost Strength";
    UI_TOOLTIP("Enables the advanced per-APL boost-strength controls below. When disabled, the shader uses only Global APL Boost Strength.")
> = false;

uniform float APLBoostStrength03 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 3% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 3% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.4;

uniform float APLBoostStrength05 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 5% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 5% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.8;

uniform float APLBoostStrength07 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 7% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 7% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.9;

uniform float APLBoostStrength10 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 10% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 10% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.8;

uniform float APLBoostStrength14 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 14% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 14% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.65;

uniform float APLBoostStrength18 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 18% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 18% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.54;

uniform float APLBoostStrength22 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 22% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 22% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.5;

uniform float APLBoostStrength25 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 25% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 25% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.5;

uniform float APLBoostStrength35 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 35% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 35% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.5;

uniform float APLBoostStrength50 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 50% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 50% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.5;



uniform bool EnableHighAPLAdaptiveBoost <
    ui_label = "Enable Adaptive Boost for Low-Nit Content";
    UI_TOOLTIP("Allows higher boost strength in lower-nit scenes. A secondary High APL % metric is built from the configured nit range and reduces the final scene boost from the adaptive maximum back toward the normal APL-based boost strength as bright HDR area increases. It does not feed back into the base closed-loop APL solve.")
> = false;

uniform float HighAPLMetricMinNits <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 1000.0; ui_step = 1.0;
    ui_category = "Advanced Adaptive Boost Setup";
    ui_category_closed = true;
    ui_label = "High APL Metric Min (nits)";
    UI_TOOLTIP("Per-pixel lower bound for the High APL % metric. Pixels at or below this level contribute 0.0 to the metric. Used only when Enable High APL Adaptive Boost is enabled.")
> = 400.0;

uniform float HighAPLMetricMaxNits <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 1000.0; ui_step = 1.0;
    ui_category = "Advanced Adaptive Boost Setup";
    ui_category_closed = true;
    ui_label = "High APL Metric Max (nits)";
    UI_TOOLTIP("Per-pixel upper bound for the High APL % metric. Pixels at or above this level contribute 1.0 to the metric. Pixels in between are scaled linearly. Used only when Enable High APL Adaptive Boost is enabled.")
> = 500.0;

uniform float HighAPLReductionStartPercent <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 100.0; ui_step = 0.1;
    ui_category = "Advanced Adaptive Boost Setup";
    ui_category_closed = true;
    ui_label = "High APL Reduction Start (%)";
    UI_TOOLTIP("High APL % level where the adaptive boost begins reducing from the adaptive maximum back toward the normal APL-based boost strength. Used only when Enable High APL Adaptive Boost is enabled.")
> = 0.0;

uniform float HighAPLReductionEndPercent <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 100.0; ui_step = 0.1;
    ui_category = "Advanced Adaptive Boost Setup";
    ui_category_closed = true;
    ui_label = "High APL Reduction End (%)";
    UI_TOOLTIP("High APL % level where the adaptive boost has fully reduced back to the normal APL-based boost strength. Used only when Enable High APL Adaptive Boost is enabled.")
> = 10.0;

uniform float HighAPLAdaptiveMaxBoostStrength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Adaptive Boost Setup";
    ui_category_closed = true;
    ui_label = "High APL Adaptive Max Boost Strength";
    UI_TOOLTIP("Maximum boost strength allowed when the High APL % metric is very low. The actual scene boost then transitions from this value toward the normal APL-based boost strength over the configured High APL % reduction range. Used only when Enable High APL Adaptive Boost is enabled.")
> = 0.9;

uniform float BoostRollOff <
    ui_type = "slider";
    ui_min = 500.0; ui_max = 1500.0; ui_step = 1.0;
    ui_label = "Boost Roll-Off Target (nits)";
    UI_TOOLTIP("Desired output anchor of the PQ highlight rolloff in nits. The shader dynamically places the knee from the current smoothed APL so the boosted curve lands on this endpoint more consistently across APL levels.")
> = 1350.0;

uniform float BoostRollOffShape <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 4.0; ui_step = 0.01;
    ui_label = "Boost Roll-Off Shape";
    UI_TOOLTIP("Adjusts the live roll off character by moving the roll off start together with the shoulder curvature so the transition stays smooth and monotonic. 1.0 = standard BT.2390. Values below 1.0 start later and hold highlights higher longer. Values above 1.0 start earlier and compress highlights harder.")
> = 1.5;


static const float PixelParticipationStartNits = 1.0;

static const float PixelParticipationFullNits = 40.0;

static const float PixelParticipationGamma = 1.0;

uniform float PixelParticipationFloor <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Shadow Protection Floor";
    UI_TOOLTIP("Minimum share of the APL-derived scene compensation applied to every pixel before the luminance-weighted participation ramp adds the remainder. Higher values track the measured ABL behavior more faithfully. Lower values behave more like a perceptual shadow-protection model.")
> = 1.0;

uniform float TransitionSpeed <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "APL Smoothing Time (s)";
    UI_TOOLTIP("Temporal smoothing time constant for the live APL-related metrics in seconds. 0 = disabled. FPS-independent. This affects live boosting and OSD values, but the graph uses its own Graph APL % slider.")
> = 0.25;

uniform float SaturationComp <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
    ui_label = "Saturation Compensation";
    UI_TOOLTIP("Adjusts color saturation after the color-preserving luminance boost. 1.0 = neutral. Lower values reduce saturation. Higher values increase saturation while preserving the boosted pixel luminance.")
> = 1.0;

uniform bool EnableColorPreservingBoostMode <
    ui_label = "Preserve Color by Reducing Boost";
    UI_TOOLTIP("When enabled, saturated colors keep their RGB ratio by reducing only the added boost before channels would exceed the Boost Roll-Off Target. Uses a fixed soft knee of 0.85. Original behavior is unchanged when disabled.")
> = false;

static const float COLOR_PRESERVING_BOOST_KNEE = 0.85;

uniform float SIGNAL_REFERENCE_NITS <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 200.0; ui_step = 1.0;
    ui_label = "scRGB Signal Reference (nits)";
    UI_TOOLTIP("Reference nits for scRGB signal conversion. Standard scRGB uses 80 nits per 1.0 signal. Used only when APL Input Mode = scRGB Normalized.")
> = 80.0;


uniform bool ShowOSD <
    ui_label = "Show APL / Metric Stats";
    UI_TOOLTIP("Displays the current raw input APL (green), smoothed output/display-side APL (yellow), maximum sampled decoded scene luminance in nits (cyan), High APL % (orange), and current final scene boost strength (magenta).")
> = false;

uniform float OSDBrightness <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 1.0; ui_step = 0.01;
    ui_label = "OSD Brightness";
    UI_TOOLTIP("Controls OSD and graph overlay brightness.")
> = 0.5;



uniform float FrameTime < source = "frametime"; >;

#if ENABLE_APL_GRAPH
uniform bool ShowAPLGraph <
    ui_label = "Show APL EOTF Debug Graph";
    UI_TOOLTIP("Shows the analysis graph. Standard mode: Blue dashed = identity reference, optional Magenta dashed = BT.2390-style reference tone map using the projected measured peak for the selected raw APL input, Light blue = real 2D measured LUT output for that raw input APL, Green = shader remapped target after the closed-loop APL solve, Gray = projected measured output at the solved display-side operating point. Window projection mode: Blue dashed = identity reference, optional Magenta dashed = BT.2390-style reference tone map using the selected window peak, Light blue = measured window EOTF for the raw input, Gray = projected window output after the closed-loop APL solve, Green = overlap between both curves.")
> = true;

uniform bool GraphShowBT2390Reference <
    ui_label = "Graph Show BT.2390 Reference";
    UI_TOOLTIP("Shows or hides the optional BT.2390-style Hermite rolloff reference overlay. It uses the measured peak for the selected APL or selected window size.")
> = false;

uniform bool GraphUseFullFieldWindowProjection <
    ui_label = "Graph Use Window Projection";
    UI_TOOLTIP("Switches the debug graph to the built-in window PQ measurement projection overlay. In this mode, Graph APL (%) is ignored. Use the window selector below to choose between the built-in 100%, 50%, 25%, 15%, and 10% window measurements. Blue dashed = identity reference, optional Magenta dashed = BT.2390-style reference tone map using the selected window peak, Light blue = measured window EOTF only, Gray = projected window output only, Green = overlap between both curves.")
> = true;

uniform int GraphProjectionWindowSize <
    ui_type = "combo";
    ui_items = "100% Window\0 50% Window\0 25% Window\0 15% Window\0 10% Window\0";
    ui_label = "Graph Projection Window Size";
    UI_TOOLTIP("Selects which built-in measured window set is used by the full-field projection graph mode.")
> = 0;

uniform float GraphAPLIndex <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 100.0; ui_step = 0.01;
    ui_label = "Graph APL (%)";
    UI_TOOLTIP("Continuous raw / pre-boost input APL value used by the standard APL-slice graph mode. Light blue = measured curve for that raw input APL. Green = shader remapped target projected from that raw input through the closed-loop APL solve. Gray = projected measured output at the solved display-side operating point. Ignored when Graph Use Window Projection is enabled.")
> = 50.0;

uniform float GraphAxisMaxNits <
    ui_type = "slider";
    ui_min = 500.0; ui_max = 10000.0; ui_step = 1.0;
    ui_label = "Graph Axis Max (nits)";
    UI_TOOLTIP("Maximum nits shown on both graph axes. Raising it lets you inspect curve behavior beyond 1000-nit input without changing the live shader.")
> = 1350.0;

uniform float GraphOpacity <
    ui_type = "slider";
    ui_min = 0.05; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Graph Opacity";
    UI_TOOLTIP("Opacity of the graph overlay background and curves.")
> = 0.5;

uniform bool GraphUsePQSpace <
    ui_label = "Graph PQ-Encoded Axes";
    UI_TOOLTIP("Renders the graph in PQ-encoded space instead of linear nits. Axis labels remain in nits.")
> = true;
#endif

// --- TEXTURES ---

texture TexAPL
{
    Width = 1;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerAPL
{
    Texture = TexAPL;
};

// Scene-uniform boost/rolloff parameters precomputed after APL smoothing.
// RGBA layout:
//   .r = full-participation scene gain exp2(sceneLogGain)
//   .g = BT.2390 PQ range; <= 0 means rolloff inactive
//   .b = BT.2390 shaped knee start in normalized PQ range
//   .a = BT.2390 compression span in normalized PQ range
texture TexBoostParams
{
    Width = 1;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerBoostParams
{
    Texture = TexBoostParams;
};

texture TexAPLInstant
{
    Width = 1;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerAPLInstant
{
    Texture = TexAPLInstant;
};

texture TexAPLPrev
{
    Width = 1;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerAPLPrev
{
    Texture = TexAPLPrev;
};

// Parallel APL decode target.
// Each of the APL_DECODE_SIZE x APL_DECODE_SIZE texels is written by PS_DecodeAPL,
// which runs on APL_DECODE_SIZE^2 GPU threads simultaneously — one PQ decode per thread
// instead of all decodes serialised inside a single 1x1 pixel shader loop.
// RG32F layout:  .r = normalised APL metric sample (0..1)
//                .g = decoded scene nits for that sample (used for the max-nits OSD value)
texture TexAPLDecoded
{
    Width  = APL_DECODE_SIZE;
    Height = APL_DECODE_SIZE;
    Format = RG32F;
};
sampler SamplerAPLDecoded
{
    Texture   = TexAPLDecoded;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};

#if ENABLE_APL_GRAPH
// Curve-precompute constants — must match DrawAPLGraphOverlay.
// Defined here (not as a const int inside the function) so the texture Width attribute
// can reference it at compile time and both the precompute pass and the draw pass agree.
#define GRAPH_CURVE_SAMPLES 64

// Row indices inside TexGraphCurves (height = 4).
// Each texel stores float4(ax, ay, bx, by) in p-space screen coords
// (texcoord with p.x *= aspect).  The precompute pass converts from nits
// to screen space so the per-pixel draw loop needs zero NitsToPQ / pow calls.
// Texels with x < 0 are sentinels: the segment should be skipped.
#define GCURVE_REMAPPED  0   // green re-mapped curve (APL mode only)
#define GCURVE_CORRECTED 1   // gray projected-output / corrected curve
#define GCURVE_MEASURED  2   // light-blue measured raw curve
#define GCURVE_BT2390REF 3   // magenta BT.2390 reference (optional)

texture TexGraphParams
{
    Width = 1;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerGraphParams
{
    Texture = TexGraphParams;
};

// Precomputed per-segment screen-space endpoints for all four curve rows.
// Width = GRAPH_CURVE_SAMPLES (one texel per segment), Height = 4 (one row per curve).
texture TexGraphCurves
{
    Width  = GRAPH_CURVE_SAMPLES;
    Height = 4;
    Format = RGBA32F;
};
sampler SamplerGraphCurves
{
    Texture   = TexGraphCurves;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};

// Precomputed grid/tick/ref line endpoints.  All positions are purely uniform-derived —
// computing them per-pixel with NitsToPQ (2 pow calls each) wastes ~200 pow calls per
// inGraphCore pixel.  Layout (one float4(ax,ay,bx,by) per texel in p-space):
//   0–8:   grid vertical lines   (i = 1..9)
//   9–17:  grid horizontal lines (i = 1..9)
//   18–23: x-tick marks          (i = 0..5)
//   24–29: y-tick marks          (i = 0..5)
//   30:    identity reference dashed line
//   31:    (padding / sentinel)
#define GRAPH_LINE_COUNT 32
texture TexGraphLines
{
    Width  = GRAPH_LINE_COUNT;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerGraphLines
{
    Texture   = TexGraphLines;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};

texture TexBoosted
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler SamplerBoosted
{
    Texture = TexBoosted;
};
#endif


// --- FUNCTIONS ---

float GetLuma709(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float GetLuma2020(float3 color)
{
    return dot(color, float3(0.2627, 0.6780, 0.0593));
}

float3 PQToLinearBT2100(float3 v)
{
    // ST.2084 / PQ EOTF
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float3 vp = pow(saturate(v), 1.0 / m2);
    float3 num = max(vp - c1, 0.0);
    float3 den = c2 - c3 * vp;
    return pow(num / max(den, 1e-6), 1.0 / m1); // 0..1 relative to 10000 nits
}

float LinearToPQBT2100(float linearValue)
{
    // ST.2084 / PQ OETF, input is 0..1 relative to 10000 nits
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float L = saturate(linearValue);
    float Lm1 = pow(L, m1);
    float num = c1 + c2 * Lm1;
    float den = 1.0 + c3 * Lm1;
    return pow(num / max(den, 1e-6), m2);
}

// float3 overload — encodes all three channels in one pair of vector pow calls instead of
// three pairs of scalar calls.  Used by ApplyBoostPreserveColorFromPrecomputedParams to re-encode
// the boosted PQ output without serialising the per-channel work.
float3 LinearToPQBT2100(float3 v)
{
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float3 Lm1 = pow(saturate(v), m1);
    float3 num = c1 + c2 * Lm1;
    float3 den = 1.0 + c3 * Lm1;
    return pow(num / max(den, 1e-6), m2);
}

// Scalar version of PQ EOTF — avoids float3 construction overhead in scalar-only contexts.
float PQToLinearScalar(float v)
{
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float vp = pow(saturate(v), 1.0 / m2);
    float num = max(vp - c1, 0.0);
    float den = c2 - c3 * vp;
    return pow(num / max(den, 1e-6), 1.0 / m1);
}

float NitsToPQ(float nits)
{
    return LinearToPQBT2100(saturate(nits / 10000.0));
}

// NitsToPQ(0.0) = LinearToPQBT2100(0.0) = c1^m2 — pure compile-time constant.
// Replaces two NitsToPQ(0.0) calls per ComputeBT2390ReferenceOutputNits invocation.
static const float PQ_BLACK = 7.309559025783966e-07;

// BT.2390 highlight rolloff in PQ space.
// This follows the Report ITU-R BT.2390 EETF construction when shapeControl = 1.0.
// For other values we keep the same normalized source/target endpoints, then move the
// knee and rebuild the shoulder with a monotonic power form that preserves a slope of 1
// where the rolloff begins and a slope of 0 at the peak. This avoids the S-shaped bend
// that appears when only the Hermite parameterization is warped.
float ComputeBT2390ShapedKneeStart(float maxLum, float shapeControl)
{
    float standardKneeStart = saturate(1.5 * maxLum - 0.5);

    // Standard BT.2390 fast path: avoid log2() and extra shaping math when the control
    // is effectively at its neutral value.
    if (abs(shapeControl - 1.0) <= 1e-4)
        return standardKneeStart;

    float safeShapeControl = max(shapeControl, 1e-4);
    float shapeBias = log2(safeShapeControl);

    if (shapeBias > 0.0)
    {
        float hardT = saturate(shapeBias * 0.5);
        float aggressiveKneeStart = standardKneeStart * 0.15;
        return saturate(lerp(standardKneeStart, aggressiveKneeStart, hardT));
    }

    if (shapeBias < 0.0)
    {
        float softT = saturate(-shapeBias * 0.5);
        float softerKneeStart = standardKneeStart + (maxLum - standardKneeStart) * 0.85;
        return min(lerp(standardKneeStart, softerKneeStart, softT), maxLum - 1e-6);
    }

    return standardKneeStart;
}

float ApplyBT2390EETFToPQWithShape(float inputPQ, float sourcePeakNits, float targetPeakNits, float shapeControl)
{
    float safeSourcePeakNits = max(sourcePeakNits, 1e-4);
    float safeTargetPeakNits = max(targetPeakNits, 0.0);

    if (safeTargetPeakNits <= 0.0)
        return PQ_BLACK;

    if (safeTargetPeakNits >= safeSourcePeakNits - 1e-4)
        return saturate(inputPQ);

    float sourceBlackPQ = PQ_BLACK;
    float sourceWhitePQ = max(NitsToPQ(safeSourcePeakNits), sourceBlackPQ + 1e-6);
    float targetWhitePQ = min(NitsToPQ(safeTargetPeakNits), sourceWhitePQ - 1e-6);

    float pqRange = max(sourceWhitePQ - sourceBlackPQ, 1e-6);
    float e1 = saturate((saturate(inputPQ) - sourceBlackPQ) / pqRange);
    float maxLum = saturate((targetWhitePQ - sourceBlackPQ) / pqRange);

    if (maxLum >= 1.0 - 1e-6)
        return saturate(inputPQ);

    float kneeStart = ComputeBT2390ShapedKneeStart(maxLum, shapeControl);
    float e2 = e1;

    if (e1 >= kneeStart)
    {
        float shoulderSpan = max(1.0 - kneeStart, 1e-6);
        float compressionSpan = max(maxLum - kneeStart, 1e-6);
        float u = saturate((e1 - kneeStart) / shoulderSpan);
        float shoulderPower = max(shoulderSpan / compressionSpan, 1.0);

        e2 = kneeStart + compressionSpan * (1.0 - pow(1.0 - u, shoulderPower));
    }

    // In this shader the source and target black levels are both PQ black, so the BT.2390
    // black-lift tail stage is mathematically a no-op and can be skipped.
    return saturate(e2 * pqRange + sourceBlackPQ);
}

float ApplyBT2390EETFToNitsWithShape(float inputNits, float sourcePeakNits, float targetPeakNits, float shapeExponent)
{
    float safeInputNits = max(inputNits, 0.0);
    float outputPQ = ApplyBT2390EETFToPQWithShape(NitsToPQ(safeInputNits), sourcePeakNits, targetPeakNits, shapeExponent);
    return max(PQToLinearScalar(outputPQ) * 10000.0, 0.0);
}

float ApplyBT2390EETFToNits(float inputNits, float sourcePeakNits, float targetPeakNits)
{
    return ApplyBT2390EETFToNitsWithShape(inputNits, sourcePeakNits, targetPeakNits, 1.0);
}

float GetSceneNitsFromColor(float3 color)
{
    if (APLInputMode == 1)
    {
        float3 linearPQ = PQToLinearBT2100(color);
        return GetLuma2020(linearPQ) * 10000.0;
    }

    return GetLuma709(max(color, 0.0.xxx)) * SIGNAL_REFERENCE_NITS;
}

float GetDigit(int digit, float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    int patterns[10] = { 31599, 9362, 29671, 29391, 23497, 31183, 31215, 29257, 31727, 31695 };
    int num = patterns[clamp(digit, 0, 9)];
    int x = int(uv.x * 3.0);
    int y = int((1.0 - uv.y) * 5.0);

    return (num >> (x + y * 3)) & 1;
}

float GetPercent(float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    float2 d0 = uv - float2(0.3, 0.25);
    float2 d1 = uv - float2(0.7, 0.75);
    bool slash = abs(uv.x - (1.0 - uv.y)) < 0.15;
    bool circles = (dot(d0, d0) < 0.04) || (dot(d1, d1) < 0.04);

    return (slash || circles) ? 1.0 : 0.0;
}

float GetDot(float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    float y = 1.0 - uv.y;
    return (uv.x > 0.35 && uv.x < 0.65 && y > 0.00 && y < 0.20) ? 1.0 : 0.0;
}

float Remap01(float x, float a, float b)
{
    return saturate((x - a) / max(b - a, 1e-6));
}

float SmootherStep01(float x)
{
    x = saturate(x);
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

float SegmentLerp(float x, float x0, float y0, float x1, float y1)
{
    return lerp(y0, y1, Remap01(x, x0, x1));
}

static const int APL_COUNT = 10;
static const int NIT_COUNT = 24;

static const float APL_POINTS[APL_COUNT] =
{
    3.000000, 5.000000, 7.000000, 10.000000, 14.000000, 18.000000, 22.000000, 25.000000, 35.000000, 50.000000
};

static const float NIT_POINTS[NIT_COUNT] =
{
    3.575635, 5.171928, 7.225205, 10.050671, 13.609937, 18.423039, 24.669117, 32.378420, 42.624646, 55.159547, 71.694443, 92.698470, 118.169439, 151.523348, 191.827692, 244.458256, 307.922168, 390.672851, 494.833309, 620.319592, 783.927695, 981.175502, 1238.660348, 1350.000000
};

// Original 2D table collapsed to one representative compensation value per APL row.
// These anchors are taken near 109 nits, which tracks the row average very closely
// while preserving the stronger APL dependence that matters most.
static const float COMP_APL_1D[APL_COUNT] =
{
    1.000000, // APL 3
    1.485507, // APL 5
    1.937592, // APL 7
    2.726513, // APL 10
    2.975849, // APL 14
    3.159946, // APL 18
    3.315940, // APL 22
    3.417932, // APL 25
    3.685460, // APL 35
    3.992070  // APL 50
};

static const float COMP_MIN = 1.0;
static const float COMP_MAX = 3.992070;

int FindAPLIndex(float aplPct)
{
    // Branchless: all APL_COUNT-1 comparisons are independent and emit in parallel.
    // [loop]+branch forces a serial dependency chain; [unroll]+step() removes it.
    int idx = 0;
    [unroll]
    for (int i = 0; i < APL_COUNT - 1; ++i)
        idx += int(step(APL_POINTS[i + 1], aplPct));
    return min(idx, APL_COUNT - 2);
}

float ApplyCompensationFreezeAPL(float aplPct)
{
    float freezeAPL = CompensationFreezeAPLPercent;
    if (freezeAPL > 0.0)
        aplPct = min(aplPct, freezeAPL);

    return aplPct;
}

float LookupMeasuredComp1D(float aplPct)
{
    float lookupAPL = ApplyCompensationFreezeAPL(aplPct);
    float clampedAPL = clamp(lookupAPL, APL_POINTS[0], APL_POINTS[APL_COUNT - 1]);
    int a0 = FindAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        APL_POINTS[a0], COMP_APL_1D[a0],
        APL_POINTS[a1], COMP_APL_1D[a1]
    );
}

float GetPerAPLBoostStrengthAtIndex(int idx)
{
    if (idx == 0) return APLBoostStrength03;
    if (idx == 1) return APLBoostStrength05;
    if (idx == 2) return APLBoostStrength07;
    if (idx == 3) return APLBoostStrength10;
    if (idx == 4) return APLBoostStrength14;
    if (idx == 5) return APLBoostStrength18;
    if (idx == 6) return APLBoostStrength22;
    if (idx == 7) return APLBoostStrength25;
    if (idx == 8) return APLBoostStrength35;
    return APLBoostStrength50;
}

float LookupPerAPLBoostStrength(float aplPct)
{
    if (!EnablePerAPLBoostStrength)
        return MaxAPLBoostStrength;

    float clampedAPL = clamp(aplPct, APL_POINTS[0], APL_POINTS[APL_COUNT - 1]);
    int a0 = FindAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        APL_POINTS[a0], GetPerAPLBoostStrengthAtIndex(a0),
        APL_POINTS[a1], GetPerAPLBoostStrengthAtIndex(a1)
    );
}

// LUT shapes the scene-compensation weight only. Final response is a nits-domain gain.
float ComputeAPLBoostFader(float currentAPL)
{
    return step(APLTrigger, currentAPL);
}

float ComputeTemporalBlendFactor(float smoothingSeconds)
{
    if (smoothingSeconds <= 1e-6)
        return 1.0;

    float dtSeconds = max(FrameTime, 0.0) * 0.001;
    return saturate(1.0 - exp(-dtSeconds / max(smoothingSeconds, 1e-6)));
}


float ComputeHighAPLMetricSampleWeight(float sampleNits)
{
    float minNits = max(HighAPLMetricMinNits, 0.0);
    float maxNits = max(HighAPLMetricMaxNits, minNits + 1e-4);
    return saturate((sampleNits - minNits) / (maxNits - minNits));
}

float ComputeHighAPLReductionWeight(float highAPLMetric)
{
    float startMetric = saturate(HighAPLReductionStartPercent * 0.01);
    float endMetric = max(HighAPLReductionEndPercent * 0.01, startMetric + 1e-4);
    return Remap01(highAPLMetric, startMetric, endMetric);
}

float ComputeAdaptiveBoostStrength(float baseStrength, float highAPLMetric)
{
    if (!EnableHighAPLAdaptiveBoost)
        return baseStrength;

    float adaptiveMaxStrength = max(HighAPLAdaptiveMaxBoostStrength, baseStrength);
    float reductionWeight = ComputeHighAPLReductionWeight(highAPLMetric);
    return lerp(adaptiveMaxStrength, baseStrength, reductionWeight);
}

float ComputeSceneFinalBoostStrength(float currentAPL, float highAPLMetric)
{
    float fader = ComputeAPLBoostFader(currentAPL);
    float aplPct = saturate(currentAPL) * 100.0;
    float baseStrength = LookupPerAPLBoostStrength(aplPct);
    float boostStrength = ComputeAdaptiveBoostStrength(baseStrength, highAPLMetric);
    return max(boostStrength * fader, 0.0);
}


// Precomputed participation ramp constants.
// PixelParticipationStartNits = 1.0 → log2(1.0) = 0.0
// PixelParticipationFullNits  = 40.0 → log2(40.0) ≈ 5.32193
// PixelParticipationGamma     = 1.0 → pow(t, 1.0) = t (identity, no pow needed)
static const float _PP_LOG_START     = 0.0;
static const float _PP_LOG_FULL      = 5.321928094887362;   // log2(40.0)
static const float _PP_LOG_RANGE_INV = 0.18796897749577098; // 1.0 / (log2(40.0) - 0.0)

float ComputePixelParticipationWeight(float inputNits)
{
    float t = saturate((log2(max(inputNits, 1e-4)) - _PP_LOG_START) * _PP_LOG_RANGE_INV);
    return SmootherStep01(t);
    // PixelParticipationGamma == 1.0 → pow(t, 1.0) == t; omitted.
}

float ComputePixelParticipation(float inputNits)
{
    float floorShare = saturate(PixelParticipationFloor);

    if (floorShare >= 0.9999)
        return 1.0;

    float w_pix = ComputePixelParticipationWeight(inputNits);
    return lerp(floorShare, 1.0, w_pix);
}

float ComputePixelGainFromSceneLogGain(float sceneLogGain, float inputNits)
{
    return exp2(sceneLogGain * ComputePixelParticipation(inputNits));
}



float ComputeSceneGainExponentFromMeasuredComp(float measuredComp, float currentAPL, float highAPLMetric)
{
    return ComputeSceneFinalBoostStrength(currentAPL, highAPLMetric);
}

float ComputeSceneGainExponentFromMeasuredComp(float measuredComp, float currentAPL)
{
    return ComputeSceneGainExponentFromMeasuredComp(measuredComp, currentAPL, 0.0);
}

float ComputeSceneLogGainFromMeasuredComp(float measuredComp, float currentAPL, float highAPLMetric)
{
    float safeMeasuredComp = max(measuredComp, 1.0);
    float gainExponent = ComputeSceneGainExponentFromMeasuredComp(safeMeasuredComp, currentAPL, highAPLMetric);
    return log2(safeMeasuredComp) * gainExponent;
}

float ComputeSceneLogGainFromMeasuredComp(float measuredComp, float currentAPL)
{
    return ComputeSceneLogGainFromMeasuredComp(measuredComp, currentAPL, 0.0);
}

float ComputeSceneLogGainFromAPL(float currentAPL, float highAPLMetric)
{
    float aplPct = saturate(currentAPL) * 100.0;
    float measuredComp = max(LookupMeasuredComp1D(aplPct), 1.0);
    return ComputeSceneLogGainFromMeasuredComp(measuredComp, currentAPL, highAPLMetric);
}

float ComputeSceneLogGainFromAPL(float currentAPL)
{
    return ComputeSceneLogGainFromAPL(currentAPL, 0.0);
}

float EstimateAverageParticipationFromRawAPL(float rawAPL)
{
    float meanSceneNits = saturate(rawAPL) * max(APLReferenceWhiteNits, 1.0);
    return ComputePixelParticipation(max(meanSceneNits, 0.0));
}

float SolveClosedLoopDisplayAPLFromRaw(float rawAPL, float highAPLMetric)
{
    float safeRawAPL = saturate(rawAPL);

    if (safeRawAPL <= 1e-6)
        return 0.0;

    float avgParticipation = EstimateAverageParticipationFromRawAPL(safeRawAPL);
    float displayAPL = safeRawAPL;

    [unroll]
    for (int i = 0; i < 3; ++i)
    {
        float sceneLogGain = ComputeSceneLogGainFromAPL(displayAPL, highAPLMetric);
        float estimatedDisplayAPL = saturate(safeRawAPL * exp2(sceneLogGain * avgParticipation));

        // Mild damping keeps the closed-loop estimate stable with very short smoothing times.
        displayAPL = lerp(displayAPL, estimatedDisplayAPL, 0.85);
    }

    return displayAPL;
}

float SolveClosedLoopDisplayAPLFromRaw(float rawAPL)
{
    return SolveClosedLoopDisplayAPLFromRaw(rawAPL, 0.0);
}

float ComputeGraphClosedLoopAPLFromRawPercent(float rawAPLPercent)
{
    float rawAPL = saturate(rawAPLPercent * 0.01);
    return SolveClosedLoopDisplayAPLFromRaw(rawAPL);
}

float ComputeSceneGainNoRolloff(float currentAPL, float highAPLMetric)
{
    float aplPct = saturate(currentAPL) * 100.0;
    float measuredComp = max(LookupMeasuredComp1D(aplPct), 1.0);
    float sceneLogGain = ComputeSceneLogGainFromMeasuredComp(measuredComp, currentAPL, highAPLMetric);
    return exp2(sceneLogGain);
}

float ComputeSceneGainNoRolloff(float currentAPL)
{
    return ComputeSceneGainNoRolloff(currentAPL, 0.0);
}

float ComputePixelGainNoRolloff(float currentAPL, float inputNits, float highAPLMetric)
{
    float sceneGain = max(ComputeSceneGainNoRolloff(currentAPL, highAPLMetric), 1.0);
    float participation = ComputePixelParticipation(inputNits);

    // Hybrid participation keeps some global compensation on all pixels, while
    // brighter pixels smoothly receive the remaining share.
    return exp2(log2(sceneGain) * participation);
}

float ComputePixelGainNoRolloff(float currentAPL, float inputNits)
{
    return ComputePixelGainNoRolloff(currentAPL, inputNits, 0.0);
}

float SignalLumaToNits(float signalLuma)
{
    if (APLInputMode == 1)
        return max(PQToLinearScalar(signalLuma) * 10000.0, 0.0);

    return max(signalLuma, 0.0) * SIGNAL_REFERENCE_NITS;
}

float NitsToSignalLuma(float nits)
{
    if (APLInputMode == 1)
        return NitsToPQ(max(nits, 0.0));

    return max(nits, 0.0) / SIGNAL_REFERENCE_NITS;
}

float ComputeBoostedTargetNitsFromBoostTNoRolloff(float currentAPL, float inputNits, float highAPLMetric)
{
    float safeInputNits = max(inputNits, 0.0);
    float pixelGain = ComputePixelGainNoRolloff(currentAPL, safeInputNits, highAPLMetric);

    return safeInputNits * pixelGain;
}

float ComputeBoostedTargetNitsFromBoostTNoRolloff(float currentAPL, float inputNits)
{
    return ComputeBoostedTargetNitsFromBoostTNoRolloff(currentAPL, inputNits, 0.0);
}


float ComputeRollOffAnchorBoostedNitsFromSceneLogGain(float sceneLogGain)
{
    float rollOffEndNits = max(BoostRollOff, 0.0);

    if (rollOffEndNits <= 0.0)
        return 0.0;

    float referenceInputNits = max(rollOffEndNits, 1e-4);
    return referenceInputNits * ComputePixelGainFromSceneLogGain(sceneLogGain, referenceInputNits);
}

float ComputeRollOffAnchorBoostedNits(float currentAPL, float highAPLMetric)
{
    float sceneLogGain = ComputeSceneLogGainFromAPL(currentAPL, highAPLMetric);
    return ComputeRollOffAnchorBoostedNitsFromSceneLogGain(sceneLogGain);
}

float ComputeRollOffAnchorBoostedNits(float currentAPL)
{
    return ComputeRollOffAnchorBoostedNits(currentAPL, 0.0);
}

// Precompute all scene-uniform BT.2390 rolloff setup in a 1x1 pass.
// The fullscreen pass still computes the pixel-dependent NitsToPQ/PQToNits work,
// but no longer recomputes source/target white, knee placement, or anchor per pixel.
float4 ComputeBoostRolloffParamsFromSceneLogGain(float sceneLogGain)
{
    float fullParticipationSceneGain = exp2(sceneLogGain);
    float rollOffEndNits = max(BoostRollOff, 0.0);
    float anchorBoostedNits = ComputeRollOffAnchorBoostedNitsFromSceneLogGain(sceneLogGain);

    if (rollOffEndNits <= 0.0)
        return float4(fullParticipationSceneGain, 0.0, 1.0, 0.0);

    float sourcePeakNits = max(anchorBoostedNits, rollOffEndNits + 1e-4);
    float sourceWhitePQ = max(NitsToPQ(sourcePeakNits), PQ_BLACK + 1e-6);
    float targetWhitePQ = min(NitsToPQ(rollOffEndNits), sourceWhitePQ - 1e-6);

    float pqRange = max(sourceWhitePQ - PQ_BLACK, 1e-6);
    float maxLum = saturate((targetWhitePQ - PQ_BLACK) / pqRange);

    if (maxLum >= 1.0 - 1e-6)
        return float4(fullParticipationSceneGain, 0.0, 1.0, 0.0);

    float kneeStart = ComputeBT2390ShapedKneeStart(maxLum, BoostRollOffShape);
    float compressionSpan = max(maxLum - kneeStart, 1e-6);

    return float4(fullParticipationSceneGain, pqRange, kneeStart, compressionSpan);
}

float ComputePixelGainFromPrecomputedParams(float sceneLogGain, float inputNits, float4 boostParams)
{
    // Default PixelParticipationFloor is 1.0, so the pixel gain is scene-uniform.
    // Read the precomputed full-participation gain instead of paying exp2() per pixel.
    if (saturate(PixelParticipationFloor) >= 0.9999)
        return max(boostParams.r, 0.0);

    return ComputePixelGainFromSceneLogGain(sceneLogGain, inputNits);
}

float ApplyBT2390EETFToPQWithPrecomputedParams(float inputPQ, float4 boostParams)
{
    float pqRange = boostParams.g;

    if (pqRange <= 0.0)
        return saturate(inputPQ);

    float kneeStart = saturate(boostParams.b);
    float compressionSpan = max(boostParams.a, 1e-6);

    float e1 = saturate((saturate(inputPQ) - PQ_BLACK) / pqRange);
    float e2 = e1;

    if (e1 >= kneeStart)
    {
        float shoulderSpan = max(1.0 - kneeStart, 1e-6);
        float u = saturate((e1 - kneeStart) / shoulderSpan);
        float shoulderPower = max(shoulderSpan / compressionSpan, 1.0);

        e2 = kneeStart + compressionSpan * (1.0 - pow(1.0 - u, shoulderPower));
    }

    return saturate(e2 * pqRange + PQ_BLACK);
}

float ApplyBT2390EETFToNitsWithPrecomputedParams(float inputNits, float4 boostParams)
{
    float safeInputNits = max(inputNits, 0.0);

    if (boostParams.g <= 0.0)
        return safeInputNits;

    float outputPQ = ApplyBT2390EETFToPQWithPrecomputedParams(NitsToPQ(safeInputNits), boostParams);
    return max(PQToLinearScalar(outputPQ) * 10000.0, 0.0);
}

float ApplyBoostWithBT2390Rolloff(float signalLuma, float currentAPL, float anchorBoostedNits)
{
    float originalNits = SignalLumaToNits(signalLuma);
    float fullyBoostedNits = ComputeBoostedTargetNitsFromBoostTNoRolloff(currentAPL, originalNits);
    float rollOffEndNits = max(BoostRollOff, 0.0);

    if (rollOffEndNits <= 0.0)
        return NitsToSignalLuma(fullyBoostedNits);

    float sourcePeakNits = max(anchorBoostedNits, rollOffEndNits + 1e-4);
    float rolledNits = max(ApplyBT2390EETFToNitsWithShape(fullyBoostedNits, sourcePeakNits, rollOffEndNits, BoostRollOffShape), originalNits);

    return NitsToSignalLuma(rolledNits);
}

float ApplyBoostWithSelectedRolloff(float signalLuma, float currentAPL, float anchorBoostedNits)
{
    return ApplyBoostWithBT2390Rolloff(signalLuma, currentAPL, anchorBoostedNits);
}

float ComputeBoostedLumaNitsFromPrecomputedParams(float inputLumaNits, float sceneLogGain, float4 boostParams)
{
    float safeInputLumaNits = max(inputLumaNits, 0.0);
    float fullyBoostedNits = safeInputLumaNits * ComputePixelGainFromPrecomputedParams(sceneLogGain, safeInputLumaNits, boostParams);

    if (boostParams.g <= 0.0)
        return fullyBoostedNits;

    return max(ApplyBT2390EETFToNitsWithPrecomputedParams(fullyBoostedNits, boostParams), safeInputLumaNits);
}

float3 ApplySaturationAdjustment709(float3 linearColor, float saturation)
{
    float luma = GetLuma709(linearColor);
    return luma.xxx + (linearColor - luma.xxx) * saturation;
}

float3 ApplySaturationAdjustment2020Nits(float3 linearColorNits, float saturation)
{
    float lumaNits = GetLuma2020(linearColorNits);
    return lumaNits.xxx + (linearColorNits - lumaNits.xxx) * saturation;
}

float Max3(float3 v)
{
    return max(max(v.r, v.g), v.b);
}

float ComputeMaxHuePreservingScale(float3 rgb, float channelLimit)
{
    float maxChannel = Max3(rgb);

    if (maxChannel <= 1e-6)
        return 1.0;

    return max(channelLimit / maxChannel, 0.0);
}

float SoftLimitBoostScale(float desiredScale, float maxScale, float kneeFraction)
{
    // This limiter operates only on added boost. It never returns below 1.0,
    // so source pixels are not darkened when they already have no channel headroom.
    float safeDesired = max(desiredScale, 1.0);
    float safeMax = max(maxScale, 1.0);

    if (safeDesired <= 1.0 || safeMax <= 1.0 + 1e-6)
        return 1.0;

    float kneeStart = lerp(1.0, safeMax, saturate(kneeFraction));

    if (safeDesired <= kneeStart)
        return safeDesired;

    float span = max(safeMax - kneeStart, 1e-6);
    float x = (safeDesired - kneeStart) / span;

    return min(kneeStart + span * (x / (1.0 + x)), safeMax);
}

float3 ApplyBoostPreserveColorFromPrecomputedParams(float3 color, float sceneLogGain, float4 boostParams)
{
    if (APLInputMode == 1)
    {
        float3 linearColorNits = PQToLinearBT2100(saturate(color)) * 10000.0;
        float originalLumaNits = max(GetLuma2020(linearColorNits), 0.0);

        if (originalLumaNits <= 1e-6)
            return color;

        float boostedLumaNits = ComputeBoostedLumaNitsFromPrecomputedParams(originalLumaNits, sceneLogGain, boostParams);
        float colorScale = boostedLumaNits / originalLumaNits;

        if (EnableColorPreservingBoostMode)
        {
            float outputChannelLimitNits = clamp(BoostRollOff, 1.0, 10000.0);
            float maxHuePreservingScale = ComputeMaxHuePreservingScale(linearColorNits, outputChannelLimitNits);
            colorScale = SoftLimitBoostScale(colorScale, maxHuePreservingScale, COLOR_PRESERVING_BOOST_KNEE);
        }

        float3 boostedColorNits = linearColorNits * colorScale;
        float3 saturatedColorNits = ApplySaturationAdjustment2020Nits(boostedColorNits, SaturationComp);

        return LinearToPQBT2100(saturate(max(saturatedColorNits, 0.0) / 10000.0));
    }

    float3 linearColor = color;
    float originalLumaNits = max(GetLuma709(max(linearColor, 0.0.xxx)) * SIGNAL_REFERENCE_NITS, 0.0);

    if (originalLumaNits <= 1e-6)
        return color;

    float boostedLumaNits = ComputeBoostedLumaNitsFromPrecomputedParams(originalLumaNits, sceneLogGain, boostParams);
    float colorScale = boostedLumaNits / originalLumaNits;

    if (EnableColorPreservingBoostMode)
    {
        float outputChannelLimit = clamp(BoostRollOff, 1.0, 10000.0) / max(SIGNAL_REFERENCE_NITS, 1.0);
        float maxHuePreservingScale = ComputeMaxHuePreservingScale(max(linearColor, 0.0.xxx), outputChannelLimit);
        colorScale = SoftLimitBoostScale(colorScale, maxHuePreservingScale, COLOR_PRESERVING_BOOST_KNEE);
    }

    float3 boostedColor = linearColor * colorScale;

    return ApplySaturationAdjustment709(boostedColor, SaturationComp);
}

float ComputeBoostedTargetNitsFromBoostT(float currentAPL, float inputNits, float anchorBoostedNits)
{
    float safeInputNits = max(inputNits, 0.0);
    float signalLuma = NitsToSignalLuma(safeInputNits);

    return SignalLumaToNits(ApplyBoostWithSelectedRolloff(signalLuma, currentAPL, anchorBoostedNits));
}




#if ENABLE_APL_GRAPH
// Restored graph-only 2D measurement table from the original shader.
// Live boost logic stays on the simplified 1D LUT path.
static const float GRAPH_COMP_TABLE_2D[APL_COUNT * NIT_COUNT] =
{
    // APL 3
    1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000,
    1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000,
    1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000,

    // APL 5
    1.720651, 1.686332, 1.639477, 1.600348, 1.600708, 1.577878, 1.542435, 1.511557,
    1.503835, 1.502406, 1.495001, 1.485507, 1.483857, 1.489657, 1.482153, 1.468116,
    1.448344, 1.444867, 1.450962, 1.452448, 1.469464, 1.456834, 1.451324, 1.453880,

    // APL 7
    2.386696, 2.301803, 2.208239, 2.142507, 2.140282, 2.077152, 2.038432, 1.991094,
    1.993522, 1.968427, 1.989762, 1.937592, 1.929698, 1.925020, 1.945632, 1.946108,
    1.925587, 1.902872, 1.901151, 1.913164, 1.899819, 1.886626, 1.878231, 1.890897,

    // APL 10
    3.533441, 3.322778, 3.150550, 2.996933, 2.991533, 2.952331, 2.859779, 2.786477,
    2.785140, 2.774786, 2.729192, 2.726513, 2.677344, 2.659034, 2.670534, 2.664711,
    2.656535, 2.635426, 2.617849, 2.644629, 2.608929, 2.597025, 2.623546, 2.643980,

    // APL 14
    3.944622, 3.742778, 3.486730, 3.316180, 3.278714, 3.241277, 3.170756, 3.107104,
    3.048998, 3.033891, 3.007011, 2.975850, 2.967055, 2.930338, 2.894044, 2.877144,
    2.871816, 2.870981, 2.843950, 2.836061, 2.828960, 2.824714, 2.810953, 2.860440,

    // APL 18
    4.331250, 4.026790, 3.777349, 3.558558, 3.507555, 3.442118, 3.384474, 3.305192,
    3.244043, 3.216516, 3.186545, 3.159946, 3.136808, 3.105590, 3.059186, 3.035061,
    3.029201, 3.033312, 3.008409, 2.994243, 2.975847, 2.974065, 2.964559, 3.025595,

    // APL 22
    4.643759, 4.306869, 4.014115, 3.780358, 3.693690, 3.622282, 3.573737, 3.487421,
    3.425357, 3.371692, 3.345787, 3.315940, 3.279914, 3.244380, 3.207378, 3.189466,
    3.174613, 3.166520, 3.153845, 3.131529, 3.105266, 3.106722, 3.107669, 3.162626,

    // APL 25
    4.890135, 4.476783, 4.184533, 3.925642, 3.853435, 3.752898, 3.701382, 3.611937,
    3.544263, 3.498814, 3.460554, 3.417932, 3.379274, 3.360057, 3.310112, 3.291375,
    3.265695, 3.262604, 3.242291, 3.225440, 3.203959, 3.197273, 3.200682, 3.262033,

    // APL 35
    5.417324, 5.035198, 4.643715, 4.309623, 4.221975, 4.075571, 4.022938, 3.914059,
    3.842109, 3.779826, 3.737622, 3.685461, 3.643943, 3.617834, 3.570377, 3.528255,
    3.503582, 3.500313, 3.490984, 3.471195, 3.427937, 3.423172, 3.433216, 3.502432,

    // APL 50
    6.329473, 5.782274, 5.253617, 4.820496, 4.677353, 4.489843, 4.406326, 4.286695,
    4.203659, 4.119237, 4.061790, 3.992070, 3.953981, 3.914708, 3.851887, 3.803306,
    3.757446, 3.752999, 3.753410, 3.726083, 3.677635, 3.661738, 3.674132, 3.769405,
};


static const int FULLFIELD_100_COUNT = 33;

static const float FULLFIELD_100_INPUT_NITS[FULLFIELD_100_COUNT] =
{
    0.000000, 0.014036, 0.059603, 0.157591, 0.322069, 0.595511, 0.992458, 1.592344,
    2.444660, 3.575635, 5.171928, 7.225205, 10.050671, 13.609937, 18.423039, 24.669117,
    32.378420, 42.624646, 55.159547, 71.694443, 92.698470, 118.169439, 151.523348, 191.827692,
    244.458256, 307.922168, 390.672851, 494.833309, 620.319592, 783.927695, 981.175502, 1238.660348,
    1350.000000
};

static const float FULLFIELD_100_MEASURED_NITS[FULLFIELD_100_COUNT] =
{
    0.000000, 0.014648, 0.088214, 0.193289, 0.318997, 0.661295, 0.989292, 1.447618,
    2.236296, 3.376542, 4.920436, 6.930280, 9.705878, 13.055362, 17.754820, 23.893304,
    31.387134, 40.600344, 45.011469, 47.620761, 50.368808, 52.891721, 56.604813, 68.190830,
    82.588125, 98.494626, 118.746210, 143.304828, 172.126608, 209.385482, 251.637523, 297.368081,
    309.321642
};


static const int FULLFIELD_50_COUNT = 33;

static const float FULLFIELD_50_MEASURED_NITS[FULLFIELD_50_COUNT] =
{
    0.000000, 0.015862, 0.091231, 0.191387, 0.312262, 0.671993, 1.005095, 1.466901,
    2.286369, 3.449248, 5.001989, 7.038000, 9.801644, 13.156916, 17.924338, 24.163637,
    31.789419, 41.683506, 53.627316, 69.185620, 84.080554, 92.334532, 96.520524, 101.008793,
    104.432241, 114.183568, 137.227399, 166.211743, 199.071008, 240.682466, 287.937407, 345.551770,
    363.939963
};

static const int FULLFIELD_25_COUNT = 33;

static const float FULLFIELD_25_MEASURED_NITS[FULLFIELD_25_COUNT] =
{
    0.000000, 0.017065, 0.092684, 0.188695, 0.316532, 0.675762, 1.014760, 1.479035,
    2.288388, 3.459781, 4.990658, 7.024088, 9.770902, 13.179701, 17.913331, 24.091540,
    31.696396, 41.565991, 53.429244, 68.944165, 88.666517, 112.012512, 143.437406, 170.146931,
    184.837337, 192.847953, 201.161006, 207.413333, 229.887560, 275.787536, 329.782519, 395.968809,
    415.892980
};

static const int FULLFIELD_15_COUNT = 33;

static const float FULLFIELD_15_MEASURED_NITS[FULLFIELD_15_COUNT] =
{
    0.000000, 0.016253, 0.094834, 0.187706, 0.317148, 0.676951, 1.015021, 1.479980,
    2.287189, 3.448004, 4.994607, 7.041970, 9.784785, 13.150748, 17.905736, 24.049399,
    31.633274, 41.473215, 53.281468, 69.049461, 88.784032, 112.346140, 143.356248, 182.754138,
    234.099656, 278.571999, 300.521740, 315.031157, 328.402913, 344.764374, 366.215873, 440.577317,
    462.133337
};

static const int FULLFIELD_10_COUNT = 33;

static const float FULLFIELD_10_MEASURED_NITS[FULLFIELD_10_COUNT] =
{
    0.000000, 0.015782, 0.096480, 0.189964, 0.315951, 0.677001, 1.013099, 1.478316,
    2.295147, 3.465727, 5.010710, 7.056289, 9.789478, 13.159489, 17.861715, 24.058224,
    31.705232, 41.587231, 53.534239, 69.184716, 88.953048, 112.100670, 143.263472, 182.691020,
    234.475162, 294.818124, 372.854232, 426.292189, 459.043502, 483.394124, 503.668346, 517.617448,
    513.378666
};


static const int GRAPH_WINDOW_MODE_100 = 0;
static const int GRAPH_WINDOW_MODE_50  = 1;
static const int GRAPH_WINDOW_MODE_25  = 2;
static const int GRAPH_WINDOW_MODE_15  = 3;
static const int GRAPH_WINDOW_MODE_10  = 4;

int FindFullFieldWindowInputIndex(float inputNits)
{
    [loop]
    for (int i = 0; i < FULLFIELD_100_COUNT - 1; ++i)
    {
        if (inputNits < FULLFIELD_100_INPUT_NITS[i + 1])
            return i;
    }

    return FULLFIELD_100_COUNT - 2;
}

int GetFullFieldWindowCountByMode(int mode)
{
    switch (mode)
    {
        case GRAPH_WINDOW_MODE_10: return FULLFIELD_10_COUNT;
        case GRAPH_WINDOW_MODE_15: return FULLFIELD_15_COUNT;
        case GRAPH_WINDOW_MODE_25: return FULLFIELD_25_COUNT;
        case GRAPH_WINDOW_MODE_50: return FULLFIELD_50_COUNT;
        default:                   return FULLFIELD_100_COUNT;
    }
}

float GetFullFieldWindowScaleByMode(int mode)
{
    switch (mode)
    {
        case GRAPH_WINDOW_MODE_10: return 0.10;
        case GRAPH_WINDOW_MODE_15: return 0.15;
        case GRAPH_WINDOW_MODE_25: return 0.25;
        case GRAPH_WINDOW_MODE_50: return 0.50;
        default:                   return 1.00;
    }
}

float GetFullFieldMeasuredNitsByModeAndIndex(int mode, int idx)
{
    switch (mode)
    {
        case GRAPH_WINDOW_MODE_10: return FULLFIELD_10_MEASURED_NITS[idx];
        case GRAPH_WINDOW_MODE_15: return FULLFIELD_15_MEASURED_NITS[idx];
        case GRAPH_WINDOW_MODE_25: return FULLFIELD_25_MEASURED_NITS[idx];
        case GRAPH_WINDOW_MODE_50: return FULLFIELD_50_MEASURED_NITS[idx];
        default:                   return FULLFIELD_100_MEASURED_NITS[idx];
    }
}

float SampleMeasuredOutputNitsFullFieldByMode(int mode, float targetNits)
{
    float clampedNits = clamp(targetNits, FULLFIELD_100_INPUT_NITS[0], FULLFIELD_100_INPUT_NITS[FULLFIELD_100_COUNT - 1]);
    int i0 = FindFullFieldWindowInputIndex(clampedNits);
    int i1 = min(i0 + 1, GetFullFieldWindowCountByMode(mode) - 1);

    return SegmentLerp(
        clampedNits,
        FULLFIELD_100_INPUT_NITS[i0], GetFullFieldMeasuredNitsByModeAndIndex(mode, i0),
        FULLFIELD_100_INPUT_NITS[i1], GetFullFieldMeasuredNitsByModeAndIndex(mode, i1)
    );
}

float GetFullFieldMeasuredMaxInputNitsByMode(int mode)
{
    return FULLFIELD_100_INPUT_NITS[GetFullFieldWindowCountByMode(mode) - 1];
}

float GetFullFieldMeasuredMaxOutputNitsByMode(int mode)
{
    int last = GetFullFieldWindowCountByMode(mode) - 1;
    return GetFullFieldMeasuredNitsByModeAndIndex(mode, last);
}

float ComputeFullFieldRemappedTargetNitsByMode(int mode, float inputNits)
{
    float safeInputNits = max(inputNits, 0.0);
    float currentAPL = SolveClosedLoopDisplayAPLFromRaw(
        saturate(safeInputNits * GetFullFieldWindowScaleByMode(mode) / max(APLReferenceWhiteNits, 1e-4))
    );
    float anchorBoostedNits = ComputeRollOffAnchorBoostedNits(currentAPL);

    return ComputeBoostedTargetNitsFromBoostT(currentAPL, safeInputNits, anchorBoostedNits);
}

float GraphTableComp2D(int aplIdx, int nitIdx)
{
    return GRAPH_COMP_TABLE_2D[aplIdx * NIT_COUNT + nitIdx];
}

float GetGraphMeasuredMaxInputNits()
{
    return NIT_POINTS[NIT_COUNT - 1];
}

int FindNitIndex(float inputNits)
{
    [loop]
    for (int i = 0; i < NIT_COUNT - 1; ++i)
    {
        if (inputNits < NIT_POINTS[i + 1])
            return i;
    }

    return NIT_COUNT - 2;
}

float LookupGraphCompForAPLRow2D(int aplIdx, float inputNits)
{
    float clampedNits = clamp(inputNits, NIT_POINTS[0], NIT_POINTS[NIT_COUNT - 1]);
    int n0 = FindNitIndex(clampedNits);
    int n1 = min(n0 + 1, NIT_COUNT - 1);

    return SegmentLerp(
        clampedNits,
        NIT_POINTS[n0], GraphTableComp2D(aplIdx, n0),
        NIT_POINTS[n1], GraphTableComp2D(aplIdx, n1)
    );
}

float LookupMeasuredComp2DGraph(float aplPct, float inputNits)
{
    float clampedAPL = clamp(aplPct, APL_POINTS[0], APL_POINTS[APL_COUNT - 1]);
    int a0 = FindAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        APL_POINTS[a0], LookupGraphCompForAPLRow2D(a0, inputNits),
        APL_POINTS[a1], LookupGraphCompForAPLRow2D(a1, inputNits)
    );
}

float SampleRealMeasuredOutputNitsForAPL(float aplPct, float targetNits)
{
    float comp = max(LookupMeasuredComp2DGraph(aplPct, targetNits), 1e-6);
    return targetNits / comp;
}

float ComputeGraphBoostedTargetNits(float aplPct, float inputNits, float anchorBoostedNits)
{
    float currentAPL = saturate(aplPct / 100.0);
    float safeInputNits = max(inputNits, 0.0);

    return ComputeBoostedTargetNitsFromBoostT(currentAPL, safeInputNits, anchorBoostedNits);
}

float GetAPLMaxMeasuredNits(float aplPct)
{
    float maxMeasured = 0.0;

    [loop]
    for (int i = 0; i < NIT_COUNT; ++i)
    {
        float targetNits = NIT_POINTS[i];
        maxMeasured = max(maxMeasured, SampleRealMeasuredOutputNitsForAPL(aplPct, targetNits));
    }

    return maxMeasured;
}

float SampleCorrectedOutputNitsForAPL(float aplPct, float boostedTargetNits, float maxMeasuredNits)
{
    float comp = max(LookupMeasuredComp2DGraph(aplPct, boostedTargetNits), 1e-6);
    return min(boostedTargetNits / comp, maxMeasuredNits);
}


#if ENABLE_APL_GRAPH
float ComputeGraphCurveRemappedTargetNits(bool useFullFieldWindowProjection, int fullFieldWindowMode, float graphClosedLoopAPLPercent, float graphAnchorBoostedNits, float inputNits)
{
    if (useFullFieldWindowProjection)
        return ComputeFullFieldRemappedTargetNitsByMode(fullFieldWindowMode, inputNits);

    return ComputeGraphBoostedTargetNits(graphClosedLoopAPLPercent, inputNits, graphAnchorBoostedNits);
}

float ComputeGraphCurveCorrectedOutputNits(bool useFullFieldWindowProjection, int fullFieldWindowMode, float graphClosedLoopAPLPercent, float graphMaxMeasuredNits, float remappedTargetNits)
{
    if (useFullFieldWindowProjection)
        return SampleMeasuredOutputNitsFullFieldByMode(fullFieldWindowMode, remappedTargetNits);

    return SampleCorrectedOutputNitsForAPL(graphClosedLoopAPLPercent, remappedTargetNits, graphMaxMeasuredNits);
}

float ComputeGraphCurveMeasuredRawOutputNits(bool useFullFieldWindowProjection, int fullFieldWindowMode, float graphRawAPLPercent, float inputNits)
{
    if (useFullFieldWindowProjection)
        return SampleMeasuredOutputNitsFullFieldByMode(fullFieldWindowMode, inputNits);

    return SampleRealMeasuredOutputNitsForAPL(graphRawAPLPercent, inputNits);
}
#endif

float ComputeBT2390ReferenceOutputNits(float inputNits, float sourcePeakNits, float targetPeakNits)
{
    return ApplyBT2390EETFToNits(inputNits, sourcePeakNits, targetPeakNits);
}

float GraphAxisCoordinateWithPQMax(float nits, float axisMaxNits, float axisMaxPQ)
{
    float safeNits = max(nits, 0.0);
    float safeAxisMaxNits = max(axisMaxNits, 1.0);

    if (GraphUsePQSpace)
        return NitsToPQ(safeNits) / max(axisMaxPQ, 1e-6);

    return safeNits / safeAxisMaxNits;
}

float GraphTickValueFromFractionWithPQMax(float frac, float axisMaxNits, float axisMaxPQ)
{
    float safeAxisMaxNits = max(axisMaxNits, 1e-6);
    float safeFrac = saturate(frac);

    if (!GraphUsePQSpace)
        return safeAxisMaxNits * safeFrac;

    float tickPQ = axisMaxPQ * safeFrac;
    return max(PQToLinearScalar(tickPQ) * 10000.0, 0.0);
}

float GraphSampleNitsFromFraction(float frac, float axisMaxNits, float axisMaxPQ)
{
    return GraphTickValueFromFractionWithPQMax(frac, axisMaxNits, axisMaxPQ);
}

float2 ToGraphPointWithPQMax(float2 graphPos, float2 graphSize, float axisMaxNits, float axisMaxPQ, float xNits, float yNits)
{
    float nx = saturate(GraphAxisCoordinateWithPQMax(xNits, axisMaxNits, axisMaxPQ));
    float ny = GraphAxisCoordinateWithPQMax(yNits, axisMaxNits, axisMaxPQ);
    return graphPos + float2(nx * graphSize.x, (1.0 - ny) * graphSize.y);
}

float DistanceToSegment(float2 p, float2 a, float2 b, out float h)
{
    float2 pa = p - a;
    float2 ba = b - a;
    float denom = max(dot(ba, ba), 1e-6);
    h = saturate(dot(pa, ba) / denom);
    return length(pa - ba * h);
}

float DrawGraphLine(float2 p, float2 a, float2 b, float thickness)
{
    float pad = thickness * 2.2;
    float2 bbMin = min(a, b) - pad.xx;
    float2 bbMax = max(a, b) + pad.xx;

    if (p.x < bbMin.x || p.x > bbMax.x || p.y < bbMin.y || p.y > bbMax.y)
        return 0.0;

    float h;
    float d = DistanceToSegment(p, a, b, h);
    return 1.0 - smoothstep(thickness, thickness * 1.8, d);
}

float DrawGraphDashedLine(float2 p, float2 a, float2 b, float thickness, float dashCount)
{
    float pad = thickness * 2.2;
    float2 bbMin = min(a, b) - pad.xx;
    float2 bbMax = max(a, b) + pad.xx;

    if (p.x < bbMin.x || p.x > bbMax.x || p.y < bbMin.y || p.y > bbMax.y)
        return 0.0;

    float h;
    float d = DistanceToSegment(p, a, b, h);
    float lineMask = 1.0 - smoothstep(thickness, thickness * 1.8, d);
    float dashMask = step(frac(h * dashCount), 0.55);
    return lineMask * dashMask;
}

float DrawGraphRect(float2 p, float2 minP, float2 maxP, float thickness)
{
    float inside = step(minP.x, p.x) * step(minP.y, p.y) * step(p.x, maxP.x) * step(p.y, maxP.y);
    float left   = 1.0 - smoothstep(thickness, thickness * 1.8, abs(p.x - minP.x));
    float right  = 1.0 - smoothstep(thickness, thickness * 1.8, abs(p.x - maxP.x));
    float top    = 1.0 - smoothstep(thickness, thickness * 1.8, abs(p.y - minP.y));
    float bottom = 1.0 - smoothstep(thickness, thickness * 1.8, abs(p.y - maxP.y));
    return inside * saturate(left + right + top + bottom);
}

int CountDigitsInt(int value)
{
    int v = max(value, 0);

    if (v >= 10000) return 5;
    if (v >= 1000) return 4;
    if (v >= 100) return 3;
    if (v >= 10) return 2;
    return 1;
}

float DrawDigitAt(float2 texcoord, float2 topRight, float scale, float aspect, int digit)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topRight;
    anchor.x *= aspect;

    uv -= anchor;
    uv.x = -uv.x;

    return GetDigit(digit, uv / scale);
}

float DrawNumberRightAligned(float2 texcoord, float2 topRight, float scale, float aspect, int value)
{
    int v = max(value, 0);
    int digits = CountDigitsInt(v);
    float stepX = (scale * 0.82) / max(aspect, 1e-6);
    float mask = 0.0;

    mask += DrawDigitAt(texcoord, topRight, scale, aspect, v % 10);

    if (digits >= 2)
        mask += DrawDigitAt(texcoord, topRight - float2(stepX, 0.0), scale, aspect, (v / 10) % 10);

    if (digits >= 3)
        mask += DrawDigitAt(texcoord, topRight - float2(stepX * 2.0, 0.0), scale, aspect, (v / 100) % 10);

    if (digits >= 4)
        mask += DrawDigitAt(texcoord, topRight - float2(stepX * 3.0, 0.0), scale, aspect, (v / 1000) % 10);

    if (digits >= 5)
        mask += DrawDigitAt(texcoord, topRight - float2(stepX * 4.0, 0.0), scale, aspect, (v / 10000) % 10);

    return saturate(mask);
}

float DrawNumberCentered(float2 texcoord, float2 centerTop, float scale, float aspect, int value)
{
    int digits = CountDigitsInt(value);
    float stepX = (scale * 0.82) / max(aspect, 1e-6);
    float totalWidth = stepX * float(max(digits - 1, 0));
    float2 topRight = centerTop + float2(totalWidth * 0.5, 0.0);
    return DrawNumberRightAligned(texcoord, topRight, scale, aspect, value);
}

float3 DrawAPLGraphOverlay(float2 texcoord, float3 sceneColor)
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 p = texcoord;
    p.x *= aspect;

    // Bottom-left quarter layout with room for axis labels
    float2 graphPos = float2(0.055 * aspect, 0.48);
    float2 graphSize = float2(0.43 * aspect, 0.44);
    float2 graphMin = graphPos;
    float2 graphMax = graphPos + graphSize;

    float thickness = 0.00105;
    float curveThickness = thickness * 0.95;
    float refThickness = thickness * 0.90;
    float gridThickness = 0.00050;
    float tickThickness = 0.00075;
    float tickLen = graphSize.y * 0.018;
    float labelScale = 0.014;
    float digitStepScaled = labelScale * 0.82;
    float margin = thickness * 5.0;

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    bool useFullFieldWindowProjection = GraphUseFullFieldWindowProjection;
    int fullFieldWindowMode = GraphProjectionWindowSize;
    float4 graphParams = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float graphMaxMeasuredNits = useFullFieldWindowProjection
        ? GetFullFieldMeasuredMaxOutputNitsByMode(fullFieldWindowMode)
        : graphParams.g;
    float graphAxisMaxPQ = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;

    float graphXMin = graphMin.x - margin;
    float graphXMax = graphMax.x + margin;

    float xLabelMinX = graphMin.x - labelScale * 2.0;
    float xLabelMaxX = graphMax.x + labelScale * 2.0;
    float xLabelMinY = graphMax.y - margin;
    float xLabelMaxY = graphMax.y + 0.010 + labelScale * 1.25;

    int maxAxisLabelDigits = CountDigitsInt((int)round(graphAxisMaxNits));
    float yLabelAnchorX = graphPos.x - graphSize.x * 0.035;
    float yLabelMinX = yLabelAnchorX - digitStepScaled * (float(maxAxisLabelDigits) + 0.25) - labelScale * 0.35;
    float yLabelMaxX = graphPos.x + margin;
    float yLabelMinY = graphMin.y - labelScale * 0.6;
    float yLabelMaxY = graphMax.y + labelScale * 0.6;

    if (p.x < min(yLabelMinX, xLabelMinX) || p.x > max(graphXMax, xLabelMaxX))
        return sceneColor;

    bool inGraphX = (p.x >= graphXMin && p.x <= graphXMax);

    bool inGraphCore = inGraphX && (p.y >= graphMin.y - margin) && (p.y <= graphMax.y + margin);
    bool inXLabelRegion = (p.x >= xLabelMinX) && (p.x <= xLabelMaxX) && (p.y >= xLabelMinY) && (p.y <= xLabelMaxY);
    bool inYLabelRegion = (p.x >= yLabelMinX) && (p.x <= yLabelMaxX) && (p.y >= yLabelMinY) && (p.y <= yLabelMaxY);

    if (!inGraphCore && !inXLabelRegion && !inYLabelRegion)
        return sceneColor;

    float inside = step(graphMin.x, p.x) * step(graphMin.y, p.y) * step(p.x, graphMax.x) * step(p.y, graphMax.y);

    float frameMask = 0.0;
    float gridMask = 0.0;
    float tickMask = 0.0;
    float labelMask = 0.0;
    float refMask = 0.0;
    float idealPQRefMask = 0.0;
    float measuredMask = 0.0;
    float remappedMask = 0.0;
    float correctedMask = 0.0;

    if (inGraphCore)
    {
        frameMask = DrawGraphRect(p, graphMin, graphMax, thickness);

        // Grid lines: indices 0–8 (vertical) and 9–17 (horizontal).
        // All endpoints precomputed in PS_CalcGraphLines — zero NitsToPQ/pow here.
        [loop]
        for (int i = 0; i < 9; i++)
        {
            float uV = (float(i)     + 0.5) / float(GRAPH_LINE_COUNT);
            float uH = (float(i + 9) + 0.5) / float(GRAPH_LINE_COUNT);
            float4 segV = tex2Dlod(SamplerGraphLines, float4(uV, 0.5, 0.0, 0.0));
            float4 segH = tex2Dlod(SamplerGraphLines, float4(uH, 0.5, 0.0, 0.0));
            gridMask += DrawGraphLine(p, segV.xy, segV.zw, gridThickness) * 0.32;
            gridMask += DrawGraphLine(p, segH.xy, segH.zw, gridThickness) * 0.32;
        }

        // Tick marks: x-ticks at indices 18–23, y-ticks at 24–29.
        [loop]
        for (int i = 0; i < 6; i++)
        {
            float uX = (float(i + 18) + 0.5) / float(GRAPH_LINE_COUNT);
            float uY = (float(i + 24) + 0.5) / float(GRAPH_LINE_COUNT);
            float4 segX = tex2Dlod(SamplerGraphLines, float4(uX, 0.5, 0.0, 0.0));
            float4 segY = tex2Dlod(SamplerGraphLines, float4(uY, 0.5, 0.0, 0.0));
            tickMask += DrawGraphLine(p, segX.xy, segX.zw, tickThickness);
            tickMask += DrawGraphLine(p, segY.xy, segY.zw, tickThickness);
        }

        // Identity reference dashed line: index 30.
        {
            float uRef = (30.0 + 0.5) / float(GRAPH_LINE_COUNT);
            float4 segRef = tex2Dlod(SamplerGraphLines, float4(uRef, 0.5, 0.0, 0.0));
            refMask = DrawGraphDashedLine(p, segRef.xy, segRef.zw, refThickness, 22.0);
        }

    }

    if (inXLabelRegion || inYLabelRegion)
    {
        [loop]
        for (int i = 0; i < 6; i++)
        {
            // Fetch x-tick (idx 18+i) and y-tick (idx 24+i) endpoints from precomputed texture.
            // xTick = segX.zw (the 'b' endpoint = the tick base on the axis).
            // yTick = segY.xy (the 'a' endpoint = the tick base on the axis).
            float uX = (float(i + 18) + 0.5) / float(GRAPH_LINE_COUNT);
            float uY = (float(i + 24) + 0.5) / float(GRAPH_LINE_COUNT);
            float4 segX = tex2Dlod(SamplerGraphLines, float4(uX, 0.5, 0.0, 0.0));
            float4 segY = tex2Dlod(SamplerGraphLines, float4(uY, 0.5, 0.0, 0.0));
            float2 xTick = segX.zw; // 'b' endpoint is the base of the x-tick (on the axis line)
            float2 yTick = segY.xy; // 'a' endpoint is the base of the y-tick (on the axis line)

            // tickValue in nits is needed only for the integer label.
            // GraphTickValueFromFractionWithPQMax is cheap in linear-space mode; in PQ mode
            // it calls PQToLinearScalar but this block is gated by inXLabelRegion/inYLabelRegion
            // which is a small strip — the pow cost here is acceptable and unavoidable.
            float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
            int tickLabel = (int)round(tickValue);

            if (inXLabelRegion)
            {
                float2 xLabelCenter = float2(xTick.x / max(aspect, 1e-6), graphMax.y + 0.010);
                labelMask += DrawNumberCentered(texcoord, xLabelCenter, labelScale, aspect, tickLabel);
            }

            if (inYLabelRegion)
            {
                float2 yLabelTopRight = float2(yLabelAnchorX / max(aspect, 1e-6), yTick.y - labelScale * 0.52);
                labelMask += DrawNumberRightAligned(texcoord, yLabelTopRight, labelScale, aspect, tickLabel);
            }
        }
    }

    if (inGraphCore)
    {
        // -------------------------------------------------------------------
        // Curve drawing — all segment endpoints precomputed in PS_CalcGraphCurves.
        // Each texel = float4(ax, ay, bx, by) in p-space (texcoord with x*=aspect).
        // Sentinels (x < 0) mark segments to skip (invalid range or disabled curve).
        // Per-pixel cost: GRAPH_CURVE_SAMPLES tex fetches + DrawGraphLine bbox tests.
        // All expensive LUT math + NitsToPQ/pow moved to the 64x4 precompute pass.
        // -------------------------------------------------------------------
        [loop]
        for (int s = 0; s < GRAPH_CURVE_SAMPLES - 1; ++s)
        {
            float u = (float(s) + 0.5) / float(GRAPH_CURVE_SAMPLES);

            // Remapped (green) curve — APL mode only; precompute stores sentinel in window mode
            if (!useFullFieldWindowProjection)
            {
                float4 seg = tex2Dlod(SamplerGraphCurves, float4(u, 0.125, 0.0, 0.0));
                if (seg.x >= 0.0)
                    remappedMask = max(remappedMask, DrawGraphLine(p, seg.xy, seg.zw, curveThickness * 0.95));
            }

            // Corrected / gray projected-output curve
            {
                float4 seg = tex2Dlod(SamplerGraphCurves, float4(u, 0.375, 0.0, 0.0));
                if (seg.x >= 0.0)
                    correctedMask = max(correctedMask, DrawGraphLine(p, seg.xy, seg.zw, curveThickness));
            }

            // Measured raw / light-blue curve
            {
                float4 seg = tex2Dlod(SamplerGraphCurves, float4(u, 0.625, 0.0, 0.0));
                if (seg.x >= 0.0)
                    measuredMask = max(measuredMask, DrawGraphLine(p, seg.xy, seg.zw, curveThickness));
            }
        }

        // BT.2390 reference (magenta dashed) — row 3; precompute stores sentinels when disabled
        if (GraphShowBT2390Reference && max(graphMaxMeasuredNits, 0.0) > 0.0)
        {
            [loop]
            for (int s = 0; s < GRAPH_CURVE_SAMPLES - 1; ++s)
            {
                float u = (float(s) + 0.5) / float(GRAPH_CURVE_SAMPLES);
                float4 seg = tex2Dlod(SamplerGraphCurves, float4(u, 0.875, 0.0, 0.0));
                if (seg.x >= 0.0)
                    idealPQRefMask = max(idealPQRefMask, DrawGraphDashedLine(p, seg.xy, seg.zw, refThickness * 0.95, 18.0));
            }
        }
    }

    float bgMask = inside * 0.12;
    float3 graphColor = sceneColor;
    graphColor = lerp(graphColor, float3(0.0, 0.0, 0.0), bgMask * saturate(GraphOpacity * 0.95));
    graphColor = lerp(graphColor, float3(0.58, 0.58, 0.58) * OSDBrightness * 1.25, saturate(gridMask) * GraphOpacity);
    graphColor = lerp(graphColor, float3(0.90, 0.90, 0.90) * OSDBrightness * 1.45, saturate(tickMask) * GraphOpacity);
    graphColor = lerp(graphColor, float3(1.0, 1.0, 1.0) * OSDBrightness * 1.8, saturate(frameMask) * GraphOpacity);
    graphColor = lerp(graphColor, float3(0.85, 0.85, 0.85) * OSDBrightness * 1.7, saturate(labelMask) * saturate(GraphOpacity + 0.05));
    float measuredMaskSat = saturate(measuredMask);
    float correctedMaskSat = saturate(correctedMask);
    float overlapMask = useFullFieldWindowProjection ? min(measuredMaskSat, correctedMaskSat) : 0.0;
    float measuredExclusiveMask = useFullFieldWindowProjection ? saturate(measuredMaskSat - overlapMask) : measuredMaskSat;
    float correctedExclusiveMask = useFullFieldWindowProjection ? saturate(correctedMaskSat - overlapMask) : correctedMaskSat;

    float3 measuredCurveColor = float3(0.62, 0.82, 1.00);
    float3 correctedCurveColor = float3(0.62, 0.62, 0.62);
    float3 overlapCurveColor = float3(0.30, 0.88, 0.42);

    graphColor = lerp(graphColor, float3(0.40, 0.65, 1.00) * OSDBrightness * 2.0, saturate(refMask) * GraphOpacity);
    graphColor = lerp(graphColor, float3(1.00, 0.35, 0.92) * OSDBrightness * 2.0, saturate(idealPQRefMask) * saturate(GraphOpacity + 0.02));
    graphColor = lerp(graphColor, measuredCurveColor * OSDBrightness * 1.95, measuredExclusiveMask * saturate(GraphOpacity * 0.95));
    graphColor = lerp(graphColor, float3(0.30, 0.88, 0.42) * OSDBrightness * 1.55, saturate(remappedMask) * saturate(GraphOpacity + 0.06));
    graphColor = lerp(graphColor, correctedCurveColor * OSDBrightness * 1.85, correctedExclusiveMask * saturate(GraphOpacity + 0.20));
    graphColor = lerp(graphColor, overlapCurveColor * OSDBrightness * 1.95, overlapMask * saturate(GraphOpacity + 0.20));

    return saturate(graphColor);
}

#endif

// --- SHADERS ---

// PASS 0: Parallel APL decode — runs on APL_DECODE_SIZE x APL_DECODE_SIZE threads.
// Each thread samples the backbuffer at its own UV and performs the full PQ decode
// (or scRGB luma) exactly once, writing the result to TexAPLDecoded.
// This spreads APL_DECODE_SIZE^2 transcendental calls across that many parallel GPU
// threads instead of serialising them all inside a single 1x1 pixel shader loop.
// PS_CalcAPL then only needs to read and sum pre-decoded scalars — zero transcendentals.
float4 PS_DecodeAPL(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 color     = tex2Dlod(ReShade::BackBuffer, float4(texcoord, 0.0, 0.0)).rgb;
    float  sceneNits = GetSceneNitsFromColor(color);
    float  metric    = saturate(sceneNits / max(APLReferenceWhiteNits, 1.0));
    // .r = normalised metric, .g = raw nits (for max-nits OSD in PS_CalcAPL)
    return float4(metric, sceneNits, 0.0, 1.0);
}

// PASS 1: Accumulate pre-decoded APL samples — runs on a single 1x1 pixel.
// All APL_DECODE_SIZE^2 loop iterations are now pure texture fetches + adds;
// the expensive decode work was done in parallel by PS_DecodeAPL above.
// APLGridSize is no longer used here: since the decode cost is paid by the
// parallel pass, all APL_DECODE_SIZE^2 samples are always accumulated.

float4 PS_CalcAPL(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float totalMetric         = 0.0;
    float maxSampledSceneNits = 0.0;
    float totalHighAPLMetric  = 0.0;
    static const float invTotalSamples = 1.0 / float(APL_DECODE_SIZE * APL_DECODE_SIZE);

    [loop]
    for (int x = 0; x < APL_DECODE_SIZE; ++x)
    {
        [loop]
        for (int y = 0; y < APL_DECODE_SIZE; ++y)
        {
            float2 uv   = (float2(x, y) + 0.5) * invTotalSamples * float(APL_DECODE_SIZE); // = (xy + 0.5) / APL_DECODE_SIZE
            float2 data = tex2Dlod(SamplerAPLDecoded, float4(uv, 0.0, 0.0)).rg;
            float sampleNits = data.g;

            totalMetric         += data.r;
            maxSampledSceneNits  = max(maxSampledSceneNits, sampleNits);

            if (EnableHighAPLAdaptiveBoost)
                totalHighAPLMetric += ComputeHighAPLMetricSampleWeight(sampleNits);
        }
    }

    float apl = totalMetric * invTotalSamples;
    float highAPLMetric = EnableHighAPLAdaptiveBoost ? (totalHighAPLMetric * invTotalSamples) : 0.0;

    // r = raw current-frame APL metric, g = max sampled decoded scene nits, b = raw current-frame High APL % metric, a = valid
    return float4(apl, maxSampledSceneNits, highAPLMetric, 1.0);
}

float4 PS_CopyAPLState(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    return tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0));
}


float4 PS_SmoothAPL(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float4 currentData = tex2Dlod(SamplerAPLInstant, float4(0.5, 0.5, 0.0, 0.0));
    float4 prevData = tex2Dlod(SamplerAPLPrev, float4(0.5, 0.5, 0.0, 0.0));

    float rawAPL = saturate(currentData.r);
    float currentMaxSampledNits = max(currentData.g, 0.0);
    float currentHighAPLMetric = saturate(currentData.b);

    float prevSmoothedAPL = saturate(prevData.r);
    float prevSmoothedMaxSampledNits = max(prevData.g, 0.0);
    float prevSmoothedHighAPLMetric = saturate(prevData.b);

    float alpha = ComputeTemporalBlendFactor(TransitionSpeed);
    float hasPrev = (prevData.r > 0.0 || prevData.g > 0.0 || prevData.b > 0.0 || prevData.a > 0.0) ? 1.0 : 0.0;

    float smoothedMaxSampledNits = lerp(currentMaxSampledNits, lerp(prevSmoothedMaxSampledNits, currentMaxSampledNits, alpha), hasPrev);
    float smoothedHighAPLMetric = lerp(currentHighAPLMetric, lerp(prevSmoothedHighAPLMetric, currentHighAPLMetric, alpha), hasPrev);

    // Keep the original closed-loop APL solver independent from the High APL % overlay reduction.
    // This avoids a second lag path where the smoothed High APL metric indirectly perturbs the
    // already-smoothed base APL operating point. High APL % still reduces the final scene boost
    // directly through ComputeSceneLogGainFromAPL(...) below.
    float closedLoopCurrentAPL = SolveClosedLoopDisplayAPLFromRaw(rawAPL);
    float smoothedAPL = lerp(closedLoopCurrentAPL, lerp(prevSmoothedAPL, closedLoopCurrentAPL, alpha), hasPrev);

    // Precompute scene-uniform sceneLogGain here (1x1 pass) so PS_MainPass reads it from the
    // texture instead of recomputing the LUT lookup + log2 + pow chain for every pixel.
    // .b is now the smoothed High APL % metric, so sceneLogGain moves to .a.
    // The following Boost_Params pass derives the rolloff anchor and BT.2390 shoulder constants from it.
    float sceneLogGain = ComputeSceneLogGainFromAPL(smoothedAPL, smoothedHighAPLMetric);

    // r = smoothed closed-loop display-side APL metric, g = smoothed max sampled decoded scene nits,
    // b = smoothed High APL % metric, a = precomputed scene log-gain (uniform across all pixels)
    return float4(smoothedAPL, smoothedMaxSampledNits, smoothedHighAPLMetric, sceneLogGain);
}

float4 PS_CalcBoostParams(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float4 aplData = tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0));
    return ComputeBoostRolloffParamsFromSceneLogGain(aplData.a);
}

float DrawOSDDigitAt(float2 texcoord, float2 topRight, float scale, float aspect, int digit)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topRight;
    anchor.x *= aspect;

    uv -= anchor;
    uv.x = -uv.x;

    return GetDigit(digit, uv / scale);
}

float DrawOSDPercentAt(float2 texcoord, float2 topRight, float scale, float aspect)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topRight;
    anchor.x -= scale / max(aspect, 1e-6);
    anchor.x *= aspect;

    uv -= anchor;

    return GetPercent(uv / scale);
}

float DrawOSDDotAt(float2 texcoord, float2 topRight, float scale, float aspect)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topRight;
    anchor.x *= aspect;

    uv -= anchor;
    uv.x = -uv.x;

    return GetDot(uv / scale);
}

float DrawOSDAPLPercent2(float2 texcoord, float2 topRight, float scale, float stepX, float aspect, float currentAPL)
{
    int aplPctX100 = clamp(int(floor(saturate(currentAPL) * 10000.0 + 0.5)), 0, 10000);
    int integerPart = aplPctX100 / 100;
    int fractionalPart = aplPctX100 % 100;

    float mask = 0.0;

    // Fixed 2-decimal percent layout, right-aligned to the hundredths digit:
    // [hundreds][tens][ones].[tenths][hundredths]
    mask += DrawOSDDigitAt(texcoord, topRight, scale, aspect, fractionalPart % 10);
    mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX, 0.0), scale, aspect, (fractionalPart / 10) % 10);
    mask += DrawOSDDotAt(texcoord, topRight - float2(stepX * 2.0, 0.0), scale, aspect);
    mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 3.0, 0.0), scale, aspect, integerPart % 10);

    if (integerPart >= 10)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 4.0, 0.0), scale, aspect, (integerPart / 10) % 10);

    if (integerPart >= 100)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 5.0, 0.0), scale, aspect, (integerPart / 100) % 10);

    return saturate(mask);
}

float DrawOSDFixed2(float2 texcoord, float2 topRight, float scale, float stepX, float aspect, float value)
{
    int valueX100 = clamp(int(floor(max(value, 0.0) * 100.0 + 0.5)), 0, 9999);
    int integerPart = valueX100 / 100;
    int fractionalPart = valueX100 % 100;

    float mask = 0.0;

    mask += DrawOSDDigitAt(texcoord, topRight, scale, aspect, fractionalPart % 10);
    mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX, 0.0), scale, aspect, (fractionalPart / 10) % 10);
    mask += DrawOSDDotAt(texcoord, topRight - float2(stepX * 2.0, 0.0), scale, aspect);
    mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 3.0, 0.0), scale, aspect, integerPart % 10);

    if (integerPart >= 10)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 4.0, 0.0), scale, aspect, (integerPart / 10) % 10);

    return saturate(mask);
}


float DrawOSDRow5(float2 texcoord, float2 topRight, float scale, float stepX, float aspect, int value)
{
    uint v = (uint)clamp(value, 0, 99999);
    float mask = 0.0;

    mask += DrawOSDDigitAt(texcoord, topRight, scale, aspect, (int)(v % 10));

    if (v >= 10)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX, 0.0), scale, aspect, (int)((v / 10) % 10));

    if (v >= 100)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 2.0, 0.0), scale, aspect, (int)((v / 100) % 10));

    if (v >= 1000)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 3.0, 0.0), scale, aspect, (int)((v / 1000) % 10));

    if (v >= 10000)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 4.0, 0.0), scale, aspect, (int)((v / 10000) % 10));

    return saturate(mask);
}


float3 DrawStatsOverlay(float2 texcoord, float3 sceneColor, float rawInputAPL, float outputAPL, float maxSampledNits, float highAPLMetric, float finalBoostStrength)
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float invAspect = 1.0 / max(aspect, 1e-6);
    float scale = 0.029;
    float glyphWidth = scale * invAspect;
    float stepX = glyphWidth * 1.08;
    float lineSpacing = scale * 1.22;
    float percentGap = glyphWidth * 0.20;

    // Compact five-row numeric OSD on the right.
    // Row 1 = raw input scene APL (%), Row 2 = smoothed output / display-side APL (%),
    // Row 3 = smoothed max sampled decoded scene nits, Row 4 = smoothed High APL (%),
    // Row 5 = current final scene boost strength.
    float rightMargin = 0.016;
    float2 inputPercentRight = float2(1.0 - rightMargin, 0.040);
    float2 inputRowRight = inputPercentRight - float2(glyphWidth + percentGap, 0.0);
    float2 outputPercentRight = inputPercentRight + float2(0.0, lineSpacing);
    float2 outputRowRight = inputRowRight + float2(0.0, lineSpacing);
    float2 nitsRowRight = inputRowRight + float2(0.0, lineSpacing * 2.0);
    float2 highAPLPercentRight = inputPercentRight + float2(0.0, lineSpacing * 3.0);
    float2 highAPLRowRight = inputRowRight + float2(0.0, lineSpacing * 3.0);
    float2 boostStrengthRowRight = inputRowRight + float2(0.0, lineSpacing * 4.0);

    float left = inputRowRight.x - stepX * 5.0 - glyphWidth;
    float right = inputPercentRight.x;
    float top = inputRowRight.y;
    float bottom = boostStrengthRowRight.y + scale;

    float padX = glyphWidth * 0.42;
    float padY = scale * 0.18;

    if (texcoord.x < left - padX || texcoord.x > right + padX || texcoord.y < top - padY || texcoord.y > bottom + padY)
        return sceneColor;

    int nitDisplay = clamp(int(floor(max(maxSampledNits, 0.0) + 0.5)), 0, 99999);

    float bgMask = (texcoord.x >= left - padX && texcoord.x <= right + padX && texcoord.y >= top - padY && texcoord.y <= bottom + padY) ? 1.0 : 0.0;

    float inputMask = 0.0;
    inputMask += DrawOSDAPLPercent2(texcoord, inputRowRight, scale, stepX, aspect, rawInputAPL);
    inputMask += DrawOSDPercentAt(texcoord, inputPercentRight, scale, aspect);
    inputMask = saturate(inputMask);

    float outputMask = 0.0;
    outputMask += DrawOSDAPLPercent2(texcoord, outputRowRight, scale, stepX, aspect, outputAPL);
    outputMask += DrawOSDPercentAt(texcoord, outputPercentRight, scale, aspect);
    outputMask = saturate(outputMask);

    float nitsMask = DrawOSDRow5(texcoord, nitsRowRight, scale, stepX, aspect, nitDisplay);

    float highAPLMask = 0.0;
    highAPLMask += DrawOSDAPLPercent2(texcoord, highAPLRowRight, scale, stepX, aspect, highAPLMetric);
    highAPLMask += DrawOSDPercentAt(texcoord, highAPLPercentRight, scale, aspect);
    highAPLMask = saturate(highAPLMask);

    float boostStrengthMask = DrawOSDFixed2(texcoord, boostStrengthRowRight, scale, stepX, aspect, finalBoostStrength);

    float bgAlpha = 0.18 * OSDBrightness * bgMask;
    float3 shadedScene = sceneColor * (1.0 - bgAlpha);

    float3 inputColor = float3(0.30, 1.00, 0.30) * OSDBrightness;
    float3 outputColor = float3(1.00, 0.90, 0.18) * OSDBrightness;
    float3 nitsColor = float3(0.60, 0.85, 1.00) * OSDBrightness;
    float3 highAPLColor = float3(1.00, 0.55, 0.22) * OSDBrightness;
    float3 boostStrengthColor = float3(0.95, 0.65, 1.00) * OSDBrightness;

    float3 result = shadedScene;
    result = lerp(result, inputColor, inputMask);
    result = lerp(result, outputColor, outputMask);
    result = lerp(result, nitsColor, nitsMask);
    result = lerp(result, highAPLColor, highAPLMask);
    result = lerp(result, boostStrengthColor, boostStrengthMask);

    return result;
}

// PASS 2b: Main Rendering (1D APL-only measured scene gain + hybrid luminance participation)

float4 PS_MainPass(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;

    float4 aplData = tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0));
    float currentAPL = aplData.r;
    float smoothedMaxSampledNits = aplData.g;
    float smoothedHighAPLMetric = aplData.b;

    // sceneLogGain is scene-uniform (depends only on APL + uniforms).
    // It is precomputed once in PS_SmoothAPL and stored in aplData.a,
    // eliminating the LUT lookup + log2 + conditional pow chain per pixel.
    float sceneLogGain = aplData.a;
    if (sceneLogGain <= 0.0 && (ShowOSD == false))
        return float4(color, 1.0);

    float4 boostParams = tex2Dlod(SamplerBoostParams, float4(0.5, 0.5, 0.0, 0.0));
    float3 finalColor = ApplyBoostPreserveColorFromPrecomputedParams(color, sceneLogGain, boostParams);

    if (ShowOSD)
    {
        float rawInputAPL = saturate(tex2Dlod(SamplerAPLInstant, float4(0.5, 0.5, 0.0, 0.0)).r);
        float finalBoostStrength = ComputeSceneFinalBoostStrength(currentAPL, smoothedHighAPLMetric);
        finalColor = DrawStatsOverlay(texcoord, finalColor, rawInputAPL, currentAPL, smoothedMaxSampledNits, smoothedHighAPLMetric, finalBoostStrength);
    }

    return float4(finalColor, 1.0);
}

#if ENABLE_APL_GRAPH
float4 PS_CalcGraphParams(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float graphAxisMaxPQ = GraphUsePQSpace ? max(NitsToPQ(graphAxisMaxNits), 1e-6) : 0.0;

    if (GraphUseFullFieldWindowProjection)
    {
        return float4(0.0, 0.0, graphAxisMaxPQ, 0.0);
    }

    float graphRawAPLPercent = clamp(GraphAPLIndex, 0.0, 100.0);
    float graphClosedLoopAPL = ComputeGraphClosedLoopAPLFromRawPercent(graphRawAPLPercent);
    float graphClosedLoopAPLPercent = graphClosedLoopAPL * 100.0;
    float maxMeasuredNits = GetAPLMaxMeasuredNits(graphClosedLoopAPLPercent);
    float graphAnchorBoostedNits = ComputeRollOffAnchorBoostedNits(graphClosedLoopAPL);

    // r = solved closed-loop APL %, g = max measured nits, b = axis max PQ, a = rolloff anchor.
    // The old r value was graphRollOffStartNits but PS_CalcGraphCurves never used it.
    return float4(graphClosedLoopAPLPercent, maxMeasuredNits, graphAxisMaxPQ, graphAnchorBoostedNits);
}

// GRAPH PASS 1b: Precompute grid/tick/ref line screen-space endpoints (32 pixels — free).
// Eliminates ~200 NitsToPQ/pow calls per inGraphCore pixel in the fullscreen draw pass.
float4 PS_CalcGraphLines(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    int idx = int(vpos.x);

    float aspect       = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 graphPos    = float2(0.055 * aspect, 0.48);
    float2 graphSize   = float2(0.43  * aspect, 0.44);
    float2 graphMin    = graphPos;
    float2 graphMax    = graphPos + graphSize;
    float  thickness   = 0.00105;
    float  tickLen     = graphSize.y * 0.018;

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float4 graphParams     = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float  graphAxisMaxPQ  = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;

    float2 a = 0.0, b = 0.0;

    if (idx < 9) // grid vertical lines i=1..9
    {
        int i = idx + 1;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 10.0, graphAxisMaxNits, graphAxisMaxPQ);
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, 0.0);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, graphAxisMaxNits);
    }
    else if (idx < 18) // grid horizontal lines i=1..9
    {
        int i = idx - 9 + 1;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 10.0, graphAxisMaxNits, graphAxisMaxPQ);
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0,           tickValue);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, graphAxisMaxNits, tickValue);
    }
    else if (idx < 24) // x-tick marks i=0..5
    {
        int i = idx - 18;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
        float2 xTick = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, 0.0);
        a = xTick + float2(0.0, -tickLen);
        b = xTick;
    }
    else if (idx < 30) // y-tick marks i=0..5
    {
        int i = idx - 24;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
        float2 yTick = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0, tickValue);
        a = yTick;
        b = yTick + float2(tickLen, 0.0);
    }
    else if (idx == 30) // identity reference dashed line
    {
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0,             0.0);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, graphAxisMaxNits, graphAxisMaxNits);
    }
    else // idx == 31 — padding sentinel
    {
        return float4(-1.0, -1.0, -1.0, -1.0);
    }

    return float4(a, b);
}

// GRAPH PASS 2: Precompute all curve segment endpoints (64 x 4 = 256 pixels — free).
//
// Each texel (s, row) stores float4(ax, ay, bx, by) in p-space screen coords
// (texcoord with p.x *= aspect) for curve segment s, row = GCURVE_* index.
// Sentinel float4(-1,-1,-1,-1) marks segments to skip in the draw pass.
//
// This removes all expensive LUT math + NitsToPQ/pow calls from the fullscreen
// PS_DebugOverlay pass.  The per-pixel draw loop only does tex fetches + DrawGraphLine.
float4 PS_CalcGraphCurves(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    static const float4 SENTINEL = float4(-1.0, -1.0, -1.0, -1.0);

    int s   = int(vpos.x);   // 0 .. GRAPH_CURVE_SAMPLES-1
    int row = int(vpos.y);   // 0 .. 3

    // Only segments 0..62 are valid; column 63 is a pad, never fetched by the draw pass.
    if (s >= GRAPH_CURVE_SAMPLES - 1)
        return SENTINEL;

    // --- Shared graph layout (must exactly match DrawAPLGraphOverlay) ---
    float aspect       = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 graphPos    = float2(0.055 * aspect, 0.48);
    float2 graphSize   = float2(0.43  * aspect, 0.44);
    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);

    float4 graphParams               = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float  graphAxisMaxPQ            = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;
    float  graphRawAPLPercent        = clamp(GraphAPLIndex, 0.0, 100.0);
    float  graphClosedLoopAPLPercent = graphParams.r;
    float  graphAnchorBoostedNits    = graphParams.a;

    bool useFF = GraphUseFullFieldWindowProjection;
    int fullFieldWindowMode = GraphProjectionWindowSize;

    // --- Sample the two nits x-values for this segment ---
    float t0 = float(s)     / float(GRAPH_CURVE_SAMPLES - 1);
    float t1 = float(s + 1) / float(GRAPH_CURVE_SAMPLES - 1);
    float x0 = GraphSampleNitsFromFraction(t0, graphAxisMaxNits, graphAxisMaxPQ);
    float x1 = GraphSampleNitsFromFraction(t1, graphAxisMaxNits, graphAxisMaxPQ);

    float graphMaxMeasuredNits = useFF
        ? GetFullFieldMeasuredMaxOutputNitsByMode(fullFieldWindowMode)
        : graphParams.g;

    float4 result = SENTINEL;

    if (row == GCURVE_REMAPPED)
    {
        // Green re-mapped curve: standard APL mode only, using the closed-loop display-side APL solved from the selected raw input APL.
        if (!useFF)
        {
            float y0 = ComputeGraphCurveRemappedTargetNits(useFF, fullFieldWindowMode, graphClosedLoopAPLPercent, graphAnchorBoostedNits, x0);
            float y1 = ComputeGraphCurveRemappedTargetNits(useFF, fullFieldWindowMode, graphClosedLoopAPLPercent, graphAnchorBoostedNits, x1);
            float2 a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
            float2 b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
            result = float4(a, b);
        }
    }
    else if (row == GCURVE_CORRECTED)
    {
        // Gray projected / corrected output curve (both modes).
        float y0r = ComputeGraphCurveRemappedTargetNits(useFF, fullFieldWindowMode, graphClosedLoopAPLPercent, graphAnchorBoostedNits, x0);
        float y1r = ComputeGraphCurveRemappedTargetNits(useFF, fullFieldWindowMode, graphClosedLoopAPLPercent, graphAnchorBoostedNits, x1);
        float y0  = ComputeGraphCurveCorrectedOutputNits(useFF, fullFieldWindowMode, graphClosedLoopAPLPercent, graphMaxMeasuredNits, y0r);
        float y1  = ComputeGraphCurveCorrectedOutputNits(useFF, fullFieldWindowMode, graphClosedLoopAPLPercent, graphMaxMeasuredNits, y1r);
        float2 a  = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
        float2 b  = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
        result = float4(a, b);
    }
    else if (row == GCURVE_MEASURED)
    {
        // Light-blue measured raw curve at the selected raw input APL / window set (clamped to measuredMaxInputNits).
        float measuredMaxInputNits = useFF
            ? GetFullFieldMeasuredMaxInputNitsByMode(fullFieldWindowMode)
            : GetGraphMeasuredMaxInputNits();

        if (x0 < measuredMaxInputNits)
        {
            float mx1 = min(x1, measuredMaxInputNits);
            float y0   = ComputeGraphCurveMeasuredRawOutputNits(useFF, fullFieldWindowMode, graphRawAPLPercent, x0);
            float y1   = ComputeGraphCurveMeasuredRawOutputNits(useFF, fullFieldWindowMode, graphRawAPLPercent, mx1);
            float2 a   = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0,  y0);
            float2 b   = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, mx1, y1);
            result = float4(a, b);
        }
    }
    else // row == GCURVE_BT2390REF (row 3)
    {
        // Magenta dashed BT.2390 reference curve (optional).
        float idealReferencePeakNits = max(graphMaxMeasuredNits, 0.0);
        if (GraphShowBT2390Reference && idealReferencePeakNits > 0.0)
        {
            float y0  = ComputeBT2390ReferenceOutputNits(x0, graphAxisMaxNits, idealReferencePeakNits);
            float y1  = ComputeBT2390ReferenceOutputNits(x1, graphAxisMaxNits, idealReferencePeakNits);
            float2 a  = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
            float2 b  = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
            result = float4(a, b);
        }
    }
    return result;
}

float4 PS_DebugOverlay(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 finalColor = tex2D(SamplerBoosted, texcoord).rgb;

    if (ShowAPLGraph)
    {
        finalColor = DrawAPLGraphOverlay(texcoord, finalColor);
    }

    return float4(finalColor, 1.0);
}
#endif

technique EOTF_Boost_1D_APL_LUT 
{
    // Parallel decode: APL_DECODE_SIZE x APL_DECODE_SIZE threads each run one PQ decode.
    pass APL_Decode
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_DecodeAPL;
        RenderTarget = TexAPLDecoded;
    }

    pass APL_Calculation
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcAPL;
        RenderTarget = TexAPLInstant;
    }

    pass APL_CopyState
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CopyAPLState;
        RenderTarget = TexAPLPrev;
    }

    pass APL_Smoothing
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_SmoothAPL;
        RenderTarget = TexAPL;
    }

    pass Boost_Params
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcBoostParams;
        RenderTarget = TexBoostParams;
    }

    pass Main_Boost
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MainPass;
#if ENABLE_APL_GRAPH
        RenderTarget = TexBoosted;
#endif
    }

#if ENABLE_APL_GRAPH
    pass Graph_Params
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcGraphParams;
        RenderTarget = TexGraphParams;
    }

    pass Graph_Lines
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcGraphLines;
        RenderTarget = TexGraphLines;
    }

    pass Graph_Curves
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcGraphCurves;
        RenderTarget = TexGraphCurves;
    }

    pass Debug_Overlay
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_DebugOverlay;
    }
#endif
}
