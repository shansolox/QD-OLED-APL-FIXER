/*
    EOTF Boost v8.7.1.2F - 1D APL Lookup + Optional High APL Adaptive Boost
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
    UI_TOOLTIP("Selects how the shader interprets scene luminance for the APL metric. scRGB uses BT.709 luma scaled by Reference White. PQ uses ST.2084-decoded BT.2020 luma scaled by Reference White."[...])
> = 1;

uniform float APLReferenceWhiteNits <
    ui_type = "slider";
    ui_min = 10.0; ui_max = 1500.0; ui_step = 1.0;
    ui_label = "APL Reference White (nits)";
    UI_TOOLTIP("Reference white used only for the APL metric normalization. It does not directly clamp output nits or change the graph axes.")
> = 1000.0;

uniform float APLTrigger <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.95; ui_step = 0.01;
    ui_label = "APL Trigger";
    UI_TOOLTIP("Boost fade-in start threshold based on the smoothed APL metric. Below this level the effect is disabled. With APL Trigger Fade Width = 0, this remains a hard on/off threshold. 10% APL on the graph is exactly the threshold when this is set to [...]
> = 0.00;

uniform float APLTriggerFadeWidth <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.50; ui_step = 0.01;
    ui_label = "APL Trigger Fade Width";
    UI_TOOLTIP("Width of the APL Trigger fade-in range. 0 = original hard trigger. Example: Trigger 0.10 and Fade Width 0.05 means boost fades from 0 at 10% APL to full strength at 15% APL.")
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
    UI_TOOLTIP("Scales the measured APL compensation in log-gain space before per-pixel participation is applied. 1.0 means full measured compensation at maximum LUT weight. Values below 1.0 under-compensate [...]
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
    UI_TOOLTIP("Allows higher boost strength in lower-nit scenes. A secondary High APL % metric is built from the configured nit range and reduces the final scene boost from the adaptive maximum back toward the normal APL-based boost strength over the configured range [...]
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
    UI_TOOLTIP("Maximum boost strength allowed when the High APL % metric is very low. The actual scene boost then transitions from this value toward the normal APL-based boost strength over the configured range [...]
> = 0.9;

uniform float BoostRollOff <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1500.0; ui_step = 1.0;
    ui_label = "Boost Roll-Off Target (nits)";
    UI_TOOLTIP("Desired output anchor of the PQ highlight rolloff in nits. The shader dynamically places the knee from the current smoothed APL so the boosted curve lands on this endpoint more consistently [...]
> = 1000.0;

uniform float BoostRollOffShape <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 4.0; ui_step = 0.01;
    ui_label = "Boost Roll-Off Shape";
    UI_TOOLTIP("Adjusts the live roll off character by moving the roll off start together with the shoulder curvature so the transition stays smooth and monotonic. 1.0 = standard BT.2390. Values below [...]
> = 1.25;


static const float PixelParticipationStartNits = 1.0;

static const float PixelParticipationFullNits = 40.0;

static const float PixelParticipationGamma = 1.0;

uniform float PixelParticipationFloor <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Shadow Protection Floor";
    UI_TOOLTIP("Minimum share of the APL-derived scene compensation applied to every pixel before the luminance-weighted participation ramp adds the remainder. Higher values track the measured ABL behavior [...]
> = 1.0;

uniform float TransitionSpeed <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "APL Smoothing Time (s)";
    UI_TOOLTIP("Temporal smoothing time constant for the live APL-related metrics in seconds. 0 = disabled. FPS-independent. This affects live boosting and OSD values, but the graph uses its own Graph [...]
> = 0.25;

uniform float SaturationComp <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
    ui_label = "Saturation Compensation";
    UI_TOOLTIP("Adjusts color saturation after the color-preserving luminance boost. 1.0 = neutral. Lower values reduce saturation. Higher values increase saturation while preserving the boosted [...]
> = 1.0;

uniform float EnableColorPreservingBoostMode <
    ui_type = "slider";
    ui_min = 0.75; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Preserve Color by Reducing Boost";
    UI_TOOLTIP("When enabled, saturated colors keep their RGB ratio by reducing only the added boost before channels would exceed the Boost Roll-Off Target. Variable. Original behavior is unchanged [...]
> = 1.0;

uniform float SIGNAL_REFERENCE_NITS <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 200.0; ui_step = 1.0;
    ui_label = "scRGB Signal Reference (nits)";
    UI_TOOLTIP("Reference nits for scRGB signal conversion. Standard scRGB uses 80 nits per 1.0 signal. Used only when APL Input Mode = scRGB Normalized.")
> = 80.0;


uniform bool ShowOSD <
    ui_label = "Show APL / Metric Stats";
    UI_TOOLTIP("Displays the current raw input APL (green), smoothed output/display-side APL (yellow), maximum sampled decoded scene luminance in nits (cyan), High APL % (orange), and current final [...]
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
    UI_TOOLTIP("Shows the analysis graph. Standard mode: Blue dashed = identity reference, optional Magenta dashed = BT.2390-style reference tone map using the projected measured peak for the selected [...]
> = true;

uniform bool GraphShowBT2390Reference <
    ui_label = "Graph Show BT.2390 Reference";
    UI_TOOLTIP("Shows or hides the optional BT.2390-style Hermite rolloff reference overlay. It uses the measured peak for the selected APL or selected window size.")
> = false;

uniform bool GraphUseFullFieldWindowProjection <
    ui_label = "Graph Use Window Projection";
    UI_TOOLTIP("Switches the debug graph to the built-in window PQ measurement projection overlay. In this mode, Graph APL (%) is ignored. Use the window selector below to choose between the built-in [...]
> = true;

uniform int GraphProjectionWindowSize <
    ui_type = "combo";
    ui_items = "100% Window\0 50% Window\0 25% Window\0 15% Window\0 10% Window\0";
    ui_label = "Graph Projection Window Size";
    UI_TOOLTIP("Selects which built-in measured window set is used by the full-field projection graph mode.")
> = 0;

uniform float GraphAPLIndex <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 50.0; ui_step = 0.01;
    ui_label = "Graph APL (%)";
    UI_TOOLTIP("Continuous raw / pre-boost input APL value used by the standard APL-slice graph mode. Light blue = measured curve for that raw input APL. Green = shader remapped target projected from [...]
> = 50.0;

uniform float GraphInputSignalLimitNits <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4000.0; ui_step = 1.0;
    ui_label = "Graph Input Signal Limit (nits)";
    UI_TOOLTIP("Graph-only input signal cap used for curve preview. 0 = disabled. When set above 0, the graph behaves as if input signal values above this nit level were clipped to the specified [...]
> = 0.0;

uniform float GraphAxisMaxNits <
    ui_type = "slider";
    ui_min = 100.0; ui_max = 10000.0; ui_step = 1.0;
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
    10.302358, 13.132379, 16.611621, 20.870708, 26.064850, 32.378420, 40.030390, 49.280814, 60.438551, 73.870492, 90.012580, 109.383004, 132.598006, 160.390856, 193.634650, 233.369755, 280.836899, 337.661956, 405.998627, 487.305274, 584.002533, 698.661499, 835.327332, 1000.000000
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
    float triggerStart = saturate(APLTrigger);
    float fadeWidth = max(APLTriggerFadeWidth, 0.0);

    if (fadeWidth <= 1e-6)
        return step(triggerStart, currentAPL);

    float triggerEnd = min(triggerStart + fadeWidth, 1.0);
    return Remap01(currentAPL, triggerStart, max(triggerEnd, triggerStart + 1e-6));
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
