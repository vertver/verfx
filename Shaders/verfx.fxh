/***************************************************************************************
* Copyright (C) Anton Kovalev (vertver), 2026. All rights reserved.
* Faithful retro shaders
* MIT License
***************************************************************************************/
#ifndef VERFX_H_
#define VERFX_H_

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

float2 ntsc_carrier(float2 pixel, float base_field)
{
    float field = pixel.x + 2.0f * pixel.y + (base_field - 4.0f * floor(base_field * 0.25f));
    field -= 4.0f * floor(field * 0.25f);
    float sign = field >= 2.0f ? -1.0f : 1.0f;
    return (field == 1.0f || field == 3.0f) ? float2(0.0f, sign) : float2(sign, 0.0f);
}

// NOTE(vertver): since SM3 doesn't support bitfield operations, I use float hash instead
// https://www.shadertoy.com/view/4djSRW
float ntsc_noise(float2 pixel, float field)
{
	float3 p3 = float3(pixel, field);
	p3 = frac(p3 * 0.1031f);
    p3 += dot(p3, p3.zyx + 33.33f);
    return frac((p3.x + p3.y) * p3.z) - 0.5f;
}

#endif