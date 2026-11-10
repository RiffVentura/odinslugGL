#version 460

#extension GL_ARB_bindless_texture : require

struct GlyphInstance {
    vec4 color[4];
    vec4 dst_rect;
    vec4 src_rect;
    uint band_idx;
};

layout(binding=0, std430) readonly buffer ssbo0 {
    mat4 mvp;
    vec2 screen_dim;
};


layout(binding=3, std430) readonly buffer ssbo3 {
    GlyphInstance glyphs[];
};

const float DILATE_PX = 0.5;

out VS_OUT {
    vec2 pos_em;
    vec4 color;
    flat vec4 glyph_rect;
    flat uint band_idx;
} vs_out;

void main() {

    GlyphInstance glyph = glyphs[gl_InstanceID];

    // Triangle-strip corners: (0,0) (1,0) (0,1) (1,1)
    vec2 corner = vec2(gl_VertexID & 1, (gl_VertexID >> 1) & 1);

    vec2 normal = corner * 2 - 1;
    vec2 dilate = normal * DILATE_PX;

    vec2 dilate_em = dilate * glyph.src_rect.zw / glyph.dst_rect.zw;

    vec2 vert_pos = glyph.dst_rect.xy + corner * glyph.dst_rect.zw + dilate;
	gl_Position = mvp * vec4(vert_pos, 0, 1);

    vs_out.pos_em = glyph.src_rect.xy + corner * glyph.src_rect.zw + dilate_em;
    vs_out.color = glyph.color[gl_VertexID];
    vs_out.band_idx = glyph.band_idx;
    vs_out.glyph_rect = glyph.src_rect;
}
