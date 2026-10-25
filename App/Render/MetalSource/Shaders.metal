#include <metal_stdlib>
using namespace metal;

// Layouts mirror FrameUniforms / SkyUniforms in Renderer.swift and OverlayPoint / OverlaySegment in Overlay.swift.
struct FrameUniforms {
    float2 viewport;
    float redTheme;
    float padding;
    float3x3 sensorFromScreen;
    float2 sensorSize;
    float2 padding2;
};

struct SkyUniforms {
    float3x3 referenceFromScreen;
    float lighting;
    float3 padding;
};

struct PointInstance {
    float2 position;
    float radius;
    float padding;
    float4 color;
};

struct SegmentInstance {
    float2 a;
    float2 b;
    float4 color;
    float4 outlineColor;
    float width;
    float outline;
    float glow;
    float dashPeriod;
    float dashPhase;
    float padding0;
    float padding1;
    float padding2;
};

static float3 applyTheme(float3 c, float red) {
    float luminance = dot(c, float3(0.299, 0.587, 0.114));
    return mix(c, float3(luminance, 0.0, 0.0), red);
}

static float4 toClip(float2 screen, float2 viewport) {
    return float4(screen.x / viewport.x * 2.0 - 1.0, 1.0 - screen.y / viewport.y * 2.0, 0.0, 1.0);
}

struct FullscreenOut {
    float4 position [[position]];
    float2 screen;
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]], constant FrameUniforms &u [[buffer(0)]]) {
    float2 ndc = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
    FullscreenOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.screen = float2((ndc.x + 1.0) * 0.5 * u.viewport.x, (1.0 - ndc.y) * 0.5 * u.viewport.y);
    return out;
}

fragment float4 cameraFragment(FullscreenOut in [[stage_in]],
                               constant FrameUniforms &u [[buffer(0)]],
                               texture2d<float> camera [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_zero);
    float3 sensor = u.sensorFromScreen * float3(in.screen, 1.0);
    float4 c = camera.sample(linearSampler, sensor.xy / u.sensorSize);
    return float4(applyTheme(c.rgb, u.redTheme), 1.0);
}

fragment float4 skyFragment(FullscreenOut in [[stage_in]],
                            constant FrameUniforms &u [[buffer(0)]],
                            constant SkyUniforms &sky [[buffer(1)]]) {
    float3 ray = normalize(sky.referenceFromScreen * float3(in.screen, 1.0));
    float altitude = ray.z;
    float3 nightZenith = float3(0.004, 0.008, 0.025);
    float3 nightHorizon = float3(0.025, 0.04, 0.08);
    float3 dayZenith = float3(0.12, 0.32, 0.68);
    float3 dayHorizon = float3(0.55, 0.70, 0.88);
    float t = sqrt(saturate(altitude));
    float3 night = mix(nightHorizon, nightZenith, t);
    float3 day = mix(dayHorizon, dayZenith, t);
    float3 color = mix(day, night, sky.lighting);
    float3 ground = mix(float3(0.16, 0.15, 0.13), float3(0.012, 0.012, 0.014), sky.lighting);
    color = mix(color, ground, smoothstep(0.0, -0.01, altitude));
    return float4(applyTheme(color, u.redTheme), 1.0);
}

struct PointOut {
    float4 position [[position]];
    float2 local;
    float radius [[flat]];
    float4 color [[flat]];
};

vertex PointOut pointVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant FrameUniforms &u [[buffer(0)]],
                            const device PointInstance *points [[buffer(1)]]) {
    PointInstance p = points[iid];
    float extent = p.radius * 3.0 + 1.5;
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    PointOut out;
    out.position = toClip(p.position + corner * extent, u.viewport);
    out.local = corner * extent;
    out.radius = p.radius;
    out.color = p.color;
    return out;
}

fragment float4 pointFragment(PointOut in [[stage_in]], constant FrameUniforms &u [[buffer(0)]]) {
    float d = length(in.local);
    float core = saturate(in.radius + 0.5 - d);
    float sigma = max(in.radius * 1.1, 0.75);
    float halo = 0.45 * exp(-(d * d) / (2.0 * sigma * sigma));
    float alpha = max(core, halo) * in.color.a;
    return float4(applyTheme(in.color.rgb, u.redTheme) * alpha, alpha);
}

struct SegmentOut {
    float4 position [[position]];
    float along;
    float across;
    float length [[flat]];
    uint instance [[flat]];
};

static float glowRadius(SegmentInstance s) {
    return s.glow * max(s.width, 1.0) * 4.0;
}

vertex SegmentOut segmentVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant FrameUniforms &u [[buffer(0)]],
                                const device SegmentInstance *segments [[buffer(1)]]) {
    SegmentInstance s = segments[iid];
    float2 delta = s.b - s.a;
    float len = length(delta);
    float2 dir = len > 1e-4 ? delta / len : float2(1.0, 0.0);
    float2 normal = float2(-dir.y, dir.x);
    float extent = s.width * 0.5 + s.outline + glowRadius(s) + 1.0;
    bool atEnd = (vid & 1) != 0;
    float along = atEnd ? len + extent : -extent;
    float across = (vid & 2) ? extent : -extent;
    SegmentOut out;
    out.position = toClip(s.a + dir * along + normal * across, u.viewport);
    out.along = along;
    out.across = across;
    out.length = len;
    out.instance = iid;
    return out;
}

// A batch is drawn twice: pass 0 lays down every outline and glow, pass 1 every core on top, so the round caps
// of joined segments (polylines) never cover a neighbour's core with outline.
fragment float4 segmentFragment(SegmentOut in [[stage_in]],
                                constant FrameUniforms &u [[buffer(0)]],
                                const device SegmentInstance *segments [[buffer(1)]],
                                constant uint &pass [[buffer(2)]]) {
    SegmentInstance s = segments[in.instance];
    float clamped = clamp(in.along, 0.0, in.length);
    float d = length(float2(in.along - clamped, in.across));
    float halfWidth = s.width * 0.5;

    float dash = 1.0;
    if (s.dashPeriod > 0.0) {
        float phase = fract((in.along + s.dashPhase) / s.dashPeriod);
        float edge = 1.0 / s.dashPeriod;
        dash = smoothstep(0.0, edge, phase) * (1.0 - smoothstep(0.55 - edge, 0.55, phase));
    }

    if (pass == 1) {
        float alpha = saturate(halfWidth + 0.5 - d) * dash * s.color.a;
        return float4(applyTheme(s.color.rgb, u.redTheme) * alpha, alpha);
    }

    float rimAlpha = s.outline > 0.0 ? saturate(halfWidth + s.outline + 0.5 - d) * dash * s.outlineColor.a : 0.0;
    float radius = glowRadius(s);
    float halo = radius > 0.0 ? s.glow * 0.55 * exp(-pow(max(d - halfWidth, 0.0) / (radius * 0.5), 2.0)) : 0.0;
    float haloAlpha = halo * s.color.a * (1.0 - rimAlpha);
    float3 premultiplied = applyTheme(s.outlineColor.rgb, u.redTheme) * rimAlpha + applyTheme(s.color.rgb, u.redTheme) * haloAlpha;
    return float4(premultiplied, saturate(rimAlpha + haloAlpha));
}
