/*
    EOTF Boost v8.7.1.1F - 1D APL Lookup + Optional High APL Adaptive Boost
    Calibrated for monitor SAMSUNG OLED G8 G85SB, tweaked slightly for AORUS FO32U/2/2P (F04) based on approximated and aggregated values from TFT review
    Added color preserving boost limit slider
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
> = 1040.0;

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
> = 0.4;


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
> = 0.7;

uniform float APLBoostStrength07 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 7% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 7% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.7;

uniform float APLBoostStrength10 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 10% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 10% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.7;

uniform float APLBoostStrength14 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 14% Boost Strength";
    UI_TOOLTIP("Per-APL boost strength override for the measured 14% APL point. Used only when Enable Per-APL Boost Strength is enabled.")
> = 0.6;

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
> = 400.0;

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
> = 1000.0;

uniform float BoostRollOffShape <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 4.0; ui_step = 0.01;
    ui_label = "Boost Roll-Off Shape";
    UI_TOOLTIP("Adjusts the live roll off character by moving the roll off start together with the shoulder curvature so the transition stays smooth and monotonic. 1.0 = standard BT.2390. Values below 1.0 start later and hold highlights higher longer. Values above 1.0 start earlier and compress highlights harder.")
> = 1.25;


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

uniform float EnableColorPreservingBoostMode <
    ui_type = "slider";
    ui_min = 0.75; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Preserve Color by Reducing Boost";
    UI_TOOLTIP("When enabled, saturated colors keep their RGB ratio by reducing only the added boost before channels would exceed the Boost Roll-Off Target. Variable. Original behavior is unchanged when at 1.0.")
> = 1.0;

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
> = 1000.0;

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
// three pairs of scalar calls.  Used by ApplyBoostPreserveColorFromSceneLogGain to re-encode
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

float ApplyBT2390EETFToPQ(float inputPQ, float sourcePeakNits, float targetPeakNits)
{
    return ApplyBT2390EETFToPQWithShape(inputPQ, sourcePeakNits, targetPeakNits, 1.0);
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

float GetSignalLuma(float3 color)
{
    return (APLInputMode == 1) ? GetLuma2020(color) : GetLuma709(color);
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

float GetAPLMetricSample(float3 color)
{
    return saturate(GetSceneNitsFromColor(color) / max(APLReferenceWhiteNits, 1.0));
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
    10.302358, 13.132379, 16.611621, 20.870708, 26.064850, 32.378420, 40.030390, 49.280814, 60.438551, 73.870492, 90.012580, 109.383004, 132.598006, 160.390856, 193.634650, 233.369755, 280.836899, 337.517130, 405.180165, 485.942985, 587.341000, 707.414628, 845.814884, 1040.932391
};

// Original 2D table collapsed to one representative compensation value per APL row.
// These anchors are taken near 109 nits, which tracks the row average very closely
// while preserving the stronger APL dependence that matters most.
static const float COMP_APL_1D[APL_COUNT] =
{
    1.000000, // APL 3
    1.352556, // APL 5
    1.673813, // APL 7
    2.151376, // APL 10
    2.455437, // APL 14
    2.636610, // APL 18
    2.760512, // APL 22
    2.839076, // APL 25
    3.064304, // APL 35
    3.345667  // APL 50
};

static const float COMP_MIN = 1.0;
static const float COMP_MAX = 3.345667;

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
float MeasuredCompToBoostT(float comp)
{
    return saturate((comp - COMP_MIN) / max(COMP_MAX - COMP_MIN, 1e-6));
}

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

float ComputeBoostedTargetNitsNoRolloff(float currentAPL, float inputNits, float highAPLMetric)
{
    float safeInputNits = max(inputNits, 0.0);
    return ComputeBoostedTargetNitsFromBoostTNoRolloff(currentAPL, safeInputNits, highAPLMetric);
}

float ComputeBoostedTargetNitsNoRolloff(float currentAPL, float inputNits)
{
    return ComputeBoostedTargetNitsNoRolloff(currentAPL, inputNits, 0.0);
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

float SolveDynamicRollOffStartNits(float currentAPL)
{
    float rollOffEndNits = max(BoostRollOff, 0.0);

    if (rollOffEndNits <= 0.0)
        return 0.0;

    float referenceInputNits = max(rollOffEndNits, 1e-4);
    float referenceBoostedNits = ComputeRollOffAnchorBoostedNits(currentAPL);

    if (referenceBoostedNits <= referenceInputNits + 1e-4)
        return referenceBoostedNits;

    float sourceBlackPQ = PQ_BLACK;
    float sourceWhitePQ = max(NitsToPQ(referenceBoostedNits), sourceBlackPQ + 1e-6);
    float targetWhitePQ = min(NitsToPQ(referenceInputNits), sourceWhitePQ - 1e-6);
    float pqRange = max(sourceWhitePQ - sourceBlackPQ, 1e-6);
    float maxLum = saturate((targetWhitePQ - sourceBlackPQ) / pqRange);
    float kneeStart = ComputeBT2390ShapedKneeStart(maxLum, BoostRollOffShape);
    float rollOffStartPQ = saturate(kneeStart * pqRange + sourceBlackPQ);

    return max(PQToLinearScalar(rollOffStartPQ) * 10000.0, 0.0);
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

float ApplyBoostWithBT2390RolloffFromSceneLogGain(float signalLuma, float sceneLogGain, float anchorBoostedNits)
{
    float originalNits = SignalLumaToNits(signalLuma);
    float safeOriginalNits = max(originalNits, 0.0);
    float fullyBoostedNits = safeOriginalNits * ComputePixelGainFromSceneLogGain(sceneLogGain, safeOriginalNits);
    float rollOffEndNits = max(BoostRollOff, 0.0);

    if (rollOffEndNits <= 0.0)
        return NitsToSignalLuma(fullyBoostedNits);

    float sourcePeakNits = max(anchorBoostedNits, rollOffEndNits + 1e-4);
    float rolledNits = max(ApplyBT2390EETFToNitsWithShape(fullyBoostedNits, sourcePeakNits, rollOffEndNits, BoostRollOffShape), safeOriginalNits);

    return NitsToSignalLuma(rolledNits);
}

float ApplyBoostWithSelectedRolloff(float signalLuma, float currentAPL, float anchorBoostedNits)
{
    return ApplyBoostWithBT2390Rolloff(signalLuma, currentAPL, anchorBoostedNits);
}

float ApplyBoostWithSelectedRolloffFromSceneLogGain(float signalLuma, float sceneLogGain, float anchorBoostedNits)
{
    if (APLInputMode == 1)
    {
        float originalNits     = PQToLinearScalar(signalLuma) * 10000.0;
        float safeOriginalNits = max(originalNits, 0.0);
        float pixelGain        = ComputePixelGainFromSceneLogGain(sceneLogGain, safeOriginalNits);
        float fullyBoostedNits = safeOriginalNits * pixelGain;
        float rollOffEndNits   = max(BoostRollOff, 0.0);

        if (rollOffEndNits <= 0.0)
            return NitsToPQ(fullyBoostedNits);

        float sourcePeakNits   = max(anchorBoostedNits, rollOffEndNits + 1e-4);
        float rolledPQ = ApplyBT2390EETFToPQWithShape(NitsToPQ(fullyBoostedNits), sourcePeakNits, rollOffEndNits, BoostRollOffShape);

        // The BT.2390 mapping is monotonic in PQ space, so the original-signal floor
        // can still be enforced directly on the encoded value.
        return max(rolledPQ, signalLuma);
    }

    return ApplyBoostWithBT2390RolloffFromSceneLogGain(signalLuma, sceneLogGain, anchorBoostedNits);
}

float ComputeBoostedLumaNitsFromSceneLogGain(float inputLumaNits, float sceneLogGain, float anchorBoostedNits)
{
    float safeInputLumaNits = max(inputLumaNits, 0.0);
    float fullyBoostedNits = safeInputLumaNits * ComputePixelGainFromSceneLogGain(sceneLogGain, safeInputLumaNits);
    float rollOffEndNits = max(BoostRollOff, 0.0);

    if (rollOffEndNits <= 0.0)
        return fullyBoostedNits;

    float sourcePeakNits = max(anchorBoostedNits, rollOffEndNits + 1e-4);
    return max(ApplyBT2390EETFToNitsWithShape(fullyBoostedNits, sourcePeakNits, rollOffEndNits, BoostRollOffShape), safeInputLumaNits);
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

float3 ApplyBoostPreserveColorFromSceneLogGain(float3 color, float sceneLogGain, float anchorBoostedNits)
{
    if (APLInputMode == 1)
    {
        float3 linearColorNits = PQToLinearBT2100(saturate(color)) * 10000.0;
        float originalLumaNits = max(GetLuma2020(linearColorNits), 0.0);

        if (originalLumaNits <= 1e-6)
            return color;

        float boostedLumaNits = ComputeBoostedLumaNitsFromSceneLogGain(originalLumaNits, sceneLogGain, anchorBoostedNits);
        float colorScale = boostedLumaNits / originalLumaNits;
        float3 boostedColorNits = linearColorNits * colorScale;
        float3 saturatedColorNits = ApplySaturationAdjustment2020Nits(boostedColorNits, SaturationComp);

        // Re-encode all three channels in one vector call (2 vector pow) instead of
        // three separate scalar calls (6 scalar pow).
        return LinearToPQBT2100(saturate(max(saturatedColorNits, 0.0) / 10000.0));
    }

    float3 linearColor = color;
    float originalLumaNits = max(GetLuma709(max(linearColor, 0.0.xxx)) * SIGNAL_REFERENCE_NITS, 0.0);

    if (originalLumaNits <= 1e-6)
        return color;

    float boostedLumaNits = ComputeBoostedLumaNitsFromSceneLogGain(originalLumaNits, sceneLogGain, anchorBoostedNits);
    float colorScale = boostedLumaNits / originalLumaNits;
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
    1.275485, 1.279098, 1.298112, 1.311262, 1.320233, 1.306626, 1.336365, 1.320144,
    1.337008, 1.337614, 1.354279, 1.352556, 1.347158, 1.353409, 1.354995, 1.357722,
    1.360410, 1.379355, 1.375188, 1.377428, 1.380128, 1.378296, 1.394903, 1.403779,

    // APL 7
    1.636865, 1.586585, 1.600228, 1.632120, 1.646603, 1.656140, 1.653732, 1.648574,
    1.659723, 1.638967, 1.676518, 1.673813, 1.667162, 1.672429, 1.678772, 1.682167,
    1.684833, 1.688457, 1.682479, 1.705485, 1.708849, 1.722217, 1.732755, 1.743012,

    // APL 10
    2.222370, 2.139135, 2.131274, 2.103239, 2.119450, 2.139539, 2.144950, 2.119860,
    2.154030, 2.144674, 2.181553, 2.151376, 2.139477, 2.150906, 2.153600, 2.140693,
    2.162291, 2.190399, 2.181303, 2.170379, 2.194950, 2.195467, 2.208124, 2.226317,

    // APL 14
    2.574646, 2.466301, 2.477981, 2.440763, 2.439207, 2.453153, 2.457554, 2.437744,
    2.459988, 2.467005, 2.474901, 2.455437, 2.446400, 2.453859, 2.454635, 2.467066,
    2.467625, 2.465686, 2.466095, 2.466487, 2.476404, 2.484286, 2.496364, 2.518080,

    // APL 18
    2.748700, 2.653554, 2.657380, 2.630880, 2.595614, 2.617234, 2.624612, 2.604644,
    2.621808, 2.624117, 2.640117, 2.636610, 2.604680, 2.617061, 2.615594, 2.612188,
    2.617207, 2.621120, 2.624654, 2.626987, 2.640365, 2.633628, 2.665580, 2.675877,

    // APL 22
    2.916959, 2.818433, 2.786699, 2.777913, 2.748502, 2.748234, 2.764812, 2.754077,
    2.767587, 2.764558, 2.776648, 2.760512, 2.734844, 2.742903, 2.740379, 2.745571,
    2.753666, 2.757212, 2.750390, 2.758649, 2.770630, 2.772743, 2.790399, 2.814688,

    // APL 25
    3.005716, 2.911831, 2.892784, 2.875547, 2.824210, 2.833016, 2.856895, 2.834469,
    2.853785, 2.843423, 2.864118, 2.839076, 2.816207, 2.827746, 2.825887, 2.840115,
    2.842497, 2.844660, 2.835615, 2.839335, 2.859106, 2.857170, 2.876447, 2.900269,

    // APL 35
    3.227778, 3.139621, 3.086106, 3.101464, 3.053503, 3.050585, 3.063989, 3.034956,
    3.074032, 3.056235, 3.082187, 3.064304, 3.033025, 3.038294, 3.037854, 3.051513,
    3.057893, 3.059339, 3.042766, 3.063924, 3.067941, 3.076905, 3.098045, 3.124520,

    // APL 50
    3.605147, 3.469041, 3.422317, 3.396852, 3.379085, 3.350383, 3.331431, 3.333736,
    3.385554, 3.346382, 3.380603, 3.345667, 3.325029, 3.308191, 3.317324, 3.329362,
    3.338411, 3.331323, 3.321922, 3.330550, 3.342307, 3.347892, 3.376754, 3.407354
};


static const int FULLFIELD_100_COUNT = 33;

static const float FULLFIELD_100_INPUT_NITS[FULLFIELD_100_COUNT] =
{
    0.000000, 0.011931, 0.054452, 0.138304, 0.282443, 0.521309, 0.865680, 1.384067,
    2.082348, 3.035066, 4.374848, 6.086059, 8.324707, 11.363916, 15.134164, 19.949442,
    26.352272, 34.156536, 43.978027, 56.870362, 72.413132, 92.698470, 117.036078, 147.265282,
    186.502536, 233.369755, 291.383762, 368.488542, 460.037005, 571.771366, 720.083776, 901.023134,
    1040.932000
};

static const float FULLFIELD_100_MEASURED_NITS[FULLFIELD_100_COUNT] =
{
    0.000000, 0.000000, 0.025553, 0.118012, 0.288831, 0.591004, 0.975432, 1.522651,
    2.381936, 3.378590, 5.068168, 6.945428, 9.627818, 12.967435, 16.961642, 20.195403,
    23.503979, 30.959431, 35.582524, 38.937325, 42.492201, 45.812047, 49.682839, 59.134684,
    70.803150, 84.266779, 100.396451, 118.819227, 141.396332, 169.118513, 202.873554, 239.232825,
    265.021011
};


static const int FULLFIELD_50_COUNT = 33;

static const float FULLFIELD_50_MEASURED_NITS[FULLFIELD_50_COUNT] =
{
    0.000000, 0.000000, 0.019611, 0.097831, 0.249949, 0.526106, 0.889249, 1.411673,
    2.227720, 3.168462, 4.802616, 6.558748, 9.185429, 12.424980, 16.227606, 19.369587,
    23.859118, 31.436385, 40.137642, 53.197343, 65.392805, 74.547320, 80.127169, 85.519747,
    92.611297, 100.748551, 119.449653, 140.743873, 168.553173, 197.406956, 239.022413, 280.116401,
    310.507285
};

static const int FULLFIELD_25_COUNT = 33;

static const float FULLFIELD_25_MEASURED_NITS[FULLFIELD_25_COUNT] =
{
    0.000000, 0.000000, 0.020193, 0.098958, 0.253351, 0.530072, 0.894046, 1.417652,
    2.236172, 3.175224, 4.814092, 6.578921, 9.210201, 12.453936, 16.233701, 19.360823,
    24.324769, 31.664910, 40.662945, 53.441695, 68.002699, 88.193059, 111.606274, 135.299708,
    149.261837, 161.082050, 170.971315, 185.138530, 201.136027, 235.942743, 283.942968, 331.624744,
    366.448525
};

static const int FULLFIELD_15_COUNT = 33;

static const float FULLFIELD_15_MEASURED_NITS[FULLFIELD_15_COUNT] =
{
    0.000000, 0.000000, 0.024520, 0.114708, 0.280640, 0.581359, 0.958295, 1.494907,
    2.323773, 3.286472, 4.984005, 6.824739, 9.518044, 12.823650, 16.687334, 19.874191,
    24.870417, 32.192746, 41.126911, 53.811406, 68.639696, 88.228024, 111.933290, 142.016629,
    178.322722, 218.856152, 244.621474, 264.975028, 281.601565, 304.076471, 324.154317, 379.958739,
    415.885700
};

static const int FULLFIELD_10_COUNT = 33;

static const float FULLFIELD_10_MEASURED_NITS[FULLFIELD_10_COUNT] =
{
    0.000000, 0.000000, 0.023311, 0.111391, 0.276822, 0.572010, 0.949903, 1.489990,
    2.313793, 3.300262, 4.981862, 6.854603, 9.544428, 12.853254, 16.722919, 20.305498,
    26.128305, 33.665465, 42.636117, 55.207774, 69.932789, 89.672005, 112.739759, 141.994701,
    180.269676, 227.876442, 287.603899, 341.189386, 373.286063, 402.007822, 430.822267, 464.211151,
    474.045533
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

float SampleApproxMeasuredOutputNitsForAPL(float aplPct, float targetNits)
{
    float comp = max(LookupMeasuredComp1D(aplPct), 1e-6);
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

float GraphAxisCoordinate(float nits, float axisMaxNits)
{
    float safeAxisMaxNits = max(axisMaxNits, 1.0);
    float axisMaxPQ = GraphUsePQSpace ? max(NitsToPQ(safeAxisMaxNits), 1e-6) : 0.0;
    return GraphAxisCoordinateWithPQMax(nits, safeAxisMaxNits, axisMaxPQ);
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

float GraphTickValueFromFraction(float frac, float axisMaxNits)
{
    float safeAxisMaxNits = max(axisMaxNits, 1e-6);
    float axisMaxPQ = GraphUsePQSpace ? max(NitsToPQ(safeAxisMaxNits), 1e-6) : 0.0;
    return GraphTickValueFromFractionWithPQMax(frac, safeAxisMaxNits, axisMaxPQ);
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

float2 ToGraphPoint(float2 graphPos, float2 graphSize, float axisMaxNits, float xNits, float yNits)
{
    float safeAxisMaxNits = max(axisMaxNits, 1.0);
    float axisMaxPQ = GraphUsePQSpace ? max(NitsToPQ(safeAxisMaxNits), 1e-6) : 0.0;
    return ToGraphPointWithPQMax(graphPos, graphSize, safeAxisMaxNits, axisMaxPQ, xNits, yNits);
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
    // .b is now the smoothed High APL % metric, so sceneLogGain moves to .a and the live pass
    // recomputes the rolloff anchor from that value.
    float sceneLogGain = ComputeSceneLogGainFromAPL(smoothedAPL, smoothedHighAPLMetric);

    // r = smoothed closed-loop display-side APL metric, g = smoothed max sampled decoded scene nits,
    // b = smoothed High APL % metric, a = precomputed scene log-gain (uniform across all pixels)
    return float4(smoothedAPL, smoothedMaxSampledNits, smoothedHighAPLMetric, sceneLogGain);
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

    float rollOffAnchorBoostedNits = ComputeRollOffAnchorBoostedNitsFromSceneLogGain(sceneLogGain);
    float3 finalColor = ApplyBoostPreserveColorFromSceneLogGain(color, sceneLogGain, rollOffAnchorBoostedNits);

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
    float graphRollOffStartNits = SolveDynamicRollOffStartNits(graphClosedLoopAPL);
    float maxMeasuredNits = GetAPLMaxMeasuredNits(graphClosedLoopAPLPercent);
    float graphAnchorBoostedNits = ComputeRollOffAnchorBoostedNits(graphClosedLoopAPL);

    return float4(graphRollOffStartNits, maxMeasuredNits, graphAxisMaxPQ, graphAnchorBoostedNits);
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
    float  graphClosedLoopAPL        = ComputeGraphClosedLoopAPLFromRawPercent(graphRawAPLPercent);
    float  graphClosedLoopAPLPercent = graphClosedLoopAPL * 100.0;
    float  graphRollOffStartNits     = graphParams.r;
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
