/***************************************************************************************
* Copyright (C) Anton Kovalev (vertver), 2026. All rights reserved.
* HLSL single-pass NTSC filter
* MIT License
***************************************************************************************
* shout out to LMP88959, which implemented an awesome NTSC emulation (fixed-point).
* https://github.com/LMP88959/NTSC-CRT
***************************************************************************************/

//Original: https://gist.github.com/vertver/670a85babb52f20ba6b5e08e5f02f08e
//Small modifications + porting by LVutner

#include "ReShade.fxh"

#if (__RENDERER__ >= 0xb000)
#define NTSC_USE_COMPUTE 1
#else
#define NTSC_USE_COMPUTE 0
uniform int compute_error_report <
	ui_type = "radio";
	ui_label = " ";
	ui_category = "WARNING: using two-pass path instead of compute shaders";
	ui_category_closed = false;
	ui_text = "Compute Shaders are not supported, use DXVK to enable faster path.\n\n";
> = 0;
#endif

//Sliders
uniform float PARAM_LUMA < ui_type = "drag"; ui_label = "Luma"; ui_min = 0.0; ui_max = 1.0; > = 0.60;
uniform float PARAM_CHROMA < ui_type = "drag"; ui_label = "Chroma"; ui_min = 0.0; ui_max = 1.0; > = 0.10;
uniform float PARAM_SATURATION < ui_type = "drag"; ui_label = "Saturation"; ui_min = 0.0; ui_max = 2.0; > = 1.10;
uniform float PARAM_NOISE < ui_type = "drag"; ui_label = "Noise"; ui_min = 0.0; ui_max = 1.0; > = 0.035;

//Resources
texture t_ntsc_backbuffer : COLOR;

sampler s_ntsc_backbuffer
{
	Texture = t_ntsc_backbuffer;
	MipFilter = LINEAR;
	MinFilter = LINEAR;
	MagFilter = LINEAR;
	AddressU = CLAMP;
	AddressV = CLAMP;
	AddressW = CLAMP;
};

texture2D t_ntsc
{
	Width = BUFFER_WIDTH;
	Height = BUFFER_HEIGHT;
#if NTSC_USE_COMPUTE
	Format = RGBA8;
#else
	Format = RGBA16F;
#endif
};

sampler2D s_ntsc
{
	Texture = t_ntsc;
	MipFilter = POINT;
	MinFilter = POINT;
	MagFilter = POINT;
	AddressU = CLAMP;
	AddressV = CLAMP;
	AddressW = CLAMP;
};

#if NTSC_USE_COMPUTE
storage2D u_ntsc
{
	Texture = t_ntsc;
};
#endif

uniform int POST_FIELD < source = "framecount"; >;

#define GROUP_SIZE_X 64
#define GROUP_SIZE_Y 1
#define GROUP_SIZE_Z 1

#define LINE_WIDTH GROUP_SIZE_X

#ifndef NTSC_ENCODE_TAPS
#define NTSC_ENCODE_TAPS 24		      // improves encoded signal quality (more blur)
#endif

#ifndef NTSC_DEMODULATION_CYCLES
#define NTSC_DEMODULATION_CYCLES 24   // improves demodulation quality (less dot crawl)
#endif

#if (NTSC_DEMODULATION_CYCLES > 32)
#define NTSC_DECODE_TAPS 32
#elif (NTSC_DEMODULATION_CYCLES < 1)
#define NTSC_DECODE_TAPS 1
#else
#define NTSC_DECODE_TAPS NTSC_DEMODULATION_CYCLES
#endif

#define NTSC_SIGNAL_SAMPLES (LINE_WIDTH + NTSC_DECODE_TAPS - 1)
#define NTSC_SOURCE_SAMPLES (NTSC_SIGNAL_SAMPLES + NTSC_ENCODE_TAPS - 1)

#define NTSC_FREQ_Y 0.2933f  // 4.2 MHz
#define NTSC_FREQ_I 0.1048f  // 1.5 MHz
#define NTSC_FREQ_Q 0.0384f  // 0.55 MHz

// NOTE(vertver): FIR coefficents generated from IIR NTSC-CRT's response
static const float fir_y[32] = {
    0.116792f, 0.242562f, 0.174966f, 0.282876f, 0.082318f, 0.049388f, 0.025644f, 0.013314f,
    0.006457f, 0.003093f, 0.001428f, 0.000650f, 0.000290f, 0.000127f, 0.000055f, 0.000024f,
    0.000010f, 0.000004f, 0.000002f, 0.000001f, 0.000000f, 0.000000f, 0.000000f, 0.000000f,
    0.000000f, 0.000000f, 0.000000f, 0.000000f, 0.000000f, 0.000000f, 0.000000f, 0.000000f
};
static const float fir_i[32] = {
    0.030134f, 0.060512f, 0.106078f, 0.146764f, 0.142932f, 0.140058f, 0.107505f, 0.082863f,
    0.060574f, 0.042483f, 0.028819f, 0.019024f, 0.012275f, 0.007769f, 0.004836f, 0.002968f,
    0.001798f, 0.001078f, 0.000640f, 0.000376f, 0.000220f, 0.000127f, 0.000073f, 0.000042f,
    0.000024f, 0.000013f, 0.000008f, 0.000004f, 0.000002f, 0.000001f, 0.000001f, 0.000000f
};
static const float fir_q[32] = {
    0.017258f, 0.039278f, 0.073129f, 0.102855f, 0.119173f, 0.121205f, 0.112486f, 0.097605f,
    0.080458f, 0.063703f, 0.048824f, 0.036434f, 0.026587f, 0.019037f, 0.013411f, 0.009315f,
    0.006390f, 0.004336f, 0.002914f, 0.001941f, 0.001283f, 0.000842f, 0.000549f, 0.000356f,
    0.000229f, 0.000147f, 0.000094f, 0.000060f, 0.000038f, 0.000024f, 0.000015f, 0.000009f
};

#if NTSC_USE_COMPUTE
groupshared float ntsc_luma[NTSC_SOURCE_SAMPLES];
groupshared float ntsc_chroma[NTSC_SOURCE_SAMPLES * 2]; //LV: edit, since reshade doesnt support multidimensional arrays (can be tough on perf but...)
groupshared float ntsc_composite[NTSC_SIGNAL_SAMPLES];
#endif

float3 rgb_to_yiq(float3 color)
{
	float y = dot(color, float3(0.299f, 0.587f, 0.114f));
	float i = dot(color, float3(0.5959f, -0.2746f, -0.3213f));
	float q = dot(color, float3(0.2115f, -0.5227f, 0.3112f));
    return float3(y, i, q);
}

float3 yiq_to_rgb(float3 yiq)
{
	float r = dot(yiq, float3(1.0f, 0.956f, 0.619f));
	float g = dot(yiq, float3(1.0f, -0.272f, -0.647f));
	float b = dot(yiq, float3(1.0f, -1.106f, 1.703f));

	return float3(r, g, b);
}

float ntsc_fir_decay(float freq)
{
    return saturate(1.0f - exp(-6.2831853f * freq)); // low pass cutoff filter for composite smear
}

float2 ntsc_carrier(float2 pixel)
{
    float field = pixel.x + 2.0f * pixel.y + (POST_FIELD - 4.0f * floor(POST_FIELD * 0.25f));
    field -= 4.0f * floor(field * 0.25f);
    float sign = field >= 2.0f ? -1.0f : 1.0f;
    return (field == 1.0f || field == 3.0f) ? float2(0.0f, sign) : float2(sign, 0.0f);
}

// NOTE(vertver): since SM3 doesn't support bitfield operations, I use float hash instead
// https://www.shadertoy.com/view/4djSRW
float ntsc_noise(float2 pixel)
{
	float3 p3 = float3(pixel, POST_FIELD);
	p3 = frac(p3 * 0.1031f);
    p3 += dot(p3, p3.zyx + 33.33f);
    return frac((p3.x + p3.y) * p3.z) - 0.5f;
}

float3 ntsc_sample_yiq(int2 pixel)
{
    float half_step = (BUFFER_WIDTH < BUFFER_PIXEL_SIZE.x * 0.9f) ? BUFFER_PIXEL_SIZE.x * 0.25f : 0.0f;
    float2 uv = (float2(pixel) + 0.5f) * BUFFER_PIXEL_SIZE;

    float3 a0 = tex2Dlod(s_ntsc_backbuffer, float4(uv.x - half_step, uv.y, 0, 0)).rgb;
    if (half_step <= 0.0f) {
        return rgb_to_yiq(max(a0, 0.0f));
	} else {
		float3 a1 = tex2Dlod(s_ntsc_backbuffer, float4(uv.x + half_step, uv.y, 0, 0)).rgb;
		return rgb_to_yiq(max(a0 + a1, 0.0f) * 0.5f);
	}
}

float3 ntsc_fetch_yiq(int2 pixel, int source_offset)
{
#if NTSC_USE_COMPUTE
    int sample_idx = pixel.x - source_offset;
    return float3(ntsc_luma[sample_idx], ntsc_chroma[sample_idx], ntsc_chroma[sample_idx + NTSC_SOURCE_SAMPLES]);
#else
    return ntsc_sample_yiq(pixel);
#endif
}

float ntsc_fetch_composite(int2 pixel, int signal_offset)
{
#if NTSC_USE_COMPUTE
    return ntsc_composite[pixel.x - signal_offset];
#else
    float2 uv = (float2(pixel) + 0.5f) * BUFFER_PIXEL_SIZE;
    return tex2Dlod(s_ntsc, float4(uv, 0, 0)).r;
#endif
}

float ntsc_encode(int2 pixel, int source_offset)
{
    float2 carrier = ntsc_carrier(pixel);
	float lume_scale = max(PARAM_LUMA, 0.01f);
	float chroma_scale = max(PARAM_CHROMA, 0.01f);
    float chroma_freq = ((carrier.y != 0.0f) ? NTSC_FREQ_Q : NTSC_FREQ_I);

    float2 fir_decay = float2(ntsc_fir_decay(NTSC_FREQ_Y * lume_scale), ntsc_fir_decay(chroma_freq * chroma_scale));
    float2 sum = 0.0f;
    float2 weight = 1.0f;

    [unroll]
    for (int tap_idx = 0; tap_idx < NTSC_ENCODE_TAPS; tap_idx++) {
        float3 yiq = ntsc_fetch_yiq(pixel - int2(tap_idx, 0), source_offset);
    
        float luma = yiq.x;
        float chroma = carrier.y != 0.0f ? yiq.z : yiq.y;
    
        sum += float2(luma, chroma) * weight; // signal convolution and filter
        weight *= 1.0f - fir_decay;
    }
    
    // encode luma and chroma with qam
    float2 signal = fir_decay * sum / max(1.0f - weight, 1e-5f);
    float composite = signal.x + PARAM_SATURATION * (signal.y * (carrier.x + carrier.y));
    float noise = PARAM_NOISE * ntsc_noise(pixel);
    
    return composite + noise;
}

float3 ntsc_decode(int2 pixel, int signal_offset)
{
	float luma = 0.0f;
	float2 chroma = float2(0, 0);
    float2 carrier = ntsc_carrier(pixel);

    [unroll]
	for (int tap_idx = 0; tap_idx < NTSC_DECODE_TAPS; tap_idx++) {
        float composite = ntsc_fetch_composite(pixel - int2(tap_idx, 0), signal_offset);

		// NOTE(vertver): apply FIR coefficents directly for each channel instead of using FIR decay for luma/chroma
        luma += composite * fir_y[tap_idx];
        chroma.x += (composite * carrier.x * 2.0f) * fir_i[tap_idx];
        chroma.y += (composite * carrier.y * 2.0f) * fir_q[tap_idx];
        
		// NOTE(vertver): swap carrier sign
		carrier = float2(carrier.y, -carrier.x);
    }

    return float3(luma, chroma.x, chroma.y);
}

#if NTSC_USE_COMPUTE
// flattened two-pass solution into one compute shader with barriers
// that works faster than texture read/writes because most of the data stays inside shared memory
void faithful_ntsc_main(uint3 group_id : SV_GroupID, uint3 group_thread_id : SV_GroupThreadID, uint3 dispatch_id : SV_DispatchThreadID)
{
	// variables
    int signal_offset = (int)(group_id.x * LINE_WIDTH) - (NTSC_DECODE_TAPS - 1);
    int source_offset = signal_offset - (NTSC_ENCODE_TAPS - 1);
    uint row_idx = min(dispatch_id.y, (uint)BUFFER_HEIGHT - 1u);

	// read from RGB texture to YIQ shared memory
    for (uint sample_idx = group_thread_id.x; sample_idx < NTSC_SOURCE_SAMPLES; sample_idx += LINE_WIDTH) {
        float3 yiq = ntsc_sample_yiq(int2(source_offset + (int)sample_idx, row_idx));
        ntsc_luma[sample_idx] = yiq.x;
        ntsc_chroma[sample_idx] = yiq.y;
        ntsc_chroma[sample_idx + NTSC_SOURCE_SAMPLES] = yiq.z;
    }
    barrier();

	// encode YIQ->composite using quadrature amplitude modulation
    for (uint signal_idx = group_thread_id.x; signal_idx < NTSC_SIGNAL_SAMPLES; signal_idx += LINE_WIDTH) {
        int2 pixel = int2(clamp(signal_offset + (int)signal_idx, 0, (int)BUFFER_WIDTH - 1), row_idx);
        ntsc_composite[signal_idx] = ntsc_encode(pixel, source_offset);
    }
    barrier();
	
	// demodulate raw composite QAM signal with FIR filters on specific carriers
	if (any(dispatch_id.xy >= (uint2)BUFFER_SCREEN_SIZE)) {
        return;
    }
    
	float4 result = float4(ntsc_decode(int2(dispatch_id.xy), signal_offset), 1.0f);

    result.xyz = yiq_to_rgb(result.xyz); //LV: Back to RGB

    tex2Dstore(u_ntsc, dispatch_id.xy, result);
}

float4 faithful_ntsc_blit(float4 hpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{  
	return tex2Dfetch(s_ntsc, hpos.xy);
}

#else
float4 faithful_ntsc_encode(float4 hpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    int2 pixel = int2(floor(texcoord * BUFFER_SCREEN_SIZE));
    return float4(ntsc_encode(pixel, 0), 0.0f, 0.0f, 1.0f);
}

float4 faithful_ntsc_decode(float4 hpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    int2 pixel = int2(floor(texcoord * BUFFER_SCREEN_SIZE));
    return float4(yiq_to_rgb(ntsc_decode(pixel, 0)), 1.0f);
}
#endif

technique faithful_ntsc <
    ui_label = "Faithful NTSC Filter";
> { 
#if NTSC_USE_COMPUTE
	pass faithful_ntsc_main { 
        ComputeShader = faithful_ntsc_main<GROUP_SIZE_X, GROUP_SIZE_Y, GROUP_SIZE_Z>;
        DispatchSizeX = (BUFFER_WIDTH + GROUP_SIZE_X - 1) / GROUP_SIZE_X; // NOTE(vertver): fixed bug with last line
        DispatchSizeY = BUFFER_HEIGHT / GROUP_SIZE_Y; 
		DispatchSizeZ = GROUP_SIZE_Z;
    }

    pass faithful_ntsc_blit {
		VertexShader = PostProcessVS;
		PixelShader  = faithful_ntsc_blit;
	}      
#else
    pass faithful_ntsc_encode {
        VertexShader = PostProcessVS;
        PixelShader = faithful_ntsc_encode;
        RenderTarget = t_ntsc;
    }

    pass faithful_ntsc_decode {
        VertexShader = PostProcessVS;
        PixelShader = faithful_ntsc_decode;
    }
#endif
}
