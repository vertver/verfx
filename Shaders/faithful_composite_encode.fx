/***************************************************************************************
* Copyright (C) Anton Kovalev (vertver), 2026. All rights reserved.
* Faithful retro shaders
* MIT License
***************************************************************************************/
#include "ReShade.fxh"
#include "verfx.fxh"

uniform float PARAM_LUMA < ui_type = "drag"; ui_label = "Luma"; ui_min = 0.0; ui_max = 1.0; > = 0.60;
uniform float PARAM_CHROMA < ui_type = "drag"; ui_label = "Chroma"; ui_min = 0.0; ui_max = 1.0; > = 0.10;
uniform float PARAM_SATURATION < ui_type = "drag"; ui_label = "Saturation"; ui_min = 0.0; ui_max = 2.0; > = 1.10;
uniform float PARAM_NOISE < ui_type = "drag"; ui_label = "Noise"; ui_min = 0.0; ui_max = 1.0; > = 0.035;
uniform int POST_FIELD < source = "framecount"; >;
uniform int NTSC_ENCODE_TAPS < ui_type = "drag"; ui_label = "Encode Taps"; ui_min = 1; ui_max = 32; > = 24;

texture t_backbuffer : COLOR;

sampler s_backbuffer
{
	Texture = t_backbuffer;
	MipFilter = LINEAR;
	MinFilter = LINEAR;
	MagFilter = LINEAR;
	AddressU = CLAMP;
	AddressV = CLAMP;
	AddressW = CLAMP;
};

float3 ntsc_fetch_yiq(int2 pixel)
{
    float half_step = (BUFFER_WIDTH < BUFFER_PIXEL_SIZE.x * 0.9f) ? BUFFER_PIXEL_SIZE.x * 0.25f : 0.0f;
    float2 uv = (float2(pixel) + 0.5f) * BUFFER_PIXEL_SIZE;

    float3 a0 = tex2Dlod(s_backbuffer, float4(uv.x - half_step, uv.y, 0, 0)).rgb;
    if (half_step <= 0.0f) {
        return rgb_to_yiq(max(a0, 0.0f));
	} else {
		float3 a1 = tex2Dlod(s_backbuffer, float4(uv.x + half_step, uv.y, 0, 0)).rgb;
		return rgb_to_yiq(max(a0 + a1, 0.0f) * 0.5f);
	}
}

float ntsc_encode(int2 pixel)
{
    float2 carrier = ntsc_carrier(pixel, POST_FIELD);
	float lume_scale = max(PARAM_LUMA, 0.01f);
	float chroma_scale = max(PARAM_CHROMA, 0.01f);
    float chroma_freq = ((carrier.y != 0.0f) ? NTSC_FREQ_Q : NTSC_FREQ_I);

    float2 fir_decay = float2(ntsc_fir_decay(NTSC_FREQ_Y * lume_scale), ntsc_fir_decay(chroma_freq * chroma_scale));
    float2 sum = 0.0f;
    float2 weight = 1.0f;

    //[unroll]
    for (int tap_idx = 0; tap_idx < NTSC_ENCODE_TAPS; tap_idx++) {
        float3 yiq = ntsc_fetch_yiq(pixel - int2(tap_idx, 0));
    
        float luma = yiq.x;
        float chroma = carrier.y != 0.0f ? yiq.z : yiq.y;
    
        sum += float2(luma, chroma) * weight; // signal convolution and filter
        weight *= 1.0f - fir_decay;
    }
    
    // encode luma and chroma with qam
    float2 signal = fir_decay * sum / max(1.0f - weight, 1e-5f);
    float composite = signal.x + PARAM_SATURATION * (signal.y * (carrier.x + carrier.y));
    float noise = PARAM_NOISE * ntsc_noise(pixel, POST_FIELD);
    
    return composite + noise;
}

float4 faithful_composite_encode(float4 hpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    int2 pixel = int2(floor(texcoord * BUFFER_SCREEN_SIZE));
    return float4(ntsc_encode(pixel), 0.0f, 0.0f, 1.0f);
}

technique faithful_composite_encode <
    ui_label = "Faithful Composite (Encode)";
> {
    pass faithful_composite_encode {
        VertexShader = PostProcessVS;
        PixelShader = faithful_composite_encode;
    }
}