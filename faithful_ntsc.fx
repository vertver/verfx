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

//Sliders
uniform float PARAM_LUMA < ui_type = "drag"; ui_label = "Luma"; ui_min = 0.0; ui_max = 1.0; > = 0.80;
uniform float PARAM_CHROMA < ui_type = "drag"; ui_label = "Chroma"; ui_min = 0.0; ui_max = 1.0; > = 0.20;
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
	Format = RGBA8;
};

sampler2D s_ntsc
{
	Texture = t_ntsc;
	MipFilter = LINEAR; 
	MinFilter = LINEAR; 
	MagFilter = LINEAR;
	AddressU = CLAMP;
	AddressV = CLAMP;
	AddressW = CLAMP;
};

storage2D u_ntsc
{
	Texture = t_ntsc;
};

uniform uint POST_FIELD < source = "framecount"; >;

#define GROUP_SIZE_X 64
#define GROUP_SIZE_Y 1
#define GROUP_SIZE_Z 1

#define LINE_WIDTH GROUP_SIZE_X

#ifndef NTSC_ENCODE_TAPS
#define NTSC_ENCODE_TAPS 16		      // improves encoded signal quality (more blur)
#endif

#ifndef NTSC_DEMODULATION_CYCLES
#define NTSC_DEMODULATION_CYCLES 3    // improves demodulation quality (less dot crawl)
#endif

#define NTSC_SIGNAL_SAMPLES (LINE_WIDTH + NTSC_DEMODULATION_CYCLES * 4 - 1)
#define NTSC_SOURCE_SAMPLES (NTSC_SIGNAL_SAMPLES + NTSC_ENCODE_TAPS - 1)

#define NTSC_FREQ_Y 0.2933f  // 4.2 MHz
#define NTSC_FREQ_I 0.1048f  // 1.5 MHz
#define NTSC_FREQ_Q 0.0384f  // 0.55 MHz

groupshared float ntsc_luma[NTSC_SOURCE_SAMPLES];
groupshared float2 ntsc_chroma[NTSC_SOURCE_SAMPLES]; //LV: edit, since reshade doesnt support multidimensional arrays (can be tough on perf but...)
groupshared float ntsc_composite[NTSC_SIGNAL_SAMPLES];

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

uint3 noise_hash(uint3 hash)
{
    hash = hash * 1664525u + 1013904223u;
    hash.x += hash.y * hash.z; 
	hash.y += hash.z * hash.x; 
	hash.z += hash.x * hash.y;
    hash ^= hash >> 16u;
    hash.x += hash.y * hash.z; 
	hash.y += hash.z * hash.x; 
	hash.z += hash.x * hash.y;
    return hash;
}

float uint_to_unorm(uint unc)
{
	return asfloat((unc >> 9u) | 0x3F800000u) - 1.0;
}

float ntsc_fir_decay(float freq)
{
    return saturate(1.0f - exp(-6.2831853f * freq)); // low pass cutoff filter for composite smear
}

float2 ntsc_carrier(uint2 pixel)
{
    uint phase = uint(pixel.x + 2u * pixel.y + POST_FIELD) & 3u;
    float sign = (phase & 2u) != 0u ? -1.0f : 1.0f;
    return (phase & 1u) != 0u ? float2(0.0f, sign) : float2(sign, 0.0f);
}

float ntsc_noise(uint2 pixel, uint field)
{
    uint3 h = noise_hash(uint3(pixel, field));
    float3 u = float3(uint_to_unorm(h.x), uint_to_unorm(h.y), uint_to_unorm(h.z));
    return (u.x + u.y + u.z - 1.5f) * 0.6666667f;
}

void ntsc_load_data(uint3 group_thread_id, int source_offset, float frame_v)
{
	float half_step = (BUFFER_WIDTH < BUFFER_PIXEL_SIZE.x * 0.9f) ? BUFFER_PIXEL_SIZE.x * 0.25f : 0.0f;

	for (uint sample_idx = group_thread_id.x; sample_idx < NTSC_SOURCE_SAMPLES; sample_idx += LINE_WIDTH) {
        float2 uv = float2(((float)(source_offset + (int)sample_idx) + 0.5f) * BUFFER_PIXEL_SIZE.x, frame_v);

		float3 yiq = float3(0.0f, 0.0f, 0.0f);
		float3 a0 = tex2Dlod(s_ntsc_backbuffer, float4(uv.x - half_step, uv.y, 0, 0)).rgb;
		if (half_step <= 0.0f) {
			yiq = rgb_to_yiq(max(a0, 0.0f));
		} else {
			float3 a1 = tex2Dlod(s_ntsc_backbuffer, float4(uv.x + half_step, uv.y, 0, 0)).rgb;
			yiq = rgb_to_yiq(max(a0 + a1, 0.0f) * 0.5f);
		}

        ntsc_luma[sample_idx] = yiq.x;
        ntsc_chroma[sample_idx] = yiq.yz; //LV: edit, since reshade doesnt support multidimensional arrays
    }
}

void ntsc_encode(uint3 group_thread_id, int signal_offset, int source_offset, uint row_idx,  float frame_v)
{
    float step = BUFFER_PIXEL_SIZE.x;

	for (uint signal_idx = group_thread_id.x; signal_idx < NTSC_SIGNAL_SAMPLES; signal_idx += LINE_WIDTH) {
        int signal_x = max(signal_offset + (int)signal_idx, 0);
        float luma_scale = max(PARAM_LUMA, 0.01f);
        float chroma_scale = max(PARAM_CHROMA, 0.01f);

        uint2 signal_pixel = uint2((uint)signal_x, row_idx);
        float2 carrier = ntsc_carrier(signal_pixel);
        uint chroma_idx = (carrier.y != 0.0f) ? 1u : 0u;
        float chroma_freq = (chroma_idx != 0u) ? NTSC_FREQ_Q : NTSC_FREQ_I;
        
		float2 fir_decay = float2(ntsc_fir_decay(NTSC_FREQ_Y * luma_scale), ntsc_fir_decay(chroma_freq * chroma_scale));
        float2 sum = 0.0f;
        float2 weight = 1.0f;

        [unroll]
		for (int tap_idx = 0; tap_idx < NTSC_ENCODE_TAPS; tap_idx++) {
			int sample_idx = signal_x - source_offset - tap_idx;

			float luma = ntsc_luma[sample_idx];
			float2 chroma = ntsc_chroma[sample_idx];

			// signal convolution and filter
			sum += float2(luma, chroma[chroma_idx]) * weight; //LV: edit, since reshade doesnt support multidimensional arrays
			weight *= (1.0f - fir_decay);
		}
		
		// encode luma and chroma with qam
		float2 signal = fir_decay * sum / max(1.0f - weight, 1e-5f);
		float composite = signal.x + PARAM_SATURATION * (signal.y * (carrier.x + carrier.y));
		float noise = PARAM_NOISE * ntsc_noise(signal_pixel, POST_FIELD);

		ntsc_composite[signal_idx] = composite + noise;
    }	
}

float4 ntsc_decode(uint3 group_thread_id, uint2 pixel)
{
    float fir_decay = ntsc_fir_decay(4.0f * NTSC_FREQ_I * max(PARAM_CHROMA, 0.01f));
    float4 accum = 0.0f;
    float luma = 0.0f;
    float weight = 1.0f;

	// accumulate multiple samples of composite signal by carrier phase
    [unroll]
	for (int cycle_idx = 0; cycle_idx < NTSC_DEMODULATION_CYCLES; cycle_idx++) {
		[unroll]
		for (int phase_idx = 0; phase_idx < 4; phase_idx++) {
			int signal_idx = (int)group_thread_id.x + NTSC_DEMODULATION_CYCLES * 4 - 1 - cycle_idx * 4 - phase_idx;

			float composite = ntsc_composite[signal_idx];
			accum[phase_idx] += weight * composite;
			if (cycle_idx == 0 && (phase_idx & 1) == 0) {
				luma += composite * 0.5f;
			}
		}

		weight *= (1.0f - fir_decay);
	}
	
	// demodulate chroma signal from base signal
	float4 phases = accum * (fir_decay / max(1.0f - weight, 1e-5f));
	float2 state = float2(phases[0] - phases[2], phases[1] - phases[3]);
	float2 carrier = ntsc_carrier(pixel);
	float2 chroma = float2(state.x * carrier.x + state.y * carrier.y, state.x * carrier.y - state.y * carrier.x) * 0.5f;

	return float4(luma, chroma.x, chroma.y, 1.0f);
}

// flattened two-pass solution into one compute shader with barriers
// that works faster than texture read/writes because most of the data stays inside shared memory
void faithful_ntsc_main(uint3 group_id : SV_GroupID, uint3 group_thread_id : SV_GroupThreadID, uint3 dispatch_id : SV_DispatchThreadID)
{
	// variables
    int signal_offset = (int)(group_id.x * LINE_WIDTH) - (NTSC_DEMODULATION_CYCLES * 4 - 1);
    int source_offset = signal_offset - (NTSC_ENCODE_TAPS - 1);
    uint row_idx = min(dispatch_id.y, (uint)BUFFER_HEIGHT - 1u);
    float frame_v = ((float)row_idx + 0.5f) / BUFFER_HEIGHT;

	// read from RGB texture to YIQ shared memory
	ntsc_load_data(group_thread_id, source_offset, frame_v);
    barrier();

	// encode YIQ->composite using quadrature amplitude modulation
	ntsc_encode(group_thread_id, signal_offset, source_offset, row_idx, frame_v);
    barrier();
	
	// demodulate raw composite QAM signal with FIR filters on specific carriers
	if (any(dispatch_id.xy >= (uint2)BUFFER_SCREEN_SIZE)) {
        return;
    }
    
    float4 result = ntsc_decode(group_thread_id, dispatch_id.xy);

    result.xyz = yiq_to_rgb(result.xyz); //LV: Back to RGB
    
	tex2Dstore(u_ntsc, dispatch_id.xy, result);
}

float4 faithful_ntsc_blit(float4 hpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{  
	return tex2Dfetch(s_ntsc, hpos.xy);
}

technique faithful_ntsc <
    ui_label = "Faithful NTSC Filter";
> { 
	pass faithful_ntsc_main { 
        ComputeShader = faithful_ntsc_main<GROUP_SIZE_X, GROUP_SIZE_Y, GROUP_SIZE_Z>;
        DispatchSizeX = BUFFER_WIDTH / GROUP_SIZE_X; 
        DispatchSizeY = BUFFER_HEIGHT / GROUP_SIZE_Y; 
		DispatchSizeZ = GROUP_SIZE_Z;
    }

    pass faithful_ntsc_blit {
		VertexShader = PostProcessVS;
		PixelShader  = faithful_ntsc_blit;
	}      
}