// ForwardFlow — shader. One pass in screen points (origin top-left), drawn once per recipient:
// the message snapshot on a grid, its vertices carried by a flow into the avatar. Near the avatar
// the message takes on the avatar's color, blurs (coarser mip level) and dissolves at its edge.
//
// Same model as BlackHoleDelete's mesh: the flow goes along rays to the avatar center; its speed
// depends on the "height" above the avatar edge D = ρ·k(φ) − r, k = cos(φ)^shape, where φ is measured
// from the axis avatar → message (any direction, not only "up").
// v(D) = speed · (1 + strength · e^(−D/reach)): far away the copy flies undistorted, near the avatar
// the flow accelerates sharply — the copy stretches into a stream and narrows along rays.

#include <metal_stdlib>
using namespace metal;

struct MeshUniforms {
    float4 view;    // width, height (pt), scale
    float4 hole;    // avatar center x, y, radius (pt), time since this copy started
    float4 flow;    // speed (pt/s), strength, reach (pt), ramp (s)
    float4 extra;   // sink (pt), swirl, shape, acceleration (1/s)
    float4 fade;    // fade start, fade end (radii), max mip level, lean (pt)
    float4 frame;   // message frame x, y, width, height (pt)
    float4 grid;    // columns, rows, axis x, axis y
    float4 tint;    // avatar color rgb, dim of the source still on the copy (0…1)
};

struct MeshOut {
    float4 position [[position]];
    float2 uv;
    float alpha;
    float lod;
    float heat;
};

namespace forwardflow {

float easedTime(float tau, float ramp, float accel) {
    float eased = ramp > 0.001 ? tau - ramp * (1.0 - exp(-tau / ramp)) : tau;
    return accel > 0.001 ? (exp(accel * eased) - 1.0) / accel : eased;
}

float shapeFactor(float rho, float cosPhi, float horizon, float shape) {
    float w = smoothstep(horizon * 1.0, horizon * 4.0, rho);
    return pow(cosPhi, shape * w);
}

constant uint2 corners[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };

}

vertex MeshOut forwardFlowMeshVertex(uint vid [[vertex_id]], constant MeshUniforms &u [[buffer(0)]]) {
    uint cols = uint(u.grid.x);
    uint rows = uint(u.grid.y);
    uint cell = vid / 6;
    uint2 corner = forwardflow::corners[vid % 6];
    float2 uv = float2(float(cell % cols + corner.x) / float(cols),
                       float(cell / cols + corner.y) / float(rows));
    float2 p = u.frame.xy + uv * u.frame.zw;

    float2 center = u.hole.xy;
    float horizon = max(u.hole.z, 1.0);
    float2 axis = u.grid.zw;
    // Lean towards the avatar while the copy peels off: each copy already leans its own way.
    {
        float2 dp = p - center;
        float dl = max(length(dp), 0.001);
        p -= normalize(mix(dp / dl, axis, 0.6)) * u.fade.w;
    }

    float sink = u.extra.x;
    float shape = u.extra.z;
    float2 d = p - center;
    float rho = max(length(d), 0.001);
    float cosPhi = clamp(dot(d, axis) / rho, 0.65, 1.0);
    float height = rho * forwardflow::shapeFactor(rho, cosPhi, horizon, shape) - horizon;

    // New height: travelTime(D') = travelTime(D) − t. With T(D) = R·ln(e^(D/R) + s)/v it has a closed
    // form: e^((D'−D)/R) = (1 + s·e^(−D/R))·e^(−v·t/R) − s·e^(−D/R). No Newton iterations needed.
    float t = forwardflow::easedTime(max(u.hole.w, 0.0), u.flow.w, u.extra.w);
    float reach = max(u.flow.z, 1.0);
    float speed = max(u.flow.x, 1.0);
    float s = u.flow.y;
    float a = exp(-height / reach);
    float arg = (1.0 + s * a) * exp(-speed * t / reach) - s * a;
    float landed = arg > 1e-7 ? height + reach * log(arg) : -sink - 1.0;
    landed = clamp(landed, -sink, height);

    float rhoNew = (landed + horizon) / pow(cosPhi, shape);
    for (int i = 0; i < 4; i++) {
        rhoNew = (landed + horizon) / forwardflow::shapeFactor(rhoNew, cosPhi, horizon, shape);
    }
    float progress = clamp(1.0 - (landed + sink) / max(height + sink, 1.0), 0.0, 1.0);
    float angle = atan2(d.y, d.x) + u.extra.y * progress * progress;
    float2 q = center + float2(cos(angle), sin(angle)) * rhoNew;

    // Near the avatar the message takes on its color and dissolves just inside its edge.
    float rr = rhoNew / horizon;
    float heat = 1.0 - smoothstep(u.fade.y, u.fade.x, rr);
    float visible = smoothstep(u.fade.y, u.fade.y + 0.25, rr);
    if (landed <= -sink + 0.5) { visible = 0.0; }

    MeshOut out;
    out.position = float4(q.x / u.view.x * 2.0 - 1.0, 1.0 - q.y / u.view.y * 2.0, 0.0, 1.0);
    out.uv = uv;
    out.alpha = visible;
    out.lod = heat * heat * u.fade.z;
    out.heat = heat;
    return out;
}

fragment half4 forwardFlowMeshFragment(MeshOut in [[stage_in]], constant MeshUniforms &u [[buffer(0)]],
                                       texture2d<half> texture [[texture(0)]], sampler smp [[sampler(0)]]) {
    half4 color = texture.sample(smp, in.uv, level(in.lod));
    // The source sits under the share sheet's dim: the copy starts dimmed and brightens as it lifts.
    color.rgb *= half(1.0 - u.tint.w);
    half3 tint = half3(u.tint.rgb) * color.a;
    float h = in.heat;
    color.rgb = mix(color.rgb, tint, half(smoothstep(0.0, 0.9, h) * 0.85)) + tint * half(h * 0.2);
    return color * half(in.alpha);
}
