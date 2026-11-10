# Slug implementation in Odin with OpenGL

A basic sample implementation of text rendering using the [Slug algorithm](https://jcgt.org/published/0006/02/02/) by Eric Lengyel. The GLSL shader code is ported from [the reference HLSL shader](https://github.com/EricLengyel/Slug).

The sample preprocesses the font data at runtime for use inside the shaders.
Ideally, fonts should be preprocessed ahead of time and saved in a custom font file.

### Requirements and dependencies
- The code is written in Odin, with OpenGL as the rendering API.
- `stb_truetype` is used for convenience to load and parse font data. Ideally, a more robust loader that offers more features, such as ligatures, would be used instead.
- `kb_text_shape` is used for convenience to shape text.
- `glfw` is used for windowing and OpenGL setup.

### Band data format
Each glyph is split into 8 bands, both vertically and horizontally. The shader code assumes an 8-band split. Why 8? It's just the default value. The band data is stored sequentially by glyph. Each glyph's band data starts with a header of sixteen 32-bit values (8 horizontal + 8 vertical), each holding a 16-bit offset from the glyph base and a 16-bit curve list length. The header is followed by the actual band data: lists of curve indices pointing to the control point data (refer to the original paper for more information).
