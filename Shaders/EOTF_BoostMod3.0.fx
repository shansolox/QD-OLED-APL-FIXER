/*
    EOTF Boost v8.18.7.15
    Calibrated for 3rd gen QD-OLEDS TB400

    Applies a scene-uniform HDR gain from a measured 1D APL compensation table.

        scene gain = compensation(solved APL) ^ strength

    A rolling full-frame histogram estimates raw APL and three boosted response
    points. A bracketed solver finds display-side APL, then temporal smoothing
    produces the final gain. PQ highlight roll-off removes added boost near the
    configured target. The boost stage never falls below the source signal.

    Live pipeline:
      1. Frame setup and rolling-row clear
      2. Full-frame row histogram build
      3. Global histogram reduction
      4. Response solve, smoothing, and boost parameters
      5. Fullscreen boost and optional calibration LUT

    Max Raw Nits is tracked only while the OSD is visible.
    Rolling phases advance per shader execution, independent of presented-frame count.
*/

#include "ReShade.fxh"

#ifndef BUFFER_COLOR_SPACE
    #define BUFFER_COLOR_SPACE 0
#endif


// Compile-time features.
#ifndef PQHDRLUT_ENABLE
    #define PQHDRLUT_ENABLE 0
#endif


#ifndef PER_APL_BOOST_STRENGTH_ENABLE
    #define PER_APL_BOOST_STRENGTH_ENABLE 0
#endif


#ifndef ENABLE_APL_GRAPH
    #define ENABLE_APL_GRAPH 0
#endif

#ifndef ENABLE_UI_TOOLTIPS
    #define ENABLE_UI_TOOLTIPS 0
#endif


// Full-frame histogram layout. Each 16x16 group processes one 32x32 pixel tile.
#define APL_FFH_TILE_SIZE             32
#define APL_FFH_THREADS_X             16
#define APL_FFH_THREADS_Y             16
#define APL_FFH_PIXELS_X               2
#define APL_FFH_PIXELS_Y               2
#define APL_FFH_LUMA_BINS              64
#define APL_FFH_COLOR_LUMA_BINS        64
#define APL_FFH_COLOR_RATIO_BINS        4
#define APL_FFH_MAX_BINS              256
#define APL_FFH_BLOCK_W                16
#define APL_FFH_BLOCK_H                16
#define APL_FFH_AUX_X                  APL_FFH_BLOCK_W
#define APL_FFH_REDUCE_THREADS         64


// Packed value: pixel count in the upper bits and summed bin position in the lower bits.
#define APL_FFH_PACK_COUNT_SHIFT       20
#define APL_FFH_PACK_OFFSET_MASK       ((1 << APL_FFH_PACK_COUNT_SHIFT) - 1)
#define APL_FFH_PACK_OFFSET_SCALE      1023
#define APL_FFH_PACK_ONE_COUNT         (1 << APL_FFH_PACK_COUNT_SHIFT)

#define APL_FFH_TILE_COUNT_X ((BUFFER_WIDTH  + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)
#define APL_FFH_TILE_COUNT_Y ((BUFFER_HEIGHT + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)


// Persistent 16x16 histogram block for each 32-pixel-high screen row.
#define APL_FFH_ROW_HIST_TEX_W APL_FFH_BLOCK_W
#define APL_FFH_ROW_COUNT_TEX_W (APL_FFH_BLOCK_W + 1)
#define APL_FFH_ROW_TEX_H (APL_FFH_TILE_COUNT_Y * APL_FFH_BLOCK_H)


// 0 refreshes all rows each frame. N refreshes one of N interleaved row phases.
#ifndef APL_FULLFRAME_ROLLING_PHASES
    #define APL_FULLFRAME_ROLLING_PHASES 6
#endif

#if APL_FULLFRAME_ROLLING_PHASES < 0
    #error "APL_FULLFRAME_ROLLING_PHASES must be >= 0"
#endif

#if APL_FULLFRAME_ROLLING_PHASES > APL_FFH_TILE_COUNT_Y
    #error "APL_FULLFRAME_ROLLING_PHASES cannot exceed the number of full-frame tile rows"
#endif

#if APL_FULLFRAME_ROLLING_PHASES > 0
    #define APL_FFH_ROLLING_ROW_SLOTS ((APL_FFH_TILE_COUNT_Y + APL_FULLFRAME_ROLLING_PHASES - 1) / APL_FULLFRAME_ROLLING_PHASES)


    // Metadata stores a runtime signature and the completed row pixel count.
    #define APL_FFH_ROW_META_COUNT_BITS 20
    #define APL_FFH_ROW_META_COUNT_MASK ((1 << APL_FFH_ROW_META_COUNT_BITS) - 1)
    #if (BUFFER_WIDTH * APL_FFH_TILE_SIZE) > APL_FFH_ROW_META_COUNT_MASK
        #error "Rolling full-frame row pixel count exceeds the 20-bit metadata field"
    #endif
#else
    #define APL_FFH_ROLLING_ROW_SLOTS APL_FFH_TILE_COUNT_Y
#endif

#if (APL_FFH_THREADS_X * APL_FFH_PIXELS_X != APL_FFH_TILE_SIZE) || (APL_FFH_THREADS_Y * APL_FFH_PIXELS_Y != APL_FFH_TILE_SIZE)
    #error "Full-frame APL histogram tile/thread dimensions are inconsistent"
#endif
#if (APL_FFH_BLOCK_W * APL_FFH_BLOCK_H != APL_FFH_MAX_BINS)
    #error "Full-frame APL histogram block dimensions do not match maximum bin count"
#endif
#if (APL_FFH_COLOR_LUMA_BINS * APL_FFH_COLOR_RATIO_BINS != APL_FFH_MAX_BINS)
    #error "Color-preserving full-frame APL histogram dimensions are inconsistent"
#endif


// UI tooltips can be removed at compile time.
#if ENABLE_UI_TOOLTIPS
    #define UI_TOOLTIP(text) ui_tooltip = text;
#else
    #define UI_TOOLTIP(text)
#endif


#if PQHDRLUT_ENABLE

#ifndef PQHDRLUT_SIZE
    #define PQHDRLUT_SIZE 65
#endif
#endif


// User settings.
uniform bool EnableEOTFBoost <
    ui_label = "Enable EOTF Boost";
    UI_TOOLTIP("Enables APL-based HDR brightness compensation.")
> = true;

uniform int APLInputMode <
    ui_type = "combo";
    ui_items = "scRGB Normalized\0PQ Decoded Normalized\0";
    ui_label = "APL Input Mode";
    UI_TOOLTIP("Selects scRGB or PQ decoding for APL and boost processing.")
> = 1;

uniform float APLReferenceWhiteNits <
    ui_type = "slider";
    ui_min = 10.0; ui_max = 1500.0; ui_step = 1.0;
    ui_label = "APL Reference White (nits)";
    UI_TOOLTIP("Sets the luminance represented by 100% APL.")
> = 1000.0;

uniform float CompensationFreezeAPLPercent <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 95.0; ui_step = 0.1;
    ui_label = "Compensation Freeze APL %";
    UI_TOOLTIP("Holds compensation at this solved APL for all higher APL values. 0 disables it.")
> = 50.0;

uniform float MaxAPLBoostStrength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "Global APL Boost Strength";
    UI_TOOLTIP("Scales measured compensation. 1.0 applies the full correction.")
> = 0.5;


#if PER_APL_BOOST_STRENGTH_ENABLE
uniform bool EnablePerAPLBoostStrength <
    ui_label = "Enable Per-APL Boost Strength";
    UI_TOOLTIP("Uses the per-APL strength controls instead of the global strength.")
> = true;

uniform float APLBoostStrength03 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 3% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 3% APL.")
> = 0.4;

uniform float APLBoostStrength05 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 5% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 5% APL.")
> = 0.8;

uniform float APLBoostStrength07 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 7% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 7% APL.")
> = 0.9;

uniform float APLBoostStrength10 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 10% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 10% APL.")
> = 0.8;

uniform float APLBoostStrength14 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 14% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 14% APL.")
> = 0.65;

uniform float APLBoostStrength18 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 18% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 18% APL.")
> = 0.54;

uniform float APLBoostStrength22 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 22% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 22% APL.")
> = 0.5;

uniform float APLBoostStrength25 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 25% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 25% APL.")
> = 0.5;

uniform float APLBoostStrength35 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 35% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 35% APL.")
> = 0.5;

uniform float APLBoostStrength50 <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Advanced Per-APL Boost Strength";
    ui_category_closed = true;
    ui_label = "APL 50% Boost Strength";
    UI_TOOLTIP("Sets boost strength at 50% APL.")
> = 0.5;
#endif


uniform float BoostRollOff <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1500.0; ui_step = 1.0;
    ui_label = "Boost Roll-Off Target (nits)";
    UI_TOOLTIP("Sets the luminance where added boost fades to zero.")
> = 1000.0;

uniform float BoostRollOffShape <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 4.0; ui_step = 0.01;
    ui_label = "Boost Roll-Off Shape";
    UI_TOOLTIP("Controls the roll-off knee. Lower values start later; higher values start earlier.")
> = 1.25;


uniform float TransitionSpeed <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "APL Smoothing Time (s)";
    UI_TOOLTIP("Smooths APL changes over time. 0 disables smoothing.")
> = 0.25;

uniform bool EnableColorPreservingBoostMode <
    ui_label = "Preserve Color by Reducing Boost";
    UI_TOOLTIP("Reduces added boost near channel limits to preserve RGB ratios.")
> = false;

static const float COLOR_PRESERVING_BOOST_KNEE = 0.85;

uniform float SIGNAL_REFERENCE_NITS <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 200.0; ui_step = 1.0;
    ui_label = "scRGB Signal Reference (nits)";
    UI_TOOLTIP("Sets the nits represented by scRGB value 1.0.")
> = 80.0;


#if PQHDRLUT_ENABLE
uniform bool EnablePQHDRLUT <
    ui_label = "Enable PQ HDR LUT";
    UI_TOOLTIP("Applies PQHDRLUT.cube after boost, or directly when boost is disabled.")
> = true;

uniform int PQHDRLUTInputColorSpace <
    ui_category = "Optional HDR LUT Calibration";
    ui_category_closed = true;
    ui_type = "combo";
    ui_items = "Auto\0HDR10 PQ / Rec.2020\0scRGB / linear Rec.709\0";
    ui_label = "LUT Input Color Space";
    UI_TOOLTIP("Selects the LUT input color space. Auto uses ReShade's reported buffer color space.")
> = 0;
#endif

uniform bool ShowOSD <
    ui_label = "Show APL Stats";
    UI_TOOLTIP("Shows raw APL, solved APL, and Max Raw Nits. Max tracking runs only while visible.")
> = false;

uniform float OSDBrightness <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 1.0; ui_step = 0.01;
    ui_label = "OSD Brightness";
    UI_TOOLTIP("Sets OSD and graph brightness.")
> = 0.5;

uniform float FrameTime < source = "frametime"; >;

#if ENABLE_APL_GRAPH
uniform bool ShowAPLGraph <
    ui_label = "Show APL EOTF Debug Graph";
    UI_TOOLTIP("Shows identity, measured, remapped, predicted-output, and optional BT.2390 reference curves.")
> = true;

uniform bool GraphShowBT2390Reference <
    ui_label = "Graph Show BT.2390-Style Reference";
    UI_TOOLTIP("Shows the BT.2390-style reference curve.")
> = false;

uniform bool GraphUseFullFieldWindowProjection <
    ui_label = "Graph Use Window Projection";
    UI_TOOLTIP("Uses measured window data instead of the fixed-APL graph.")
> = true;

uniform int GraphProjectionWindowSize <
    ui_type = "combo";
    ui_items = "100% Window\0 50% Window\0 25% Window\0 15% Window\0 10% Window\0";
    ui_label = "Graph Projection Window Size";
    UI_TOOLTIP("Selects the measured window data used by the graph.")
> = 0;

uniform float GraphAPLIndex <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 50.0; ui_step = 0.01;
    ui_label = "Graph APL (%)";
    UI_TOOLTIP("Sets the raw APL used by the fixed-APL graph.")
> = 50.0;

uniform float GraphInputSignalLimitNits <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4000.0; ui_step = 1.0;
    ui_label = "Graph Input Signal Limit (nits)";
    UI_TOOLTIP("Caps the graph input signal. 0 disables the cap.")
> = 0.0;

uniform float GraphAxisMaxNits <
    ui_type = "slider";
    ui_min = 100.0; ui_max = 10000.0; ui_step = 1.0;
    ui_label = "Graph Axis Max (nits)";
    UI_TOOLTIP("Sets the maximum value shown on both graph axes.")
> = 1000.0;

uniform float GraphOpacity <
    ui_type = "slider";
    ui_min = 0.05; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Graph Opacity";
    UI_TOOLTIP("Sets graph opacity.")
> = 0.5;

uniform bool GraphUsePQSpace <
    ui_label = "Graph PQ-Encoded Axes";
    UI_TOOLTIP("Uses PQ spacing on the graph axes while labels remain in nits.")
> = true;
#endif


// GPU state and histogram resources.
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
storage2D<float4> StorageAPL
{
    Texture = TexAPL;
};


// Three candidate roll-off parameter sets at gMax/3, 2*gMax/3, and gMax.
texture TexCandidateBoostParams
{
    Width = 3;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerCandidateBoostParams
{
    Texture = TexCandidateBoostParams;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float4> StorageCandidateBoostParams
{
    Texture = TexCandidateBoostParams;
};


// Final boost parameters: gain, PQ range, knee, and compression span.
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
storage2D<float4> StorageBoostParams
{
    Texture = TexBoostParams;
};

#if PQHDRLUT_ENABLE
texture3D PQHDRLUTTexture <
    source = "PQHDRLUT.cube";
>
{
    Width = PQHDRLUT_SIZE;
    Height = PQHDRLUT_SIZE;
    Depth = PQHDRLUT_SIZE;
    Format = RGBA32F;
};

sampler3D PQHDRLUTSampler
{
    Texture = PQHDRLUTTexture;
    AddressU = CLAMP;
    AddressV = CLAMP;
    AddressW = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};

#endif

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
storage2D<float4> StorageAPLInstant
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
storage2D<float4> StorageAPLPrev
{
    Texture = TexAPLPrev;
};


// Exact 129-node PQ decode table used with linear filtering.
texture TexAPLFastPQNits
{
    Width = 129;
    Height = 1;
    Format = R32F;
};
sampler SamplerAPLFastPQNits
{
    Texture = TexAPLFastPQNits;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = POINT;
};
storage2D<float> StorageAPLFastPQNits
{
    Texture = TexAPLFastPQNits;
};


// Persistent row histograms. The count texture also stores the row maximum.
texture TexAPLRowHistCount
{
    Width = APL_FFH_ROW_COUNT_TEX_W;
    Height = APL_FFH_ROW_TEX_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowHistCount
{
    Texture = TexAPLRowHistCount;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowHistCount
{
    Texture = TexAPLRowHistCount;
};

texture TexAPLRowHistOffset10
{
    Width = APL_FFH_ROW_HIST_TEX_W;
    Height = APL_FFH_ROW_TEX_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowHistOffset10
{
    Texture = TexAPLRowHistOffset10;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowHistOffset10
{
    Texture = TexAPLRowHistOffset10;
};


texture TexAPLRowHistMaxNits
{
    Width = APL_FFH_ROW_HIST_TEX_W;
    Height = APL_FFH_ROW_TEX_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowHistMaxNits
{
    Texture = TexAPLRowHistMaxNits;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowHistMaxNits
{
    Texture = TexAPLRowHistMaxNits;
};

#if APL_FULLFRAME_ROLLING_PHASES > 0


// Rolling-row validity metadata.
texture TexAPLRowMeta
{
    Width = 1;
    Height = APL_FFH_TILE_COUNT_Y;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowMeta
{
    Texture = TexAPLRowMeta;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowMeta
{
    Texture = TexAPLRowMeta;
};
#endif

texture TexAPLGlobalHistCount
{
    Width = APL_FFH_BLOCK_W + 1;
    Height = APL_FFH_BLOCK_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLGlobalHistCount
{
    Texture = TexAPLGlobalHistCount;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLGlobalHistCount
{
    Texture = TexAPLGlobalHistCount;
};


// Global histogram sums generated after all row writes complete.
texture TexAPLGlobalHistOffset10
{
    Width = APL_FFH_BLOCK_W;
    Height = APL_FFH_BLOCK_H;
    Format = R32F;
};
sampler2D<float> SamplerAPLGlobalHistOffset10
{
    Texture = TexAPLGlobalHistOffset10;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float> StorageAPLGlobalHistOffset10
{
    Texture = TexAPLGlobalHistOffset10;
};

texture TexAPLGlobalHistMaxNits
{
    Width = APL_FFH_BLOCK_W;
    Height = APL_FFH_BLOCK_H;
    Format = R32F;
};
sampler2D<float> SamplerAPLGlobalHistMaxNits
{
    Texture = TexAPLGlobalHistMaxNits;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float> StorageAPLGlobalHistMaxNits
{
    Texture = TexAPLGlobalHistMaxNits;
};


#if ENABLE_APL_GRAPH


#define GRAPH_CURVE_SAMPLES 64

// Graph curve rows: remapped signal, predicted output, measured output, reference.


#define GCURVE_REMAPPED  0
#define GCURVE_CORRECTED 1
#define GCURVE_MEASURED  2
#define GCURVE_BT2390REF 3

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


// Per-sample graph projection: remapped nits, predicted output, solved APL, valid flag.
texture TexGraphProjection
{
    Width  = GRAPH_CURVE_SAMPLES;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerGraphProjection
{
    Texture   = TexGraphProjection;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};


// Screen-space line segments for the four graph curves.
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


#define GRAPH_LINE_COUNT 32
// Screen-space grid, tick, and identity-line segments.
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

#endif


float GetLuma709(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float GetLuma2020(float3 color)
{
    return dot(color, float3(0.2627, 0.6780, 0.0593));
}

// ST.2084 transfer functions.
float3 PQToLinearBT2100(float3 v)
{

    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float3 vp = pow(saturate(v), 1.0 / m2);
    float3 num = max(vp - c1, 0.0);
    float3 den = c2 - c3 * vp;
    return pow(num / max(den, 1e-6), 1.0 / m1);
}

float LinearToPQBT2100(float linearValue)
{

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
    return pow(num / max(den, 1e-6), 1.0 / m1); // Relative to 10000 nits.
}

float NitsToPQ(float nits)
{
    return LinearToPQBT2100(saturate(nits / 10000.0));
}

bool NeedsAPLProcessing()
{
    return EnableEOTFBoost;
}

// Optional PQ Rec.2020 calibration LUT.
#if PQHDRLUT_ENABLE


float3 PQHDRLUT_PQ_To_Nits(float3 pq)
{
    return PQToLinearBT2100(max(pq, 0.0)) * 10000.0;
}

float3 PQHDRLUT_Nits_To_PQ(float3 nits)
{
    return LinearToPQBT2100(max(nits, 0.0) / 10000.0);
}


float3 PQHDRLUT_Rec709_To_XYZ(float3 rgb)
{
    return float3(
        dot(rgb, float3(0.4123907993, 0.3575843394, 0.1804807884)),
        dot(rgb, float3(0.2126390059, 0.7151686788, 0.0721923154)),
        dot(rgb, float3(0.0193308187, 0.1191947790, 0.9505321522))
    );
}


float3 PQHDRLUT_XYZ_To_Rec709(float3 xyz)
{
    return float3(
        dot(xyz, float3( 3.2409699419, -1.5373831776, -0.4986107603)),
        dot(xyz, float3(-0.9692436363,  1.8759675015,  0.0415550574)),
        dot(xyz, float3( 0.0556300797, -0.2039769589,  1.0569715142))
    );
}


float3 PQHDRLUT_Rec2020_To_XYZ(float3 rgb)
{
    return float3(
        dot(rgb, float3(0.6369580483, 0.1446169036, 0.1688809752)),
        dot(rgb, float3(0.2627002120, 0.6779980715, 0.0593017165)),
        dot(rgb, float3(0.0000000000, 0.0280726930, 1.0609850577))
    );
}


float3 PQHDRLUT_XYZ_To_Rec2020(float3 xyz)
{
    return float3(
        dot(xyz, float3( 1.7166511880, -0.3556707838, -0.2533662814)),
        dot(xyz, float3(-0.6666843518,  1.6164812366,  0.0157685458)),
        dot(xyz, float3( 0.0176398574, -0.0427706133,  0.9421031212))
    );
}

int PQHDRLUT_Resolve_Input_Mode()
{
    if (PQHDRLUTInputColorSpace == 1)
        return 1;

    if (PQHDRLUTInputColorSpace == 2)
        return 2;

#if BUFFER_COLOR_SPACE == 2

    return 2;
#elif BUFFER_COLOR_SPACE == 3

    return 1;
#else

    return 1;
#endif
}

float3 PQHDRLUT_Buffer_To_PQ2020(float3 color, int mode)
{
    if (mode == 2)
    {


        // Keep signed scRGB components through the gamut conversion.
        float3 rec709_nits = color * 80.0;
        float3 xyz_nits = PQHDRLUT_Rec709_To_XYZ(rec709_nits);
        float3 rec2020_nits = PQHDRLUT_XYZ_To_Rec2020(xyz_nits);
        return PQHDRLUT_Nits_To_PQ(max(rec2020_nits, 0.0));
    }

    return max(color, 0.0);
}

float3 PQHDRLUT_PQ2020_To_Buffer(float3 pq, int mode)
{
    if (mode == 2)
    {
        float3 rec2020_nits = PQHDRLUT_PQ_To_Nits(max(pq, 0.0));
        float3 xyz_nits = PQHDRLUT_Rec2020_To_XYZ(rec2020_nits);
        float3 rec709_nits = PQHDRLUT_XYZ_To_Rec709(xyz_nits);


        // Signed scRGB components can represent colors outside Rec.709.
        return rec709_nits / 80.0;
    }

    return pq;
}

// Map normalized PQ values to texel centers for trilinear sampling.
float3 PQHDRLUT_Sample(float3 pq)
{
    float3 coordinate = saturate(pq);


    coordinate =
        (coordinate * (PQHDRLUT_SIZE - 1.0) + 0.5) /
        PQHDRLUT_SIZE;

    return tex3D(PQHDRLUTSampler, coordinate).rgb;
}


float3 PQHDRLUT_Apply(float3 color)
{
    int inputMode = PQHDRLUT_Resolve_Input_Mode();
    float3 sourcePQ = PQHDRLUT_Buffer_To_PQ2020(color, inputMode);
    float3 calibratedPQ = PQHDRLUT_Sample(sourcePQ);
    return PQHDRLUT_PQ2020_To_Buffer(calibratedPQ, inputMode);
}
#endif


// PQ-space highlight roll-off.
static const float PQ_BLACK = 7.309559025783966e-07;


float ComputeBT2390ShapedKneeStart(float maxLum, float shapeControl)
{
    float standardKneeStart = saturate(1.5 * maxLum - 0.5);


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

#if ENABLE_APL_GRAPH
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
#endif


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

float SegmentLerp(float x, float x0, float y0, float x1, float y1)
{
    return lerp(y0, y1, Remap01(x, x0, x1));
}

// Measured APL data used by the optional graph and per-APL controls.
static const int GRAPH_APL_COUNT = 10;
static const int NIT_COUNT = 24;


static const float GRAPH_APL_POINTS[GRAPH_APL_COUNT] =
{
    3.000000, 5.000000, 7.000000, 10.000000, 14.000000, 18.000000, 22.000000, 25.000000, 35.000000, 50.000000
};

static const float NIT_POINTS[NIT_COUNT] =
{
    10.302358, 13.132379, 16.611621, 20.870708, 26.064850, 32.378420, 40.030390, 49.280814, 60.438551, 73.870492, 90.012580, 109.383004, 130.598006, 157.390856, 190.634650, 230.369755, 282.836899, 334.517130, 400.180165, 480.942985, 580.341000, 702.414628, 840.814884, 1000.932391
};


// Dense live compensation table. Values correspond to COMP_APL_POINTS.
static const int COMP_APL_COUNT = 10;

static const float COMP_APL_POINTS[COMP_APL_COUNT] =
{
    3.000000,
    5.000000,
    7.000000,
    10.000000,
    14.000000,
    18.000000,
    22.000000,
    25.000000,
    35.000000,
    50.000000
};

// Representative 1D compensation values for the 8 APL anchors above.
// These values are taken/approximated from the original denser tables so the
// reduced table preserves the overall shape of the compensation curve.
static const float COMP_APL_1D[COMP_APL_COUNT] =
{
    1.000000, // 3%
    1.352556, // 5%
    1.673813, // 7%
    2.151376, // 10%
    2.455437, // 14% (approx from 15%)
    2.636610, // 18%
    2.760512, // 22%
    2.839076, // 25%
    3.064304, // 35%
    3.345667  // 50%
};


int FindCompAPLIndex(float aplPct)
{

    int idx = 0;
    [unroll]
    for (int i = 0; i < COMP_APL_COUNT - 1; ++i)
        idx += int(step(COMP_APL_POINTS[i + 1], aplPct));
    return min(idx, COMP_APL_COUNT - 2);
}

int FindGraphAPLIndex(float aplPct)
{
    int idx = 0;
    [unroll]
    for (int i = 0; i < GRAPH_APL_COUNT - 1; ++i)
        idx += int(step(GRAPH_APL_POINTS[i + 1], aplPct));
    return min(idx, GRAPH_APL_COUNT - 2);
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
    float clampedAPL = clamp(lookupAPL, COMP_APL_POINTS[0], COMP_APL_POINTS[COMP_APL_COUNT - 1]);
    int a0 = FindCompAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, COMP_APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        COMP_APL_POINTS[a0], COMP_APL_1D[a0],
        COMP_APL_POINTS[a1], COMP_APL_1D[a1]
    );
}

#if PER_APL_BOOST_STRENGTH_ENABLE
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

    float clampedAPL = clamp(aplPct, GRAPH_APL_POINTS[0], GRAPH_APL_POINTS[GRAPH_APL_COUNT - 1]);
    int a0 = FindGraphAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, GRAPH_APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        GRAPH_APL_POINTS[a0], GetPerAPLBoostStrengthAtIndex(a0),
        GRAPH_APL_POINTS[a1], GetPerAPLBoostStrengthAtIndex(a1)
    );
}
#endif

float ComputeTemporalBlendFactor(float smoothingSeconds)
{
    if (smoothingSeconds <= 1e-6)
        return 1.0;

    float dtSeconds = max(FrameTime, 0.0) * 0.001;
    return saturate(1.0 - exp(-dtSeconds / max(smoothingSeconds, 1e-6)));
}


float ComputeSceneBoostStrength(float currentAPL)
{
#if PER_APL_BOOST_STRENGTH_ENABLE
    float aplPct = saturate(currentAPL) * 100.0;
    float boostStrength = LookupPerAPLBoostStrength(aplPct);
#else
    float boostStrength = MaxAPLBoostStrength;
#endif
    return max(boostStrength, 0.0);
}


float ComputeSceneLogGainFromMeasuredComp(float measuredComp, float currentAPL)
{
    float safeMeasuredComp = max(measuredComp, 1.0);
    return log2(safeMeasuredComp) * ComputeSceneBoostStrength(currentAPL);
}

float ComputeSceneLogGainFromAPL(float currentAPL)
{
    float aplPct = saturate(currentAPL) * 100.0;
    float measuredComp = max(LookupMeasuredComp1D(aplPct), 1.0);
    return ComputeSceneLogGainFromMeasuredComp(measuredComp, currentAPL);
}


// Upper bound for the closed-loop gain search.
float ComputeCandidateMaxLogGain()
{
    float maxComp = max(LookupMeasuredComp1D(COMP_APL_POINTS[COMP_APL_COUNT - 1]), 1.0);
    float maxStrength = MaxAPLBoostStrength;

#if PER_APL_BOOST_STRENGTH_ENABLE
    if (EnablePerAPLBoostStrength)
    {
        maxStrength = 0.0;
        [unroll]
        for (int j = 0; j < GRAPH_APL_COUNT; ++j)
            maxStrength = max(maxStrength, GetPerAPLBoostStrengthAtIndex(j));
    }
#endif

    return max(log2(maxComp) * max(maxStrength, 0.0), 0.0);
}


float ComputeRollOffAnchorBoostedNitsFromSceneLogGain(float sceneLogGain)
{
    float rollOffEndNits = max(BoostRollOff, 0.0);

    if (rollOffEndNits <= 0.0)
        return 0.0;

    float referenceInputNits = max(rollOffEndNits, 1e-4);
    return referenceInputNits * exp2(sceneLogGain);
}


// Build scene-uniform gain and roll-off parameters.
float4 ComputeBoostRolloffParamsFromSceneLogGain(float sceneLogGain)
{
    if (sceneLogGain <= 1e-6)
        return float4(1.0, 0.0, 1.0, 0.0);

    float sceneGain = exp2(sceneLogGain);
    float rollOffEndNits = max(BoostRollOff, 0.0);
    float anchorBoostedNits = ComputeRollOffAnchorBoostedNitsFromSceneLogGain(sceneLogGain);

    if (rollOffEndNits <= 0.0)
        return float4(sceneGain, 0.0, 1.0, 0.0);

    float sourcePeakNits = max(anchorBoostedNits, rollOffEndNits + 1e-4);
    float sourceWhitePQ = max(NitsToPQ(sourcePeakNits), PQ_BLACK + 1e-6);
    float targetWhitePQ = min(NitsToPQ(rollOffEndNits), sourceWhitePQ - 1e-6);

    float pqRange = max(sourceWhitePQ - PQ_BLACK, 1e-6);
    float maxLum = saturate((targetWhitePQ - PQ_BLACK) / pqRange);

    if (maxLum >= 1.0 - 1e-6)
        return float4(sceneGain, 0.0, 1.0, 0.0);

    float kneeStart = ComputeBT2390ShapedKneeStart(maxLum, BoostRollOffShape);
    float compressionSpan = max(maxLum - kneeStart, 1e-6);

    return float4(sceneGain, pqRange, kneeStart, compressionSpan);
}

float4 LoadCandidateBoostParams(int candidateIndex)
{
    int idx = clamp(candidateIndex, 1, 3);
    float u = (float(idx) - 0.5) / 3.0;
    return tex2Dlod(SamplerCandidateBoostParams, float4(u, 0.5, 0.0, 0.0));
}

// Apply roll-off only to added boost; source luminance is preserved.
float ApplyBT2390EETFToNitsWithPrecomputedParams(float inputNits, float4 boostParams)
{
    float safeInputNits = max(inputNits, 0.0);
    float pqRange = boostParams.g;

    if (pqRange <= 0.0)
        return safeInputNits;

    float inputPQ = NitsToPQ(safeInputNits);
    float kneeStart = saturate(boostParams.b);
    float e1 = saturate((inputPQ - PQ_BLACK) / pqRange);


    if (e1 < kneeStart)
        return safeInputNits;

    float shoulderSpan = max(1.0 - kneeStart, 1e-6);
    float compressionSpan = max(boostParams.a, 1e-6);
    float u = saturate((e1 - kneeStart) / shoulderSpan);
    float shoulderPower = max(shoulderSpan / compressionSpan, 1.0);
    float e2 = kneeStart + compressionSpan * (1.0 - pow(1.0 - u, shoulderPower));
    float outputPQ = saturate(e2 * pqRange + PQ_BLACK);

    return max(PQToLinearScalar(outputPQ) * 10000.0, 0.0);
}

float ComputeBoostedLumaNitsFromPrecomputedParams(float inputLumaNits, float4 boostParams)
{

    float safeInputLumaNits = max(inputLumaNits, 0.0);
    float fullyBoostedNits = safeInputLumaNits * max(boostParams.r, 0.0);

    if (boostParams.g <= 0.0)
        return fullyBoostedNits;

    return max(ApplyBT2390EETFToNitsWithPrecomputedParams(fullyBoostedNits, boostParams), safeInputLumaNits);
}

float Max3(float3 v)
{
    return max(max(v.r, v.g), v.b);
}

// Compute channel headroom for ratio-preserving boost.
float ComputeMaxHuePreservingScale(float3 rgb, float channelLimit)
{
    float maxChannel = Max3(rgb);

    if (maxChannel <= 1e-6)
        return 1.0;

    return max(channelLimit / maxChannel, 0.0);
}

float SoftLimitBoostScale(float desiredScale, float maxScale, float kneeFraction)
{


    // The limiter only removes added gain.
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

float3 ApplyBoostPreserveColorFromPrecomputedParams(float3 color, float4 boostParams)
{
    if (boostParams.r <= 1.000001 && boostParams.g <= 0.0)
        return color;

    if (APLInputMode == 1)
    {
        float3 linearColorNits = PQToLinearBT2100(saturate(color)) * 10000.0;
        float originalLumaNits = max(GetLuma2020(linearColorNits), 0.0);

        if (originalLumaNits <= 1e-6)
            return color;

        float boostedLumaNits = ComputeBoostedLumaNitsFromPrecomputedParams(originalLumaNits, boostParams);
        float colorScale = boostedLumaNits / originalLumaNits;

        if (EnableColorPreservingBoostMode)
        {


            float outputChannelLimitNits = (BoostRollOff > 0.0) ? clamp(BoostRollOff, 1.0, 10000.0) : 10000.0;
            float maxHuePreservingScale = ComputeMaxHuePreservingScale(linearColorNits, outputChannelLimitNits);
            colorScale = SoftLimitBoostScale(colorScale, maxHuePreservingScale, COLOR_PRESERVING_BOOST_KNEE);
        }

        float3 boostedColorNits = linearColorNits * colorScale;

        return LinearToPQBT2100(saturate(max(boostedColorNits, 0.0) / 10000.0));
    }

    float3 linearColor = color;


    float originalLumaNits = max(GetLuma709(linearColor) * SIGNAL_REFERENCE_NITS, 0.0);

    if (originalLumaNits <= 1e-6)
        return color;

    float boostedLumaNits = ComputeBoostedLumaNitsFromPrecomputedParams(originalLumaNits, boostParams);
    float colorScale = boostedLumaNits / originalLumaNits;

    if (EnableColorPreservingBoostMode)
    {


        float outputChannelLimit = ((BoostRollOff > 0.0) ? clamp(BoostRollOff, 1.0, 10000.0) : 10000.0) / max(SIGNAL_REFERENCE_NITS, 1.0);
        float maxHuePreservingScale = ComputeMaxHuePreservingScale(max(linearColor, 0.0.xxx), outputChannelLimit);
        colorScale = SoftLimitBoostScale(colorScale, maxHuePreservingScale, COLOR_PRESERVING_BOOST_KNEE);
    }

    return linearColor * colorScale;
}


// Scalar response used by live APL analysis and graph simulation.
float ComputePostBoostNitsForSample(float lumaNits, float maxChannelNits, float4 boostParams)
{
    if (lumaNits <= 1e-6)
        return 0.0;

    float boostedLumaNits = ComputeBoostedLumaNitsFromPrecomputedParams(lumaNits, boostParams);

    if (EnableColorPreservingBoostMode && maxChannelNits > 1e-6)
    {

        float outputChannelLimitNits = (BoostRollOff > 0.0) ? clamp(BoostRollOff, 1.0, 10000.0) : 10000.0;
        float maxHuePreservingScale = max(outputChannelLimitNits / maxChannelNits, 0.0);
        float colorScale = SoftLimitBoostScale(boostedLumaNits / lumaNits, maxHuePreservingScale, COLOR_PRESERVING_BOOST_KNEE);
        boostedLumaNits = lumaNits * colorScale;
    }

    return boostedLumaNits;
}


float ComputePostBoostMetricForSample(float lumaNits, float maxChannelNits, float4 boostParams)
{
    return saturate(
        ComputePostBoostNitsForSample(lumaNits, maxChannelNits, boostParams) /
        max(APLReferenceWhiteNits, 1.0)
    );
}


// Interpolate APL response at four log-gain nodes.
float EvaluateDisplayAPLResponseFromLogNodes(float4 logA, float logGain, float gainToNodeScale)
{
    float t = clamp(logGain * gainToNodeScale, 0.0, 3.0);
    float logEst;

    if (t <= 1.0)
        logEst = lerp(logA.x, logA.y, t);
    else if (t <= 2.0)
        logEst = lerp(logA.y, logA.z, t - 1.0);
    else
        logEst = lerp(logA.z, logA.w, t - 2.0);

    return saturate(exp2(logEst));
}


// Solve gain = compensation(APL response) with ten bisection steps.
float SolveClosedLoopDisplayAPLFromResponseNodes(float rawAPL, float3 responseNodes, float gMax)
{
    float safeRawAPL = saturate(rawAPL);

    if (safeRawAPL <= 1e-6)
        return 0.0;

    if (gMax <= 1e-6)
        return safeRawAPL;


    float4 logA = log2(max(float4(safeRawAPL, responseNodes), 1e-6));
    float gainToNodeScale = 3.0 / gMax;

    float lo = 0.0;
    float hi = gMax;

    float aplLo = safeRawAPL;           // A(0)
    float fLo = clamp(ComputeSceneLogGainFromAPL(aplLo), 0.0, gMax);


    if (fLo <= 1e-6)
        return aplLo;

    float aplHi = saturate(responseNodes.z); // A(gMax)
    float fHi = clamp(ComputeSceneLogGainFromAPL(aplHi), 0.0, gMax) - gMax;

    if (fHi >= -1e-6)
        return aplHi;


    [loop]
    for (int i = 0; i < 10; ++i)
    {
        float mid = 0.5 * (lo + hi);
        float aplMid = EvaluateDisplayAPLResponseFromLogNodes(logA, mid, gainToNodeScale);
        float fMid = clamp(ComputeSceneLogGainFromAPL(aplMid), 0.0, gMax) - mid;

        if (fMid > 0.0)
            lo = mid;
        else
            hi = mid;
    }

    float solvedGain = 0.5 * (lo + hi);
    return EvaluateDisplayAPLResponseFromLogNodes(logA, solvedGain, gainToNodeScale);
}


float SolveUniformSceneDisplayAPL(float rawAPL)
{
    float safeRawAPL = saturate(rawAPL);

    if (safeRawAPL <= 1e-6 || !EnableEOTFBoost)
        return safeRawAPL;

    float gMax = ComputeCandidateMaxLogGain();

    if (gMax <= 1e-6)
        return safeRawAPL;

    float representativeNits = safeRawAPL * max(APLReferenceWhiteNits, 1.0);
    float3 responseNodes;

    [unroll]
    for (int k = 1; k <= 3; ++k)
    {
        responseNodes[k - 1] = ComputePostBoostMetricForSample(
            representativeNits,
            representativeNits,
            LoadCandidateBoostParams(k)
        );
    }

    return SolveClosedLoopDisplayAPLFromResponseNodes(safeRawAPL, responseNodes, gMax);
}

#if ENABLE_APL_GRAPH


static const float GRAPH_COMP_TABLE_2D[GRAPH_APL_COUNT * NIT_COUNT] =
{

    1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000,
    1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000,
    1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000,


    1.275485, 1.279098, 1.298112, 1.311262, 1.320233, 1.306626, 1.336365, 1.320144,
    1.337008, 1.337614, 1.354279, 1.352556, 1.347158, 1.353409, 1.354995, 1.357722,
    1.360410, 1.379355, 1.375188, 1.377428, 1.380128, 1.378296, 1.394903, 1.403779,


    1.636865, 1.586585, 1.600228, 1.632120, 1.646603, 1.656140, 1.653732, 1.648574,
    1.659723, 1.638967, 1.676518, 1.673813, 1.667162, 1.672429, 1.678772, 1.682167,
    1.684833, 1.688457, 1.682479, 1.705485, 1.708849, 1.722217, 1.732755, 1.743012,


    2.222370, 2.139135, 2.131274, 2.103239, 2.119450, 2.139539, 2.144950, 2.119860,
    2.154030, 2.144674, 2.181553, 2.151376, 2.139477, 2.150906, 2.153600, 2.140693,
    2.162291, 2.190399, 2.181303, 2.170379, 2.194950, 2.195467, 2.208124, 2.226317,


    2.574646, 2.466301, 2.477981, 2.440763, 2.439207, 2.453153, 2.457554, 2.437744,
    2.459988, 2.467005, 2.474901, 2.455437, 2.446400, 2.453859, 2.454635, 2.467066,
    2.467625, 2.465686, 2.466095, 2.466487, 2.476404, 2.484286, 2.496364, 2.518080,


    2.748700, 2.653554, 2.657380, 2.630880, 2.595614, 2.617234, 2.624612, 2.604644,
    2.621808, 2.624117, 2.640117, 2.636610, 2.604680, 2.617061, 2.615594, 2.612188,
    2.617207, 2.621120, 2.624654, 2.626987, 2.640365, 2.633628, 2.665580, 2.675877,


    2.916959, 2.818433, 2.786699, 2.777913, 2.748502, 2.748234, 2.764812, 2.754077,
    2.767587, 2.764558, 2.776648, 2.760512, 2.734844, 2.742903, 2.740379, 2.745571,
    2.753666, 2.757212, 2.750390, 2.758649, 2.770630, 2.772743, 2.790399, 2.814688,


    3.005716, 2.911831, 2.892784, 2.875547, 2.824210, 2.833016, 2.856895, 2.834469,
    2.853785, 2.843423, 2.864118, 2.839076, 2.816207, 2.827746, 2.825887, 2.840115,
    2.842497, 2.844660, 2.835615, 2.839335, 2.859106, 2.857170, 2.876447, 2.900269,


    3.227778, 3.139621, 3.086106, 3.101464, 3.053503, 3.050585, 3.063989, 3.034956,
    3.074032, 3.056235, 3.082187, 3.064304, 3.033025, 3.038294, 3.037854, 3.051513,
    3.057893, 3.059339, 3.042766, 3.063924, 3.067941, 3.076905, 3.098045, 3.124520,

   
    3.605147, 3.469041, 3.422317, 3.396852, 3.379085, 3.350383, 3.331431, 3.333736,
    3.385554, 3.346382, 3.380603, 3.345667, 3.325029, 3.308191, 3.317324, 3.329362,
    3.338411, 3.331323, 3.321922, 3.330550, 3.342307, 3.347892, 3.376754, 3.407354
};


// Measured 2D data used only by graph projection.
static const int FULLFIELD_100_COUNT = 33;

static const float FULLFIELD_100_INPUT_NITS[FULLFIELD_100_COUNT] =
{
    0.000000, 0.011931, 0.054452, 0.138304, 0.282443, 0.521309, 0.865680, 1.384067,
    2.082348, 3.035066, 4.374848, 6.086059, 8.324707, 11.363916, 15.134164, 19.949442,
    26.352272, 34.156536, 43.978027, 56.870362, 72.413132, 92.698470, 117.036078, 147.265282,
    186.502536, 233.369755, 291.383762, 366.488542, 456.037005, 566.771366, 710.083776, 881.023134,
    1000.932000
};

static const float FULLFIELD_100_MEASURED_NITS[FULLFIELD_100_COUNT] =
{
    0.000000, 0.000000, 0.025553, 0.118012, 0.288831, 0.591004, 0.975432, 1.522651,
    2.381936, 3.378590, 5.068168, 6.945428, 9.627818, 12.967435, 16.961642, 20.195403,
    23.503979, 30.959431, 35.582524, 38.937325, 42.492201, 45.812047, 49.682839, 59.134684,
    70.803150, 84.266779, 100.396451, 118.819227, 140.396332, 166.118513, 196.873554, 230.232825,
    254.021011
};


static const int FULLFIELD_50_COUNT = 33;

static const float FULLFIELD_50_MEASURED_NITS[FULLFIELD_50_COUNT] =
{
    0.000000, 0.000000, 0.019611, 0.097831, 0.249949, 0.526106, 0.889249, 1.411673,
    2.227720, 3.168462, 4.802616, 6.558748, 9.185429, 12.424980, 16.227606, 19.369587,
    23.859118, 31.436385, 40.137642, 53.197343, 65.392805, 74.547320, 80.127169, 85.519747,
    92.611297, 100.748551, 119.449653, 140.743873, 167.553173, 195.406956, 234.022413, 272.116401,
    300.507285
};

static const int FULLFIELD_25_COUNT = 33;

static const float FULLFIELD_25_MEASURED_NITS[FULLFIELD_25_COUNT] =
{
    0.000000, 0.000000, 0.020193, 0.098958, 0.253351, 0.530072, 0.894046, 1.417652,
    2.236172, 3.175224, 4.814092, 6.578921, 9.210201, 12.453936, 16.233701, 19.360823,
    24.324769, 31.664910, 40.662945, 53.441695, 68.002699, 88.193059, 111.606274, 135.299708,
    149.261837, 161.082050, 170.971315, 185.138530, 201.136027, 234.942743, 280.942968, 325.624744,
    359.448525
};

static const int FULLFIELD_15_COUNT = 33;

static const float FULLFIELD_15_MEASURED_NITS[FULLFIELD_15_COUNT] =
{
    0.000000, 0.000000, 0.024520, 0.114708, 0.280640, 0.581359, 0.958295, 1.494907,
    2.323773, 3.286472, 4.984005, 6.824739, 9.518044, 12.823650, 16.687334, 19.874191,
    24.870417, 32.192746, 41.126911, 53.811406, 68.639696, 88.228024, 111.933290, 142.016629,
    178.322722, 218.856152, 244.621474, 264.975028, 281.601565, 303.076471, 321.154317, 374.958739,
    410.885700
};

static const int FULLFIELD_10_COUNT = 33;

static const float FULLFIELD_10_MEASURED_NITS[FULLFIELD_10_COUNT] =
{
    0.000000, 0.000000, 0.023311, 0.111391, 0.276822, 0.572010, 0.949903, 1.489990,
    2.313793, 3.300262, 4.981862, 6.854603, 9.544428, 12.853254, 16.722919, 20.305498,
    26.128305, 33.665465, 42.636117, 55.207774, 69.932789, 89.672005, 112.739759, 141.994701,
    180.269676, 227.876442, 287.603899, 341.189386, 373.286063, 401.007822, 427.822267, 459.211151,
    468.045533
};


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
    int count = GetFullFieldWindowCountByMode(mode);
    float maxMeasuredNits = 0.0;

    [loop]
    for (int i = 0; i < count; ++i)
        maxMeasuredNits = max(maxMeasuredNits, GetFullFieldMeasuredNitsByModeAndIndex(mode, i));

    return maxMeasuredNits;
}


// Simulate a grayscale window on black with the live solver.
float4 ComputeFullFieldLiveProjectionByMode(int mode, float inputNits)
{
    float safeInputNits = max(inputNits, 0.0);
    float windowFraction = saturate(GetFullFieldWindowScaleByMode(mode));
    float referenceWhite = max(APLReferenceWhiteNits, 1.0);


    float rawWindowMetric = saturate(safeInputNits / referenceWhite);
    float rawAPL = saturate(windowFraction * rawWindowMetric);
    float displayAPL = rawAPL;
    float remappedSignalNits = safeInputNits;

    if (EnableEOTFBoost && rawAPL > 1e-6)
    {
        float gMax = ComputeCandidateMaxLogGain();

        if (gMax > 1e-6)
        {
            float3 responseNodes = rawAPL.xxx;

            [unroll]
            for (int k = 1; k <= 3; ++k)
            {
                float4 candidateParams = LoadCandidateBoostParams(k);
                float brightPixelMetric = ComputePostBoostMetricForSample(
                    safeInputNits,
                    safeInputNits,
                    candidateParams
                );


                responseNodes[k - 1] = saturate(windowFraction * brightPixelMetric);
            }

            displayAPL = SolveClosedLoopDisplayAPLFromResponseNodes(rawAPL, responseNodes, gMax);
        }

        float sceneLogGain = ComputeSceneLogGainFromAPL(displayAPL);
        float4 liveBoostParams = ComputeBoostRolloffParamsFromSceneLogGain(sceneLogGain);
        remappedSignalNits = ComputePostBoostNitsForSample(
            safeInputNits,
            safeInputNits,
            liveBoostParams
        );
    }

    float predictedMeasuredOutputNits = SampleMeasuredOutputNitsFullFieldByMode(mode, remappedSignalNits);
    return float4(remappedSignalNits, predictedMeasuredOutputNits, displayAPL, 1.0);
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
    float clampedAPL = clamp(aplPct, GRAPH_APL_POINTS[0], GRAPH_APL_POINTS[GRAPH_APL_COUNT - 1]);
    int a0 = FindGraphAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, GRAPH_APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        GRAPH_APL_POINTS[a0], LookupGraphCompForAPLRow2D(a0, inputNits),
        GRAPH_APL_POINTS[a1], LookupGraphCompForAPLRow2D(a1, inputNits)
    );
}

float SampleRealMeasuredOutputNitsForAPL(float aplPct, float targetNits)
{
    float comp = max(LookupMeasuredComp2DGraph(aplPct, targetNits), 1e-6);
    return targetNits / comp;
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
float ApplyGraphInputSignalLimitNits(float inputNits)
{
    float safeInputNits = max(inputNits, 0.0);

    if (GraphInputSignalLimitNits > 0.0)
        return min(safeInputNits, GraphInputSignalLimitNits);

    return safeInputNits;
}

float ComputeGraphCurveMeasuredRawOutputNits(bool useFullFieldWindowProjection, int fullFieldWindowMode, float graphRawAPLPercent, float inputNits)
{
    float limitedInputNits = ApplyGraphInputSignalLimitNits(inputNits);

    if (useFullFieldWindowProjection)
        return SampleMeasuredOutputNitsFullFieldByMode(fullFieldWindowMode, limitedInputNits);

    return SampleRealMeasuredOutputNitsForAPL(graphRawAPLPercent, limitedInputNits);
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


    float2 graphPos = float2(0.055 * aspect, 0.48);
    float2 graphSize = float2(0.43 * aspect, 0.44);
    float2 graphMin = graphPos;
    float2 graphMax = graphPos + graphSize;

    float thickness = 0.00105;
    float curveThickness = thickness * 0.95;
    float refThickness = thickness * 0.90;
    float gridThickness = 0.00050;
    float tickThickness = 0.00075;
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


            float uX = (float(i + 18) + 0.5) / float(GRAPH_LINE_COUNT);
            float uY = (float(i + 24) + 0.5) / float(GRAPH_LINE_COUNT);
            float4 segX = tex2Dlod(SamplerGraphLines, float4(uX, 0.5, 0.0, 0.0));
            float4 segY = tex2Dlod(SamplerGraphLines, float4(uY, 0.5, 0.0, 0.0));
            float2 xTick = segX.zw;
            float2 yTick = segY.xy;


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


        float curveX = saturate((p.x - graphMin.x) / max(graphSize.x, 1e-6));
        int centerSegment = clamp(
            int(floor(curveX * float(GRAPH_CURVE_SAMPLES - 1))),
            0,
            GRAPH_CURVE_SAMPLES - 2
        );

        [unroll]
        for (int neighbor = 0; neighbor < 5; ++neighbor)
        {
            int s = clamp(centerSegment + neighbor - 2, 0, GRAPH_CURVE_SAMPLES - 2);
            float u = (float(s) + 0.5) / float(GRAPH_CURVE_SAMPLES);

            float4 remappedSeg = tex2Dlod(SamplerGraphCurves, float4(u, 0.125, 0.0, 0.0));
            if (remappedSeg.x >= 0.0)
                remappedMask = max(remappedMask, DrawGraphLine(p, remappedSeg.xy, remappedSeg.zw, curveThickness * 0.95));

            float4 correctedSeg = tex2Dlod(SamplerGraphCurves, float4(u, 0.375, 0.0, 0.0));
            if (correctedSeg.x >= 0.0)
                correctedMask = max(correctedMask, DrawGraphLine(p, correctedSeg.xy, correctedSeg.zw, curveThickness));

            float4 measuredSeg = tex2Dlod(SamplerGraphCurves, float4(u, 0.625, 0.0, 0.0));
            if (measuredSeg.x >= 0.0)
                measuredMask = max(measuredMask, DrawGraphLine(p, measuredSeg.xy, measuredSeg.zw, curveThickness));

            if (GraphShowBT2390Reference && graphMaxMeasuredNits > 0.0)
            {
                float4 referenceSeg = tex2Dlod(SamplerGraphCurves, float4(u, 0.875, 0.0, 0.0));
                if (referenceSeg.x >= 0.0)
                    idealPQRefMask = max(
                        idealPQRefMask,
                        DrawGraphDashedLine(p, referenceSeg.xy, referenceSeg.zw, refThickness * 0.95, 18.0)
                    );
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

    float3 measuredCurveColor = float3(0.62, 0.82, 1.00);
    float3 correctedCurveColor = float3(0.62, 0.62, 0.62);

    graphColor = lerp(graphColor, float3(0.40, 0.65, 1.00) * OSDBrightness * 2.0, saturate(refMask) * GraphOpacity);
    graphColor = lerp(graphColor, float3(1.00, 0.35, 0.92) * OSDBrightness * 2.0, saturate(idealPQRefMask) * saturate(GraphOpacity + 0.02));
    graphColor = lerp(graphColor, measuredCurveColor * OSDBrightness * 1.95, measuredMaskSat * saturate(GraphOpacity * 0.95));
    graphColor = lerp(graphColor, float3(0.30, 0.88, 0.42) * OSDBrightness * 1.55, saturate(remappedMask) * saturate(GraphOpacity + 0.06));
    graphColor = lerp(graphColor, correctedCurveColor * OSDBrightness * 1.85, correctedMaskSat * saturate(GraphOpacity + 0.20));

    return saturate(graphColor);
}

#endif


// Bilinear lookup in the 129-node PQ decode table.
float APL_FastPQCodeToNits(float pqCode)
{


    float u = (saturate(pqCode) * 128.0 + 0.5) * (1.0 / 129.0);
    return tex2Dlod(SamplerAPLFastPQNits, float4(u, 0.5, 0.0, 0.0)).r;
}

float3 APL_FastPQToNits(float3 pq)
{
    return float3(
        APL_FastPQCodeToNits(pq.r),
        APL_FastPQCodeToNits(pq.g),
        APL_FastPQCodeToNits(pq.b));
}

int APL_QuantizeNitsQ4(float nits)
{
    return clamp((int)floor(max(nits, 0.0) * 4.0 + 0.5), 0, 40000);
}

int APL_QuantizeMaxNits2(float nits)
{


    return clamp((int)floor(max(nits, 0.0) * 0.5 + 0.5), 0, 5000);
}

int APL_ActiveHistogramBins()
{
    return (EnableEOTFBoost && EnableColorPreservingBoostMode) ? APL_FFH_MAX_BINS : APL_FFH_LUMA_BINS;
}

int APL_HistogramLumaBin64(int lumaQ4)
{
    if (lumaQ4 <= 0) return 0;
    int exponent = firstbithigh(lumaQ4);
    int subBin = (exponent >= 2) ? ((lumaQ4 >> (exponent - 2)) & 3) : 0;
    return min(exponent * 4 + subBin, APL_FFH_LUMA_BINS - 1);
}

int APL_HistogramColorRatioBin(int lumaQ4, int maxQ4)
{
    int safeLumaQ4 = max(lumaQ4, 1);
    int ratioBin = 0;
    ratioBin += (maxQ4 >= safeLumaQ4 * 2) ? 1 : 0;
    ratioBin += (maxQ4 >= safeLumaQ4 * 4) ? 1 : 0;
    ratioBin += (maxQ4 >= safeLumaQ4 * 8) ? 1 : 0;
    return min(ratioBin, APL_FFH_COLOR_RATIO_BINS - 1);
}

void APL_HistogramLumaBinBoundsQ4(int lumaBin, out int lowerQ4, out int upperQ4)
{
    lowerQ4 = 0;
    upperQ4 = 0;

    int exponent = lumaBin >> 2;
    int subBin = lumaBin & 3;

    if (exponent < 2)
    {
        lowerQ4 = (exponent == 0) ? 0 : (1 << exponent);
        upperQ4 = (1 << (exponent + 1)) - 1;
    }
    else
    {
        int stepQ4 = 1 << (exponent - 2);
        lowerQ4 = (1 << exponent) + subBin * stepQ4;
        upperQ4 = lowerQ4 + stepQ4 - 1;
    }

    upperQ4 = min(upperQ4, 40000);
    lowerQ4 = min(lowerQ4, upperQ4);
}

int APL_EncodeWithinBinOffset10(int lumaQ4, int lumaBin)
{
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLumaBinBoundsQ4(lumaBin, lowerQ4, upperQ4);

    uint rangeQ4 = uint(upperQ4 - lowerQ4);
    if (rangeQ4 == 0u)
        return 0;

    uint positionQ4 = uint(clamp(lumaQ4, lowerQ4, upperQ4) - lowerQ4);
    uint numerator = positionQ4 * uint(APL_FFH_PACK_OFFSET_SCALE);
    uint offset10 = (numerator + (rangeQ4 >> 1)) / rangeQ4;
    return int(min(offset10, uint(APL_FFH_PACK_OFFSET_SCALE)));
}

float APL_ReconstructMeanLumaQ4(int binIndex, bool colorHistogram, float pixelCount, float offsetSum10)
{
    int lumaBin = colorHistogram ? (binIndex / APL_FFH_COLOR_RATIO_BINS) : binIndex;
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLumaBinBoundsQ4(lumaBin, lowerQ4, upperQ4);
    float rangeQ4 = float(upperQ4 - lowerQ4);

    if (pixelCount <= 0.0 || rangeQ4 <= 0.0)
        return float(lowerQ4);

    float meanOffset10 = offsetSum10 / pixelCount;
    return float(lowerQ4) + rangeQ4 * (meanOffset10 / float(APL_FFH_PACK_OFFSET_SCALE));
}

int2 APL_HistogramBlockCoord(int binIndex)
{
    return int2(binIndex & 15, binIndex >> 4);
}

int2 APL_RowHistogramCoord(int rowIndex, int binIndex)
{
    int2 binCoord = APL_HistogramBlockCoord(binIndex);
    return int2(binCoord.x, rowIndex * APL_FFH_BLOCK_H + binCoord.y);
}

int2 APL_RowExactMaxLumaCoord(int rowIndex)
{
    return int2(APL_FFH_AUX_X, rowIndex * APL_FFH_BLOCK_H);
}

int2 APL_GlobalExactMaxLumaCoord()
{
    return int2(APL_FFH_AUX_X, 0);
}

int APL_DecodeStoredRollingPhase(float storedPhase)
{
#if APL_FULLFRAME_ROLLING_PHASES > 0
    return clamp(int(floor(storedPhase + 0.5)), 0, APL_FULLFRAME_ROLLING_PHASES - 1);
#else
    return 0;
#endif
}

int APL_GetNextRollingPhase(int currentPhase)
{
#if APL_FULLFRAME_ROLLING_PHASES > 0
    int nextPhase = currentPhase + 1;
    return (nextPhase < APL_FULLFRAME_ROLLING_PHASES) ? nextPhase : 0;
#else
    return 0;
#endif
}

int APL_GetPhysicalRowFromDispatchSlot(int dispatchRowSlot, int rollingPhase)
{
#if APL_FULLFRAME_ROLLING_PHASES > 0
    return rollingPhase + dispatchRowSlot * APL_FULLFRAME_ROLLING_PHASES;
#else
    return dispatchRowSlot;
#endif
}

int APL_GetExpectedRowPixelCount(int rowIndex)
{
    int rowStartY = rowIndex * APL_FFH_TILE_SIZE;
    int rowHeight = clamp(BUFFER_HEIGHT - rowStartY, 0, APL_FFH_TILE_SIZE);
    return BUFFER_WIDTH * rowHeight;
}

int APL_GetExpectedTilePixelCount(int tileX, int rowIndex)
{
    int tileStartX = tileX * APL_FFH_TILE_SIZE;
    int tileStartY = rowIndex * APL_FFH_TILE_SIZE;
    int tileWidth = clamp(BUFFER_WIDTH - tileStartX, 0, APL_FFH_TILE_SIZE);
    int tileHeight = clamp(BUFFER_HEIGHT - tileStartY, 0, APL_FFH_TILE_SIZE);
    return tileWidth * tileHeight;
}

// Signature prevents rows built with different runtime settings from mixing.
int APL_GetRollingHistogramSignature(bool colorHistogram)
{


    int signalRef = clamp(int(SIGNAL_REFERENCE_NITS + 0.5), 1, 200);
    return clamp(APLInputMode, 0, 1) + (colorHistogram ? 2 : 0) + signalRef * 4;
}

void APL_DecodePackedFullFrameSample(
    int2 pixel,
    bool needsMaxHistogram,
    out int binIndex,
    out int packedContribution,
    out int maxNits2,
    out int lumaQ4,
    out int valid)
{
    binIndex = 0;
    packedContribution = 0;
    maxNits2 = 0;
    lumaQ4 = 0;
    valid = 0;

    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= BUFFER_WIDTH || pixel.y >= BUFFER_HEIGHT)
        return;

    float3 color = tex2Dfetch(ReShade::BackBuffer, pixel).rgb;
    float sceneNits = 0.0;
    float maxChannelNits = 0.0;

    if (APLInputMode == 1)
    {
        float3 channelNits = APL_FastPQToNits(color);
        sceneNits = max(GetLuma2020(channelNits), 0.0);
        if (needsMaxHistogram)
            maxChannelNits = max(max(channelNits.r, channelNits.g), channelNits.b);
    }
    else
    {
        sceneNits = max(GetLuma709(color) * SIGNAL_REFERENCE_NITS, 0.0);
        if (needsMaxHistogram)
        {
            float3 positiveColor = max(color, 0.0.xxx);
            maxChannelNits = max(max(positiveColor.r, positiveColor.g), positiveColor.b) * SIGNAL_REFERENCE_NITS;
        }
    }

    lumaQ4 = APL_QuantizeNitsQ4(sceneNits);
    int maxQ4 = needsMaxHistogram ? APL_QuantizeNitsQ4(maxChannelNits) : 0;
    int lumaBin = APL_HistogramLumaBin64(lumaQ4);
    binIndex = needsMaxHistogram
        ? lumaBin * APL_FFH_COLOR_RATIO_BINS + APL_HistogramColorRatioBin(lumaQ4, maxQ4)
        : lumaBin;

    int offset10 = APL_EncodeWithinBinOffset10(lumaQ4, lumaBin);
    packedContribution = APL_FFH_PACK_ONE_COUNT + offset10;
    maxNits2 = needsMaxHistogram ? APL_QuantizeMaxNits2(maxChannelNits) : 0;
    valid = 1;
}

groupshared int APL_SetupRollingPhase;
groupshared int APL_TilePackedCountLuma[APL_FFH_MAX_BINS];
groupshared int APL_TileMaxNits[APL_FFH_MAX_BINS];
groupshared int APL_TileExactMaxLumaQ4;
groupshared int APL_BuildRollingPhase;

void APL_AtomicAddMergedTileSample(int binIndex, int packedContribution, int maxNits2, int valid, bool needsMaxHistogram)
{
    if (valid == 0)
        return;

    atomicAdd(APL_TilePackedCountLuma[binIndex], packedContribution);
    if (needsMaxHistogram)
        atomicAdd(APL_TileMaxNits[binIndex], maxNits2);
}


[shader("compute")]
// Pass 1: build frame constants, copy APL history, and clear updated rows.
void CS_SetupAndClearAPLFullFrameRowHistograms(uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    int localIndex = int(threadID.x);
    int activeBins = APL_ActiveHistogramBins();
    bool needsMaxHistogram = EnableEOTFBoost && EnableColorPreservingBoostMode;
    bool trackExactMax = aplActive && ShowOSD;


    if (localIndex < 3)
    {
        float4 candidateParams = float4(1.0, 0.0, 1.0, 0.0);
        if (aplActive)
        {
            float gMax = ComputeCandidateMaxLogGain();
            float candidateLogGain = gMax * (float(localIndex + 1) / 3.0);
            candidateParams = ComputeBoostRolloffParamsFromSceneLogGain(candidateLogGain);
        }
        tex2Dstore(StorageCandidateBoostParams, int2(localIndex, 0), candidateParams);
    }


    if (aplActive && localIndex < 129)
    {
        float pqCode = float(localIndex) * (1.0 / 128.0);
        tex2Dstore(StorageAPLFastPQNits, int2(localIndex, 0), PQToLinearScalar(pqCode) * 10000.0);
    }


    if (localIndex == 0)
    {
        float4 previousAPL = aplActive
            ? tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0))
            : 0.0.xxxx;
        float storedPhase = aplActive
            ? tex2Dlod(SamplerAPLInstant, float4(0.5, 0.5, 0.0, 0.0)).b
            : 0.0;
        APL_SetupRollingPhase = APL_DecodeStoredRollingPhase(storedPhase);

        // TexAPLPrev.g is unused by the solver and carries this execution's phase.
        previousAPL.g = float(APL_SetupRollingPhase);
        tex2Dstore(StorageAPLPrev, int2(0, 0), previousAPL);
    }
    barrier();

#if APL_FULLFRAME_ROLLING_PHASES > 0
    int rowSlots = APL_FFH_ROLLING_ROW_SLOTS;
    int totalEntries = rowSlots * activeBins;
    int signature = APL_GetRollingHistogramSignature(needsMaxHistogram);
#else
    int rowSlots = APL_FFH_TILE_COUNT_Y;
    int totalEntries = rowSlots * activeBins;
#endif


    if (!trackExactMax)
    {
        [loop]
        for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += 256)
            tex2Dstore(StorageAPLRowHistCount, APL_RowExactMaxLumaCoord(rowIndex), 0);
    }

    if (aplActive)
    {
        [loop]
        for (int entry = localIndex; entry < totalEntries; entry += 256)
        {
            int rowSlot = entry / activeBins;
            int binIndex = entry - rowSlot * activeBins;
            int rowIndex = APL_GetPhysicalRowFromDispatchSlot(rowSlot, APL_SetupRollingPhase);
            if (rowIndex < APL_FFH_TILE_COUNT_Y)
            {
                int2 coord = APL_RowHistogramCoord(rowIndex, binIndex);
                tex2Dstore(StorageAPLRowHistCount, coord, 0);
                tex2Dstore(StorageAPLRowHistOffset10, coord, 0);
                if (needsMaxHistogram)
                    tex2Dstore(StorageAPLRowHistMaxNits, coord, 0);
                if (binIndex == 0)
                {
                    if (trackExactMax)
                        tex2Dstore(StorageAPLRowHistCount, APL_RowExactMaxLumaCoord(rowIndex), 0);
#if APL_FULLFRAME_ROLLING_PHASES > 0
                    tex2Dstore(StorageAPLRowMeta, int2(0, rowIndex), signature << APL_FFH_ROW_META_COUNT_BITS);
#endif
                }
            }
        }
    }
}

[shader("compute")]
// Pass 2: decode source pixels and accumulate row histograms.
void CS_BuildAPLFullFrameRowHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{

    bool aplActive = NeedsAPLProcessing();
    uint localIndex = threadID.y * APL_FFH_THREADS_X + threadID.x;
    int activeBins = APL_ActiveHistogramBins();
    bool needsMaxHistogram = EnableEOTFBoost && EnableColorPreservingBoostMode;
    bool trackExactMax = aplActive && ShowOSD;

    if (localIndex == 0)
    {
        float storedPhase = tex2Dlod(SamplerAPLPrev, float4(0.5, 0.5, 0.0, 0.0)).g;
        APL_BuildRollingPhase = APL_DecodeStoredRollingPhase(storedPhase);
    }

    if (localIndex < activeBins)
    {
        APL_TilePackedCountLuma[localIndex] = 0;
        APL_TileMaxNits[localIndex] = 0;
    }
    if (trackExactMax && localIndex == 0)
        APL_TileExactMaxLumaQ4 = 0;
    barrier();

    int physicalRow = APL_GetPhysicalRowFromDispatchSlot(int(groupID.y), APL_BuildRollingPhase);
    bool validPhysicalRow = physicalRow < APL_FFH_TILE_COUNT_Y;
    bool decodeThisGroup = aplActive && validPhysicalRow;

    if (decodeThisGroup)
    {
        int2 pixelBase = int2(int(groupID.x) * APL_FFH_TILE_SIZE, physicalRow * APL_FFH_TILE_SIZE) + int2(threadID.xy) * 2;

        int b0, p0, m0, l0, v0;
        int b1, p1, m1, l1, v1;
        int b2, p2, m2, l2, v2;
        int b3, p3, m3, l3, v3;
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 0), needsMaxHistogram, b0, p0, m0, l0, v0);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 0), needsMaxHistogram, b1, p1, m1, l1, v1);
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 1), needsMaxHistogram, b2, p2, m2, l2, v2);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 1), needsMaxHistogram, b3, p3, m3, l3, v3);

        if (trackExactMax)
            atomicMax(APL_TileExactMaxLumaQ4, max(max(l0, l1), max(l2, l3)));


        if (v1 != 0 && v0 != 0 && b1 == b0) { p0 += p1; m0 += m1; v1 = 0; }
        if (v2 != 0 && v0 != 0 && b2 == b0) { p0 += p2; m0 += m2; v2 = 0; }
        if (v2 != 0 && v1 != 0 && b2 == b1) { p1 += p2; m1 += m2; v2 = 0; }
        if (v3 != 0 && v0 != 0 && b3 == b0) { p0 += p3; m0 += m3; v3 = 0; }
        if (v3 != 0 && v1 != 0 && b3 == b1) { p1 += p3; m1 += m3; v3 = 0; }
        if (v3 != 0 && v2 != 0 && b3 == b2) { p2 += p3; m2 += m3; v3 = 0; }

        APL_AtomicAddMergedTileSample(b0, p0, m0, v0, needsMaxHistogram);
        APL_AtomicAddMergedTileSample(b1, p1, m1, v1, needsMaxHistogram);
        APL_AtomicAddMergedTileSample(b2, p2, m2, v2, needsMaxHistogram);
        APL_AtomicAddMergedTileSample(b3, p3, m3, v3, needsMaxHistogram);
    }
    barrier();

    if (trackExactMax && decodeThisGroup && localIndex == 0)
        atomicMax(StorageAPLRowHistCount, APL_RowExactMaxLumaCoord(physicalRow), APL_TileExactMaxLumaQ4);

    if (decodeThisGroup && localIndex < activeBins)
    {
        int packedValue = APL_TilePackedCountLuma[localIndex];
        int count = packedValue >> APL_FFH_PACK_COUNT_SHIFT;
        if (count > 0)
        {
            int offsetSum10 = packedValue & APL_FFH_PACK_OFFSET_MASK;
            int2 rowCoord = APL_RowHistogramCoord(physicalRow, int(localIndex));
            atomicAdd(StorageAPLRowHistCount, rowCoord, count);
            atomicAdd(StorageAPLRowHistOffset10, rowCoord, offsetSum10);
            if (needsMaxHistogram)
                atomicAdd(StorageAPLRowHistMaxNits, rowCoord, APL_TileMaxNits[localIndex]);
        }
    }

#if APL_FULLFRAME_ROLLING_PHASES > 0


    if (decodeThisGroup && localIndex == 0)
    {
        int tilePixelCount = APL_GetExpectedTilePixelCount(int(groupID.x), physicalRow);
        if (tilePixelCount > 0)
            atomicAdd(StorageAPLRowMeta, int2(0, physicalRow), tilePixelCount);
    }
#endif
}

groupshared int APL_ReduceCount[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceOffset10[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceMaxNits[APL_FFH_REDUCE_THREADS];

#define APL_REDUCE_ROW_STAGE(S) \
    if (localIndex < S) { \
        APL_ReduceCount[localIndex] += APL_ReduceCount[localIndex + S]; \
        APL_ReduceOffset10[localIndex] += APL_ReduceOffset10[localIndex + S]; \
        if (needsMaxHistogram) APL_ReduceMaxNits[localIndex] += APL_ReduceMaxNits[localIndex + S]; \
    } \
    barrier();

[shader("compute")]
// Pass 3: reduce valid persistent rows into one global histogram.
void CS_ReduceAPLFullFrameRowHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    int localIndex = int(threadID.x);
    int2 localBinCoord = int2(groupID.xy);
    int binIndex = localBinCoord.y * APL_FFH_BLOCK_W + localBinCoord.x;
    int activeBins = APL_ActiveHistogramBins();
    bool validBin = binIndex < activeBins;
    bool needsMaxHistogram = EnableEOTFBoost && EnableColorPreservingBoostMode;
    bool trackExactMax = aplActive && ShowOSD;

    int countSum = 0;
    float offsetSum10 = 0.0;
    float maxSumNits = 0.0;
    if (aplActive && validBin)
    {
        [loop]
        for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_FFH_REDUCE_THREADS)
        {
            bool includeRow = true;
#if APL_FULLFRAME_ROLLING_PHASES > 0
            int rowMeta = tex2Dfetch(SamplerAPLRowMeta, int2(0, rowIndex));
            int rowCount = rowMeta & APL_FFH_ROW_META_COUNT_MASK;
            int rowSignature = rowMeta >> APL_FFH_ROW_META_COUNT_BITS;
            int expectedSignature = APL_GetRollingHistogramSignature(needsMaxHistogram);
            includeRow = (rowCount == APL_GetExpectedRowPixelCount(rowIndex)) && (rowSignature == expectedSignature);
#endif
            if (includeRow)
            {
                int2 sourceCoord = APL_RowHistogramCoord(rowIndex, binIndex);
                countSum += tex2Dfetch(SamplerAPLRowHistCount, sourceCoord);
                offsetSum10 += float(tex2Dfetch(SamplerAPLRowHistOffset10, sourceCoord));
                if (needsMaxHistogram)
                    maxSumNits += float(tex2Dfetch(SamplerAPLRowHistMaxNits, sourceCoord));
            }
        }
    }

    APL_ReduceCount[localIndex] = countSum;
    APL_ReduceOffset10[localIndex] = offsetSum10;
    APL_ReduceMaxNits[localIndex] = maxSumNits;
    barrier();

    APL_REDUCE_ROW_STAGE(32)
    APL_REDUCE_ROW_STAGE(16)
    APL_REDUCE_ROW_STAGE(8)
    APL_REDUCE_ROW_STAGE(4)
    APL_REDUCE_ROW_STAGE(2)
    APL_REDUCE_ROW_STAGE(1)

    if (aplActive && validBin && localIndex == 0)
    {
        tex2Dstore(StorageAPLGlobalHistCount, localBinCoord, APL_ReduceCount[0]);
        tex2Dstore(StorageAPLGlobalHistOffset10, localBinCoord, APL_ReduceOffset10[0]);
        if (needsMaxHistogram)
            tex2Dstore(StorageAPLGlobalHistMaxNits, localBinCoord, APL_ReduceMaxNits[0]);


        if (binIndex == 0)
        {
            int exactMaxLumaQ4 = 0;
            if (trackExactMax)
            {
                [loop]
                for (int rowIndex = 0; rowIndex < APL_FFH_TILE_COUNT_Y; ++rowIndex)
                {
                    bool includeRow = true;
#if APL_FULLFRAME_ROLLING_PHASES > 0
                    int rowMeta = tex2Dfetch(SamplerAPLRowMeta, int2(0, rowIndex));
                    int rowCount = rowMeta & APL_FFH_ROW_META_COUNT_MASK;
                    int rowSignature = rowMeta >> APL_FFH_ROW_META_COUNT_BITS;
                    int expectedSignature = APL_GetRollingHistogramSignature(needsMaxHistogram);
                    includeRow = (rowCount == APL_GetExpectedRowPixelCount(rowIndex)) && (rowSignature == expectedSignature);
#endif
                    if (includeRow)
                        exactMaxLumaQ4 = max(exactMaxLumaQ4, tex2Dfetch(SamplerAPLRowHistCount, APL_RowExactMaxLumaCoord(rowIndex)));
                }
            }
            tex2Dstore(StorageAPLGlobalHistCount, APL_GlobalExactMaxLumaCoord(), exactMaxLumaQ4);
        }
    }
}

#undef APL_REDUCE_ROW_STAGE

groupshared float4 APL_EvalWeightedMetrics[APL_FFH_MAX_BINS];
groupshared float APL_EvalPixelCount[APL_FFH_MAX_BINS];

#define APL_REDUCE_EVAL_STAGE(S) \
    if (localIndex < S) { \
        APL_EvalWeightedMetrics[localIndex] += APL_EvalWeightedMetrics[localIndex + S]; \
        APL_EvalPixelCount[localIndex] += APL_EvalPixelCount[localIndex + S]; \
    } \
    barrier();

[shader("compute")]
// Pass 4: evaluate response, solve APL, smooth state, and write boost parameters.
void CS_EvaluateSolveAndSmoothAPLFullFrameHistogram(uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    int localIndex = int(threadID.x);
    bool colorHistogram = EnableEOTFBoost && EnableColorPreservingBoostMode;
    int activeBins = colorHistogram ? APL_FFH_MAX_BINS : APL_FFH_LUMA_BINS;

    float4 weighted = 0.0.xxxx;
    float pixelCount = 0.0;

    if (aplActive && localIndex < activeBins)
    {
        int2 binCoord = APL_HistogramBlockCoord(localIndex);
        int pixelCountI = tex2Dfetch(SamplerAPLGlobalHistCount, binCoord);
        if (pixelCountI > 0)
        {
            pixelCount = float(pixelCountI);
            float offsetSum10 = tex2Dfetch(SamplerAPLGlobalHistOffset10, binCoord);
            float meanLumaQ4 = APL_ReconstructMeanLumaQ4(localIndex, colorHistogram, pixelCount, offsetSum10);
            float sceneNits = max(meanLumaQ4 * 0.25, 0.0);
            float rawMetric = saturate(sceneNits / max(APLReferenceWhiteNits, 1.0));
            float3 candidateMetrics = rawMetric.xxx;

            if (EnableEOTFBoost)
            {
                float maxChannelNits = 0.0;
                if (colorHistogram)
                {
                    float maxSumNits = tex2Dfetch(SamplerAPLGlobalHistMaxNits, binCoord);
                    maxChannelNits = max((maxSumNits / pixelCount) * 2.0, sceneNits);
                }
                candidateMetrics.x = ComputePostBoostMetricForSample(sceneNits, maxChannelNits, LoadCandidateBoostParams(1));
                candidateMetrics.y = ComputePostBoostMetricForSample(sceneNits, maxChannelNits, LoadCandidateBoostParams(2));
                candidateMetrics.z = ComputePostBoostMetricForSample(sceneNits, maxChannelNits, LoadCandidateBoostParams(3));
            }

            weighted = float4(rawMetric, candidateMetrics) * pixelCount;
        }
    }

    APL_EvalWeightedMetrics[localIndex] = weighted;
    APL_EvalPixelCount[localIndex] = pixelCount;
    barrier();

    APL_REDUCE_EVAL_STAGE(128)
    APL_REDUCE_EVAL_STAGE(64)
    APL_REDUCE_EVAL_STAGE(32)
    APL_REDUCE_EVAL_STAGE(16)
    APL_REDUCE_EVAL_STAGE(8)
    APL_REDUCE_EVAL_STAGE(4)
    APL_REDUCE_EVAL_STAGE(2)
    APL_REDUCE_EVAL_STAGE(1)

    if (localIndex == 0)
    {


        if (!aplActive)
        {
            tex2Dstore(StorageAPLInstant, int2(0, 0), 0.0.xxxx);
            tex2Dstore(StorageAPL, int2(0, 0), 0.0.xxxx);
            tex2Dstore(StorageBoostParams, int2(0, 0), float4(1.0, 0.0, 1.0, 0.0));
            return;
        }

        float rawAPL = 0.0;
        float3 responseNodes = 0.0.xxx;
        float exactRollingMaxNits = 0.0;
        float totalPixelCount = APL_EvalPixelCount[0];

        if (totalPixelCount > 0.0)
        {
            float4 averages = APL_EvalWeightedMetrics[0] / totalPixelCount;
            rawAPL = saturate(averages.r);
            responseNodes = saturate(averages.gba);
            exactRollingMaxNits = ShowOSD
                ? float(tex2Dfetch(SamplerAPLGlobalHistCount, APL_GlobalExactMaxLumaCoord())) * 0.25
                : 0.0;
        }

        float4 prevData = tex2Dlod(SamplerAPLPrev, float4(0.5, 0.5, 0.0, 0.0));
        float prevSmoothedAPL = saturate(prevData.r);
        float hasPrev = (prevData.b > 0.0) ? 1.0 : 0.0;
        float alpha = ComputeTemporalBlendFactor(TransitionSpeed);
        int currentRollingPhase = APL_DecodeStoredRollingPhase(prevData.g);
        int nextRollingPhase = APL_GetNextRollingPhase(currentRollingPhase);


        float gMax = ComputeCandidateMaxLogGain();
        float currentDisplayAPL = SolveClosedLoopDisplayAPLFromResponseNodes(rawAPL, responseNodes, gMax);
        float smoothedAPL = lerp(
            currentDisplayAPL,
            lerp(prevSmoothedAPL, currentDisplayAPL, alpha),
            hasPrev
        );

        float sceneLogGain = ComputeSceneLogGainFromAPL(smoothedAPL);


        tex2Dstore(
            StorageAPLInstant,
            int2(0, 0),
            float4(rawAPL, exactRollingMaxNits, float(nextRollingPhase), (totalPixelCount > 0.0) ? 1.0 : 0.0)
        );
        tex2Dstore(StorageAPL, int2(0, 0), float4(smoothedAPL, smoothedAPL, 1.0, sceneLogGain));
        tex2Dstore(StorageBoostParams, int2(0, 0), ComputeBoostRolloffParamsFromSceneLogGain(sceneLogGain));
    }
}

#undef APL_REDUCE_EVAL_STAGE


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


#define OSD_CHAR_SPACE -1
#define OSD_CHAR_A 0
#define OSD_CHAR_I 8
#define OSD_CHAR_L 11
#define OSD_CHAR_M 12
#define OSD_CHAR_N 13
#define OSD_CHAR_O 14
#define OSD_CHAR_P 15
#define OSD_CHAR_R 17
#define OSD_CHAR_S 18
#define OSD_CHAR_T 19
#define OSD_CHAR_U 20
#define OSD_CHAR_W 22
#define OSD_CHAR_X 23

float GetOSDLetter(int letter, float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    int pattern = 0;


    if (letter == OSD_CHAR_A) pattern = 11245;
    else if (letter == OSD_CHAR_I) pattern = 29847;
    else if (letter == OSD_CHAR_L) pattern = 4687;
    else if (letter == OSD_CHAR_M) pattern = 24557;
    else if (letter == OSD_CHAR_N) pattern = 24573;
    else if (letter == OSD_CHAR_O) pattern = 31599;
    else if (letter == OSD_CHAR_P) pattern = 15049;
    else if (letter == OSD_CHAR_R) pattern = 15085;
    else if (letter == OSD_CHAR_S) pattern = 29671;
    else if (letter == OSD_CHAR_T) pattern = 29842;
    else if (letter == OSD_CHAR_U) pattern = 23407;
    else if (letter == OSD_CHAR_W) pattern = 23421;
    else if (letter == OSD_CHAR_X) pattern = 23213;

    int x = int(uv.x * 3.0);
    int y = int((1.0 - uv.y) * 5.0);

    return (pattern >> (x + y * 3)) & 1;
}

float DrawOSDLetterAt(float2 texcoord, float2 topLeft, float scale, float aspect, int letter)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topLeft;
    anchor.x *= aspect;

    uv -= anchor;

    return GetOSDLetter(letter, uv / scale);
}

float DrawOSDLabel8(float2 texcoord, float2 topLeft, float scale, float stepX, float aspect, int c0, int c1, int c2, int c3, int c4, int c5, int c6, int c7)
{
    float mask = 0.0;
    if (c0 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft, scale, aspect, c0);
    if (c1 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX, 0.0), scale, aspect, c1);
    if (c2 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 2.0, 0.0), scale, aspect, c2);
    if (c3 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 3.0, 0.0), scale, aspect, c3);
    if (c4 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 4.0, 0.0), scale, aspect, c4);
    if (c5 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 5.0, 0.0), scale, aspect, c5);
    if (c6 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 6.0, 0.0), scale, aspect, c6);
    if (c7 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 7.0, 0.0), scale, aspect, c7);
    return saturate(mask);
}


float3 DrawStatsOverlay(float2 texcoord, float3 sceneColor, float rawInputAPL, float outputAPL, float maxSceneNits)
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float invAspect = 1.0 / max(aspect, 1e-6);


    float scale = 0.022;
    float glyphWidth = scale * invAspect;
    float stepX = glyphWidth * 1.06;
    float lineSpacing = scale * 1.18;
    float percentGap = glyphWidth * 0.20;

    float labelScale = scale * 0.92;
    float labelGlyphWidth = labelScale * invAspect;
    float labelStepX = labelGlyphWidth * 1.18;
    float labelTotalWidth = labelStepX * 7.0 + labelGlyphWidth;
    float labelGap = glyphWidth * 0.82;


    float rightMargin = 0.016;
    float2 inputPercentRight = float2(1.0 - rightMargin, 0.034);
    float2 inputRowRight = inputPercentRight - float2(glyphWidth + percentGap, 0.0);
    float2 outputPercentRight = inputPercentRight + float2(0.0, lineSpacing);
    float2 outputRowRight = inputRowRight + float2(0.0, lineSpacing);
    float2 nitsRowRight = inputRowRight + float2(0.0, lineSpacing * 2.0);

    float valueLeft = inputRowRight.x - stepX * 5.0 - glyphWidth;
    float2 inputLabelTopLeft = float2(valueLeft - labelGap - labelTotalWidth, inputRowRight.y);
    float2 outputLabelTopLeft = inputLabelTopLeft + float2(0.0, lineSpacing);
    float2 nitsLabelTopLeft = inputLabelTopLeft + float2(0.0, lineSpacing * 2.0);

    float left = inputLabelTopLeft.x;
    float right = inputPercentRight.x;
    float top = inputRowRight.y;
    float bottom = nitsRowRight.y + scale;

    float padX = glyphWidth * 0.48;
    float padY = scale * 0.20;

    if (texcoord.x < left - padX || texcoord.x > right + padX || texcoord.y < top - padY || texcoord.y > bottom + padY)
        return sceneColor;

    int nitDisplay = clamp(int(floor(max(maxSceneNits, 0.0) + 0.5)), 0, 99999);

    float bgMask = (texcoord.x >= left - padX && texcoord.x <= right + padX && texcoord.y >= top - padY && texcoord.y <= bottom + padY) ? 1.0 : 0.0;

    float rawLabelMask = DrawOSDLabel8(texcoord, inputLabelTopLeft, labelScale, labelStepX, aspect, OSD_CHAR_R, OSD_CHAR_A, OSD_CHAR_W, OSD_CHAR_SPACE, OSD_CHAR_A, OSD_CHAR_P, OSD_CHAR_L, OSD_CHAR_SPACE);
    float outputLabelMask = DrawOSDLabel8(texcoord, outputLabelTopLeft, labelScale, labelStepX, aspect, OSD_CHAR_O, OSD_CHAR_U, OSD_CHAR_T, OSD_CHAR_SPACE, OSD_CHAR_A, OSD_CHAR_P, OSD_CHAR_L, OSD_CHAR_SPACE);
    float nitsLabelMask = DrawOSDLabel8(texcoord, nitsLabelTopLeft, labelScale, labelStepX, aspect, OSD_CHAR_R, OSD_CHAR_A, OSD_CHAR_W, OSD_CHAR_SPACE, OSD_CHAR_N, OSD_CHAR_I, OSD_CHAR_T, OSD_CHAR_S);

    float inputMask = 0.0;
    inputMask += DrawOSDAPLPercent2(texcoord, inputRowRight, scale, stepX, aspect, rawInputAPL);
    inputMask += DrawOSDPercentAt(texcoord, inputPercentRight, scale, aspect);
    inputMask = saturate(inputMask);

    float outputMask = 0.0;
    outputMask += DrawOSDAPLPercent2(texcoord, outputRowRight, scale, stepX, aspect, outputAPL);
    outputMask += DrawOSDPercentAt(texcoord, outputPercentRight, scale, aspect);
    outputMask = saturate(outputMask);

    float nitsMask = DrawOSDRow5(texcoord, nitsRowRight, scale, stepX, aspect, nitDisplay);

    float bgAlpha = 0.18 * OSDBrightness * bgMask;
    float3 shadedScene = sceneColor * (1.0 - bgAlpha);

    float3 inputColor = float3(0.30, 1.00, 0.30) * OSDBrightness;
    float3 outputColor = float3(1.00, 0.90, 0.18) * OSDBrightness;
    float3 nitsColor = float3(0.60, 0.85, 1.00) * OSDBrightness;

    float3 result = shadedScene;
    result = lerp(result, inputColor, saturate(rawLabelMask + inputMask));
    result = lerp(result, outputColor, saturate(outputLabelMask + outputMask));
    result = lerp(result, nitsColor, saturate(nitsLabelMask + nitsMask));

    return result;
}


// Pass 5: apply scene-uniform boost, optional LUT, OSD, and graph.
float4 PS_MainPass(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
    bool boostEnabled = EnableEOTFBoost;

#if PQHDRLUT_ENABLE
    bool lutEnabled = EnablePQHDRLUT;
#endif


    if (!boostEnabled)
    {
        // LUT-only or passthrough path.
#if PQHDRLUT_ENABLE
        if (lutEnabled)
            color = PQHDRLUT_Apply(color);
#endif
#if ENABLE_APL_GRAPH
        if (ShowAPLGraph)
            color = DrawAPLGraphOverlay(texcoord, color);
#endif
        return float4(color, 1.0);
    }

    float4 aplData = tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0));
    float sceneLogGain = aplData.a;

#if PQHDRLUT_ENABLE
    if ((sceneLogGain <= 0.0) && (lutEnabled == false) && (ShowOSD == false))
    {
#if ENABLE_APL_GRAPH
        if (ShowAPLGraph)
            color = DrawAPLGraphOverlay(texcoord, color);
#endif
        return float4(color, 1.0);
    }
#else
    if ((sceneLogGain <= 0.0) && (ShowOSD == false))
    {
#if ENABLE_APL_GRAPH
        if (ShowAPLGraph)
            color = DrawAPLGraphOverlay(texcoord, color);
#endif
        return float4(color, 1.0);
    }
#endif

    float3 finalColor = color;


    if (sceneLogGain > 1e-6)
    {
        float4 boostParams = tex2Dlod(SamplerBoostParams, float4(0.5, 0.5, 0.0, 0.0));
        finalColor = ApplyBoostPreserveColorFromPrecomputedParams(color, boostParams);
    }

#if PQHDRLUT_ENABLE

    // The calibration LUT operates on the final boosted signal.
    if (lutEnabled)
        finalColor = PQHDRLUT_Apply(finalColor);
#endif

    if (ShowOSD)
    {
        float4 instantData = tex2Dlod(SamplerAPLInstant, float4(0.5, 0.5, 0.0, 0.0));
        float rawInputAPL = saturate(instantData.r);
        float currentMaxSceneNits = max(instantData.g, 0.0);
        finalColor = DrawStatsOverlay(
            texcoord,
            finalColor,
            rawInputAPL,
            saturate(aplData.g),
            currentMaxSceneNits
        );
    }

#if ENABLE_APL_GRAPH


    if (ShowAPLGraph)
        finalColor = DrawAPLGraphOverlay(texcoord, finalColor);
#endif

    return float4(finalColor, 1.0);
}

#if ENABLE_APL_GRAPH


// Solve one fixed operating point for the standard APL graph.
float ComputeAPLGraphLiveOperatingPoint(float rawAPLPercent)
{
    return SolveUniformSceneDisplayAPL(saturate(rawAPLPercent * 0.01));
}

float4 PS_CalcGraphParams(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ShowAPLGraph)
        return 0.0.xxxx;

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float graphAxisMaxPQ = GraphUsePQSpace ? max(NitsToPQ(graphAxisMaxNits), 1e-6) : 0.0;

    if (GraphUseFullFieldWindowProjection)
    {
        return float4(0.0, 0.0, graphAxisMaxPQ, 0.0);
    }

    float graphRawAPLPercent = clamp(GraphAPLIndex, 0.0, 100.0);
    float graphClosedLoopAPL = ComputeAPLGraphLiveOperatingPoint(graphRawAPLPercent);
    float graphClosedLoopAPLPercent = graphClosedLoopAPL * 100.0;
    float maxMeasuredNits = GetAPLMaxMeasuredNits(graphClosedLoopAPLPercent);


    return float4(graphClosedLoopAPLPercent, maxMeasuredNits, graphAxisMaxPQ, 0.0);
}


float4 ComputeAPLGraphLiveProjection(float displayAPL, float maxMeasuredNits, float inputNits)
{
    float safeInputNits = max(inputNits, 0.0);
    float remappedSignalNits = safeInputNits;

    if (EnableEOTFBoost && displayAPL > 1e-6)
    {
        float sceneLogGain = ComputeSceneLogGainFromAPL(displayAPL);
        float4 liveBoostParams = ComputeBoostRolloffParamsFromSceneLogGain(sceneLogGain);
        remappedSignalNits = ComputePostBoostNitsForSample(
            safeInputNits,
            safeInputNits,
            liveBoostParams
        );
    }

    float displayAPLPercent = displayAPL * 100.0;
    float predictedMeasuredOutputNits = SampleCorrectedOutputNitsForAPL(
        displayAPLPercent,
        remappedSignalNits,
        maxMeasuredNits
    );

    return float4(remappedSignalNits, predictedMeasuredOutputNits, displayAPL, 1.0);
}


// Graph pass: compute live-equivalent projection at each x sample.
float4 PS_CalcGraphProjection(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ShowAPLGraph)
        return 0.0.xxxx;

    int sampleIndex = min(int(vpos.x), GRAPH_CURVE_SAMPLES - 1);
    float t = float(sampleIndex) / float(GRAPH_CURVE_SAMPLES - 1);

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float4 graphParams = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float graphAxisMaxPQ = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;
    float inputNits = GraphSampleNitsFromFraction(t, graphAxisMaxNits, graphAxisMaxPQ);
    float limitedInputNits = ApplyGraphInputSignalLimitNits(inputNits);

    if (GraphUseFullFieldWindowProjection)
        return ComputeFullFieldLiveProjectionByMode(GraphProjectionWindowSize, limitedInputNits);

    float graphClosedLoopAPL = saturate(graphParams.r * 0.01);
    float graphMaxMeasuredNits = max(graphParams.g, 0.0);
    return ComputeAPLGraphLiveProjection(graphClosedLoopAPL, graphMaxMeasuredNits, limitedInputNits);
}


// Graph pass: build grid, tick, and identity-line segments.
float4 PS_CalcGraphLines(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ShowAPLGraph)
        return float4(-1.0, -1.0, -1.0, -1.0);

    int idx = int(vpos.x);

    float aspect       = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 graphPos    = float2(0.055 * aspect, 0.48);
    float2 graphSize   = float2(0.43  * aspect, 0.44);
    float  tickLen     = graphSize.y * 0.018;

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float4 graphParams     = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float  graphAxisMaxPQ  = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;

    float2 a = 0.0, b = 0.0;

    if (idx < 9) // Vertical grid lines.
    {
        int i = idx + 1;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 10.0, graphAxisMaxNits, graphAxisMaxPQ);
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, 0.0);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, graphAxisMaxNits);
    }
    else if (idx < 18) // Horizontal grid lines.
    {
        int i = idx - 9 + 1;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 10.0, graphAxisMaxNits, graphAxisMaxPQ);
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0,           tickValue);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, graphAxisMaxNits, tickValue);
    }
    else if (idx < 24) // X-axis ticks.
    {
        int i = idx - 18;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
        float2 xTick = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, 0.0);
        a = xTick + float2(0.0, -tickLen);
        b = xTick;
    }
    else if (idx < 30) // Y-axis ticks.
    {
        int i = idx - 24;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
        float2 yTick = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0, tickValue);
        a = yTick;
        b = yTick + float2(tickLen, 0.0);
    }
    else if (idx == 30) // Identity line.
    {
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0,             0.0);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, graphAxisMaxNits, graphAxisMaxNits);
    }
    else
    {
        return float4(-1.0, -1.0, -1.0, -1.0);
    }

    return float4(a, b);
}


// Graph pass: build screen-space curve segments.
float4 PS_CalcGraphCurves(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    static const float4 SENTINEL = float4(-1.0, -1.0, -1.0, -1.0);

    if (!ShowAPLGraph)
        return SENTINEL;

    int s   = int(vpos.x);
    int row = int(vpos.y);


    if (s >= GRAPH_CURVE_SAMPLES - 1)
        return SENTINEL;


    float aspect       = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 graphPos    = float2(0.055 * aspect, 0.48);
    float2 graphSize   = float2(0.43  * aspect, 0.44);
    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);

    float4 graphParams               = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float  graphAxisMaxPQ            = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;
    float  graphRawAPLPercent        = clamp(GraphAPLIndex, 0.0, 100.0);

    bool useFF = GraphUseFullFieldWindowProjection;
    int fullFieldWindowMode = GraphProjectionWindowSize;


    float t0 = float(s)     / float(GRAPH_CURVE_SAMPLES - 1);
    float t1 = float(s + 1) / float(GRAPH_CURVE_SAMPLES - 1);
    float x0 = GraphSampleNitsFromFraction(t0, graphAxisMaxNits, graphAxisMaxPQ);
    float x1 = GraphSampleNitsFromFraction(t1, graphAxisMaxNits, graphAxisMaxPQ);

    float graphMaxMeasuredNits = useFF
        ? GetFullFieldMeasuredMaxOutputNitsByMode(fullFieldWindowMode)
        : graphParams.g;

    float4 result = SENTINEL;


    static const float invGraphSamples = 1.0 / float(GRAPH_CURVE_SAMPLES);
    float4 graphProjection0 = 0.0.xxxx;
    float4 graphProjection1 = 0.0.xxxx;

    if (row <= GCURVE_CORRECTED)
    {
        graphProjection0 = tex2Dlod(
            SamplerGraphProjection,
            float4((float(s) + 0.5) * invGraphSamples, 0.5, 0.0, 0.0)
        );
        graphProjection1 = tex2Dlod(
            SamplerGraphProjection,
            float4((float(s + 1) + 0.5) * invGraphSamples, 0.5, 0.0, 0.0)
        );
    }

    if (row == GCURVE_REMAPPED)
    {

        float y0 = graphProjection0.r;
        float y1 = graphProjection1.r;

        if (graphProjection0.a > 0.0 && graphProjection1.a > 0.0)
        {
            float2 a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
            float2 b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
            result = float4(a, b);
        }
    }
    else if (row == GCURVE_CORRECTED)
    {

        float y0;
        float y1;

        y0 = graphProjection0.g;
        y1 = graphProjection1.g;

        if (graphProjection0.a > 0.0 && graphProjection1.a > 0.0)
        {
            float2 a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
            float2 b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
            result = float4(a, b);
        }
    }
    else if (row == GCURVE_MEASURED)
    {

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
    else
    {


        float idealReferencePeakNits = max(graphMaxMeasuredNits, 0.0);
        if (GraphShowBT2390Reference && idealReferencePeakNits > 0.0)
        {
            float lx0 = ApplyGraphInputSignalLimitNits(x0);
            float lx1 = ApplyGraphInputSignalLimitNits(x1);
            float y0  = ComputeBT2390ReferenceOutputNits(lx0, graphAxisMaxNits, idealReferencePeakNits);
            float y1  = ComputeBT2390ReferenceOutputNits(lx1, graphAxisMaxNits, idealReferencePeakNits);
            float2 a  = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
            float2 b  = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
            result = float4(a, b);
        }
    }
    return result;
}

#endif

// Technique order preserves the required histogram synchronization boundaries.
technique EOTF_Boost_1D_APL_LUT
{


    pass APL_FrameSetup_And_RowHistogramClear
    {
        ComputeShader = CS_SetupAndClearAPLFullFrameRowHistograms<256, 1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }


    pass APL_FullFrame_RowHistogramBuild
    {
        ComputeShader = CS_BuildAPLFullFrameRowHistogram<16, 16, 1>;
        DispatchSizeX = APL_FFH_TILE_COUNT_X;
        DispatchSizeY = APL_FFH_ROLLING_ROW_SLOTS;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }


    pass APL_FullFrame_RowHistogramReduce
    {
        ComputeShader = CS_ReduceAPLFullFrameRowHistogram<64, 1, 1>;
        DispatchSizeX = APL_FFH_BLOCK_W;
        DispatchSizeY = APL_FFH_BLOCK_H;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }


    pass APL_Response_Solve_Smooth_And_Boost_Params
    {
        ComputeShader = CS_EvaluateSolveAndSmoothAPLFullFrameHistogram<256, 1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }

#if ENABLE_APL_GRAPH


    pass Graph_Params
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcGraphParams;
        RenderTarget = TexGraphParams;
    }

    pass Graph_Projection
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcGraphProjection;
        RenderTarget = TexGraphProjection;
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
#endif

    pass Main_Boost
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MainPass;
    }
}
    
