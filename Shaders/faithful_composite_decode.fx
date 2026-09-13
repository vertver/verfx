/***************************************************************************************
* Copyright (C) Anton Kovalev (vertver), 2026. All rights reserved.
* Faithful retro shaders
* MIT License
***************************************************************************************/
#include "ReShade.fxh"
#include "verfx.fxh"

uniform int POST_FIELD < source = "framecount"; >;
uniform int NTSC_DECODE_TAPS < ui_type = "drag"; ui_label = "Decode Taps"; ui_min = 1; ui_max = 32; > = 24;

texture t_backbuffer : COLOR;

sampler s_backbuffer
{
	Texture = t_backbuffer;
	MipFilter = POINT;
	MinFilter = POINT;
	MagFilter = POINT;
	AddressU = CLAMP;
	AddressV = CLAMP;
	AddressW = CLAMP;
};

float ntsc_fetch_composite(int2 pixel)
{
    float2 uv = (float2(pixel) + 0.5f) * BUFFER_PIXEL_SIZE;
    return tex2Dlod(s_backbuffer, float4(uv, 0, 0)).r;
}

float3 ntsc_decode(int2 pixel)
{
	float luma = 0.0f;
	float2 chroma = float2(0, 0);
    float2 carrier = ntsc_carrier(pixel, POST_FIELD);

	for (int tap_idx = 0; tap_idx < NTSC_DECODE_TAPS; tap_idx++) {
        float composite = ntsc_fetch_composite(pixel - int2(tap_idx, 0));

		// NOTE(vertver): apply FIR coefficents directly for each channel instead of using FIR decay for luma/chroma
        luma += composite * fir_y[tap_idx];
        chroma.x += (composite * carrier.x * 2.0f) * fir_i[tap_idx];
        chroma.y += (composite * carrier.y * 2.0f) * fir_q[tap_idx];
        
		// NOTE(vertver): swap carrier sign
		carrier = float2(carrier.y, -carrier.x);
    }

    return float3(luma, chroma.x, chroma.y);
}

float4 faithful_composite_decode(float4 hpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    int2 pixel = int2(floor(texcoord * BUFFER_SCREEN_SIZE));
    return float4(yiq_to_rgb(ntsc_decode(pixel)), 1.0f);
}

technique faithful_composite_decode <
    ui_label = "Faithful Composite (Decode)";
> {
    pass faithful_composite_decode {
        VertexShader = PostProcessVS;
        PixelShader = faithful_composite_decode;
    }
}