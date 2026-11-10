#version 460 core

#extension GL_ARB_bindless_texture : require

layout(binding=0, std430) readonly buffer ssbo0 {
    mat4 mvp;
    vec2 screen_dim;
};
layout(binding=1, std430) readonly buffer ssbo1 {
    uvec2 pts[];
};

layout(binding=2, std430) readonly buffer ssbo2 {
    uint bands[];
};


void unpackCurve(uint curveStart, out vec2 a, out vec2 b, out vec2 c) {
    uvec2 ab = pts[curveStart];
    uvec2 cx = pts[curveStart+1];

    a = unpackHalf2x16(ab.x);
    b = unpackHalf2x16(ab.y);
    c = unpackHalf2x16(cx.x);
}

uvec2 unpackHeader(uint i) { return uvec2(i & 0xFFFFu, i >> 16u); }

uint rootCode(float a1, float a2, float a3)
{
    uint i1 = floatBitsToUint(a1) >> 31u;
    uint i2 = floatBitsToUint(a2) >> 30u;
    uint i3 = floatBitsToUint(a3) >> 29u;

    uint s = (i2 & 2u) | (i1 & ~2u);
    s = (i3 & 4u) | (s & ~4u);

    return ((0x2E74u >> s) & 0x0101u);
}

vec2 solveH(vec2 p1, vec2 p2, vec2 p3)
{
    vec2 a = p1 - p2*2.0 + p3;
    vec2 b = p1 - p2;
    float ra = 1.0/a.y;
    float rb = 0.5/b.y;

    float d  = sqrt(max(b.y*b.y - a.y*p1.y, 0.0));
    float t1 = (b.y - d) * ra;
    float t2 = (b.y + d) * ra;

    if (abs(a.y) < 1.0/65536.0) t1 = t2 = p1.y * rb;

    return vec2((a.x*t1 - b.x*2.0)*t1 + p1.x,
                (a.x*t2 - b.x*2.0)*t2 + p1.x);
}

vec2 solveV(vec2 p1, vec2 p2, vec2 p3)
{
    vec2 a = p1 - p2*2.0 + p3;
    vec2 b = p1 - p2;
    float ra = 1.0/a.x;
    float rb = 0.5/b.x;

    float d  = sqrt(max(b.x*b.x - a.x*p1.x, 0.0));
    float t1 = (b.x - d) * ra;
    float t2 = (b.x + d) * ra;

    if (abs(a.x) < 1.0/65536.0) t1 = t2 = p1.x * rb;

    return vec2((a.y*t1 - b.y*2.0)*t1 + p1.y,
                (a.y*t2 - b.y*2.0)*t2 + p1.y);
}


in VS_OUT {
    vec2 pos_em;
    vec4 color;
    flat vec4 glyph_rect;
    flat uint band_idx;
} fs_in;
float slugRender()
{

    vec2 renderCoord = fs_in.pos_em;
    uint band_glyph_idx = fs_in.band_idx;
    vec2 glyph_size = fs_in.glyph_rect.zw;
    vec2 glyph_origin = fs_in.glyph_rect.xy;

    renderCoord.y = (glyph_origin.y + glyph_size.y) - (renderCoord.y - glyph_origin.y);

    int curveIndex;

    float xcov = 0.0, xwgt = 0.0;
    float ycov = 0.0, ywgt = 0.0;

    vec2 emsPerPixel = fwidth(renderCoord);
    vec2 pixelsPerEm = 1.0 / emsPerPixel;

    uint hband_header_idx = uint(clamp(8.0 * (renderCoord.y - glyph_origin.y)/glyph_size.y, 0.0, 7.0)) + band_glyph_idx;
    uvec2 hband_header = unpackHeader(bands[hband_header_idx]);

    uint hband_curve_base = band_glyph_idx + hband_header.x;

    for(curveIndex = 0;  curveIndex < int(hband_header.y); curveIndex++)
    {
        uint curveBase = bands[hband_curve_base + curveIndex];
        vec2 p1, p2, p3;
        unpackCurve(curveBase, p1, p2, p3);

        p1 -= renderCoord;
        p2 -= renderCoord;
        p3 -= renderCoord;

        if (max(max(p1.x, p2.x), p3.x) * pixelsPerEm.x < -0.5) break;

        uint code = rootCode(p1.y, p2.y, p3.y);

        if (code != 0u) {
            vec2 r = solveH(p1, p2, p3) * pixelsPerEm.x;

            if ((code & 1u) != 0u) {
                xcov += clamp(r.x  + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.x)* 2.0, 0.0, 1.0));
            }

            if (code > 1u) {
                xcov -= clamp(r.y  + 0.5, 0.0, 1.0);
                xwgt = max(xwgt, clamp(1.0 - abs(r.y)* 2.0, 0.0, 1.0));
            }
        }
    }

    uint vband_header_idx = uint(clamp(8.0 * (renderCoord.x - glyph_origin.x)/glyph_size.x, 0.0, 7.0)) + 8 + band_glyph_idx;
    uvec2 vband_header = unpackHeader(bands[vband_header_idx]);

    uint vband_curve_base = band_glyph_idx + vband_header.x;

    for(curveIndex = 0;  curveIndex < int(vband_header.y); curveIndex++)
    {
        uint curveBase = bands[vband_curve_base + curveIndex];
        vec2 p1, p2, p3;
        unpackCurve(curveBase, p1, p2, p3);

        p1 -= renderCoord;
        p2 -= renderCoord;
        p3 -= renderCoord;

        if (max(max(p1.y, p2.y), p3.y) * pixelsPerEm.y < -0.5) break;

        uint code = rootCode(p1.x, p2.x, p3.x);
        if (code != 0u) {
            vec2 r = solveV(p1, p2, p3) * pixelsPerEm.y;

            if ((code & 1u) != 0u) {
                ycov -= clamp(r.x  + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.x)* 2.0, 0.0, 1.0));
            }

            if (code > 1u) {
                ycov += clamp(r.y  + 0.5, 0.0, 1.0);
                ywgt = max(ywgt, clamp(1.0 - abs(r.y)* 2.0, 0.0, 1.0));
            }
        }
    }

    float coverage = max(abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0), min(abs(xcov), abs(ycov)));
    coverage = 1.0 - abs(1.0 - fract(coverage * 0.5) * 2.0);
    coverage = sqrt(coverage);

    return coverage;
}

out vec4 pixel_color;
void main() {
    pixel_color = fs_in.color * slugRender();
}
