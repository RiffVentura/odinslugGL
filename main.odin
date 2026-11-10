package main


import "core:fmt"
import "core:math/linalg"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
import gl "vendor:OpenGL"
import "vendor:glfw"

import kbts "vendor:kb_text_shape"
import stbtt "vendor:stb/truetype"

GL_VERSION_MAJOR :: 4
GL_VERSION_MINOR :: 6
WIDTH :: 900
HEIGHT :: 600
TITLE :: "OdinGL slug"

GlyphInstance :: struct #align (16) {
	color:    [4][4]f32,
	dst_rect: [4]f32,
	src_rect: [4]f32,
	band_idx: u32,
}

Globals :: struct {
	mvp:        matrix[4, 4]f32,
	screen_dim: [2]f32,
}


framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width: i32, height: i32) {
	gl.Viewport(0, 0, width, height)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
		glfw.SetWindowShouldClose(window, true)
	}
}

processInput :: proc "c" (window: glfw.WindowHandle) {
	if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
		glfw.SetWindowShouldClose(window, true)
	}
}

main :: proc() {

	if !glfw.Init() do panic("glfw has failed to load")
	defer glfw.Terminate()

	glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_VERSION_MAJOR)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_VERSION_MINOR)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

	window_handle := glfw.CreateWindow(WIDTH, HEIGHT, TITLE, nil, nil)
	if window_handle == nil do panic("GLFW has failed to load window")

	glfw.MakeContextCurrent(window_handle)
	gl.load_up_to(GL_VERSION_MAJOR, GL_VERSION_MINOR, glfw.gl_set_proc_address)
	glfw.SwapInterval(1)

	glfw.SetFramebufferSizeCallback(window_handle, framebuffer_size_callback)
	glfw.SetKeyCallback(window_handle, key_callback)
	glfw.SetWindowSize(window_handle, WIDTH, HEIGHT)
	gl.Viewport(0, 0, WIDTH, HEIGHT)

	slug_arena: vmem.Arena
	if err := vmem.arena_init_static(&slug_arena, mem.Megabyte * 100); err != .None {
		fmt.panicf("slug memory: failed to create arena {}", err)
	}
	slug_allocator := vmem.arena_allocator(&slug_arena)

	kbts_arena: vmem.Arena
	if err := vmem.arena_init_static(&kbts_arena, mem.Megabyte * 100); err != .None {
		fmt.panicf("kbts memory: failed to create arena {}", err)
	}
	kbts_allocator := vmem.arena_allocator(&kbts_arena)

	fontfile := "./Cascadia.ttf"
	font_data, read_err := os.read_entire_file_from_path(fontfile, context.allocator)
	assert(read_err == nil)

	slg_font := slugFont_from_font_data(font_data, slug_allocator)

	mvp := init_mvp(WIDTH, HEIGHT)

	font_size: f32 = 50
	line_width: f32 = 500
	line_start := [2]f32{50, 50}

	text := "Slug with Odin - and OpenGL {}*-+< : = > =>"
	text_color := [4]f32{.99, .99, .99, 1}

	glyphs: [dynamic]GlyphInstance
	{
		font_ctx := kbts.CreateShapeContext(kbts.AllocatorFromOdinAllocator(&kbts_allocator))
		font_kbts := kbts.ShapePushFontFromMemory(font_ctx, font_data, 0)
		assert(bool(kbts.FontIsValid(font_kbts)))
		kbts.ShapePushFeature(font_ctx, .liga, 0)
		kbts.ShapePushFeature(font_ctx, .clig, 0)
		kbts.ShapePushFeature(font_ctx, .calt, 0)
		kbts.ShapePushFeature(font_ctx, .dlig, 0)
		kbts.ShapePushFeature(font_ctx, .rlig, 0)
		kbts.ShapePushFeature(font_ctx, .hlig, 0)

		kbts.ShapeBegin(font_ctx, .DONT_KNOW, .DONT_KNOW)
		kbts.ShapeUtf8(font_ctx, text, .CODEPOINT_INDEX)
		kbts.ShapeEnd(font_ctx)

		scale := font_size * slg_font.scale

		cursor := line_start

		for run in kbts.ShapeRun(font_ctx) {
			run := run
			for glyph in kbts.GlyphIteratorNext(&run.Glyphs) {
				char := glyph.Codepoint
				gOffset := [?]f32{f32(glyph.OffsetX), f32(glyph.OffsetY)}
				gAdv := [?]f32{f32(glyph.AdvanceX), f32(glyph.AdvanceY)}

				if abs(line_start.x - cursor.x) + gAdv.x * scale > line_width {
					cursor.y += slg_font.line_height * font_size
					cursor.x = line_start.x
				}

				if glyph.Codepoint != ' ' && glyph.Id != 0 {
					glyphPx := cursor.x + gOffset.x * scale
					glyphPy := cursor.y + gOffset.y * scale

					g := slg_font.glyph_map[u32(glyph.Id)]
					bbox := g.bbox
					bbox.pos *= font_size
					bbox.dim *= font_size
					ascent := slg_font.ascent * font_size
					descent := slg_font.descent * font_size

					yPos := glyphPy + (ascent - bbox.pos.y - bbox.dim.y)
					xPos := glyphPx + bbox.pos.x

					append(
						&glyphs,
						GlyphInstance {
							dst_rect = {
								xPos,
								yPos,
								g.bbox.dim.x * font_size,
								g.bbox.dim.y * font_size,
							},
							src_rect = transmute([4]f32)g.bbox,
							band_idx = g.band_data_idx,
							color = {text_color, text_color, text_color, text_color},
						},
					)
				}

				cursor += gAdv * scale
			}
		}
	}

	program_id, program_load_ok := gl.load_shaders_file("./slug.vert", "./slug.frag")
	if !program_load_ok {
		msg1, _, msg2, _ := gl.get_last_error_messages()
		fmt.println(msg1, msg2)
	}
	vao, vbo: u32
	gl.GenVertexArrays(1, &vao)

	globals := Globals {
		screen_dim = {WIDTH, HEIGHT},
		mvp        = mvp,
	}
	globals_buffer_id: u32
	gl.CreateBuffers(1, &globals_buffer_id)
	gl.NamedBufferStorage(globals_buffer_id, size_of(globals), &globals, gl.DYNAMIC_STORAGE_BIT)

	points_buffer_id: u32
	gl.CreateBuffers(1, &points_buffer_id)
	gl.NamedBufferStorage(
		points_buffer_id,
		size_of([4]f16) * len(slg_font.control_points_data),
		raw_data(slg_font.control_points_data),
		gl.DYNAMIC_STORAGE_BIT,
	)

	band_data_buffer_id: u32
	gl.CreateBuffers(1, &band_data_buffer_id)
	gl.NamedBufferStorage(
		band_data_buffer_id,
		size_of(u32) * len(slg_font.bands_data),
		raw_data(slg_font.bands_data),
		gl.DYNAMIC_STORAGE_BIT,
	)

	glyphs_buffer_id: u32
	gl.CreateBuffers(1, &glyphs_buffer_id)
	gl.NamedBufferStorage(
		glyphs_buffer_id,
		size_of(GlyphInstance) * len(glyphs),
		raw_data(glyphs),
		gl.DYNAMIC_STORAGE_BIT,
	)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	for !glfw.WindowShouldClose(window_handle) {

		glfw.PollEvents()
		processInput(window_handle)

		gl.ClearColor(0, .5, .6, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		gl.BindVertexArray(vao)
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, globals_buffer_id)
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, points_buffer_id)
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 2, band_data_buffer_id)
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 3, glyphs_buffer_id)

		gl.UseProgram(program_id)
		gl.BindVertexArray(vao)
		gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, i32(len(glyphs)))

		glfw.SwapBuffers(window_handle)
	}
}

BAND_NUM :: 8
Curve :: struct {
	p0, p1, p2: [2]f32,
	last:       bool,
}

Band_Entry :: struct {
	idx: u32,
	max: f32,
}
GlyphID :: u32
GlyphRecord :: struct #align (32) {
	bbox:          struct {
		pos: [2]f32,
		dim: [2]f32,
	},
	band_data_idx: u32,
	id:            GlyphID,
}
SlugFont :: struct {
	glyph_count:           int,
	scale:                 f32,
	ascent, descent:       f32,
	line_gap, line_height: f32,
	glyphs:                [dynamic]GlyphRecord,
	control_points_data:   [dynamic][4]f16,
	bands_data:            [dynamic]u32,
	glyph_map:             map[GlyphID]^GlyphRecord,
}

slugFont_from_font_data :: proc(font_data: []byte, allocator := context.allocator) -> SlugFont {
	context.allocator = allocator
	result: SlugFont

	result.control_points_data = make([dynamic][4]f16)
	result.bands_data = make([dynamic]u32)
	result.glyphs = make([dynamic]GlyphRecord)
	result.glyph_map = make(map[GlyphID]^GlyphRecord)

	font: stbtt.fontinfo
	stbtt.InitFont(&font, raw_data(font_data), stbtt.GetFontOffsetForIndex(raw_data(font_data), 0))

	em_scale := stbtt.ScaleForMappingEmToPixels(&font, 1.0)
	result.scale = em_scale

	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&font, &ascent, &descent, &line_gap)
	result.ascent = f32(ascent) * em_scale
	result.descent = f32(descent) * em_scale
	result.line_gap = f32(line_gap) * em_scale
	result.line_height = result.ascent - result.descent + result.line_gap

	// WARNING: not the best way to iterate all the glyphs in the font
	// also there maybe id instabilities font to font.
	// TODO: refactor
	for cpt in 0 ..< 0x10000 {
		id := stbtt.FindGlyphIndex(&font, rune(cpt))
		if id == 0 {
			continue
		}


		glyph: GlyphRecord
		glyph.id = u32(id)

		curves: [dynamic]Curve
		{
			verts: [^]stbtt.vertex
			verts_count := stbtt.GetGlyphShape(&font, id, &verts)
			if verts_count == 0 {
				continue
			}

			last_point: [2]f32
			for i in 0 ..< verts_count {
				v := verts[i]
				current_point := [2]f32{f32(v.x), f32(v.y)}
				defer last_point = current_point

				switch v.type {
				case u8(stbtt.vmove.vmove):
					if i > 0 do curves[len(curves) - 1].last = true

				case u8(stbtt.vmove.vline):
					mid := (last_point + current_point) * 0.5
					append(&curves, Curve{last_point, mid, current_point, false})
				case u8(stbtt.vmove.vcurve):
					append(
						&curves,
						Curve{last_point, {f32(v.cx), f32(v.cy)}, current_point, false},
					)
				case u8(stbtt.vmove.vcubic):
					c1 := [2]f32{f32(v.cx), f32(v.cy)}
					c2 := [2]f32{f32(v.cx1), f32(v.cy1)}

					quads: [dynamic]Curve
					cubic_to_quad(&quads, last_point, c1, c2, current_point)
					for q in quads do append(&curves, q)
				}
			}

			curves[len(curves) - 1].last = true
		}

		x0, y0, x1, y1: i32
		stbtt.GetGlyphBox(&font, id, &x0, &y0, &x1, &y1)
		glyph.bbox.pos = {f32(x0), f32(y0)}
		glyph.bbox.dim = {f32(x1 - x0), f32(y1 - y0)}

		hbands: [BAND_NUM][dynamic]Band_Entry
		vbands: [BAND_NUM][dynamic]Band_Entry
		band_h := glyph.bbox.dim.y / BAND_NUM
		band_w := glyph.bbox.dim.x / BAND_NUM

		for c in curves {
			p0 := em_scale * c.p0
			p1 := em_scale * c.p1
			p2 := em_scale * c.p2
			ctrl_point_idx := u32(len(result.control_points_data))
			append(&result.control_points_data, [4]f16{f16(p0.x), f16(p0.y), f16(p1.x), f16(p1.y)})
			if c.last {
				append(&result.control_points_data, [4]f16{f16(p2.x), f16(p2.y), 0, 0})
			}

			curve_min_x := min(c.p0.x, c.p1.x, c.p2.x)
			curve_max_x := max(c.p0.x, c.p1.x, c.p2.x)
			curve_min_y := min(c.p0.y, c.p1.y, c.p2.y)
			curve_max_y := max(c.p0.y, c.p1.y, c.p2.y)

			skip_for_v_band := c.p0.x == c.p1.x && c.p0.x == c.p2.x
			skip_for_h_band := c.p0.y == c.p1.y && c.p0.y == c.p2.y

			if !skip_for_h_band {
				span_start := clamp(
					int((curve_min_y - glyph.bbox.pos.y) / band_h),
					0,
					BAND_NUM - 1,
				)
				span_end := clamp(int((curve_max_y - glyph.bbox.pos.y) / band_h), 0, BAND_NUM - 1)
				for i in span_start ..= span_end {
					append(&hbands[i], Band_Entry{ctrl_point_idx, curve_max_x})
				}
			}

			if !skip_for_v_band {
				span_start := clamp(
					int((curve_min_x - glyph.bbox.pos.x) / band_w),
					0,
					BAND_NUM - 1,
				)
				span_end := clamp(int((curve_max_x - glyph.bbox.pos.x) / band_w), 0, BAND_NUM - 1)
				for i in span_start ..= span_end {
					append(&vbands[i], Band_Entry{ctrl_point_idx, curve_max_y})
				}
			}
		}

		band_base := len(result.bands_data)
		glyph.band_data_idx = u32(band_base)
		//push empty space for known headers count
		for b in 0 ..< BAND_NUM * 2 do append(&result.bands_data, 0)
		band_current_offset := band_base + BAND_NUM * 2

		for b in 0 ..< BAND_NUM {
			slice.sort_by(hbands[b][:], proc(i, j: Band_Entry) -> bool {
				return i.max > j.max
			})

			hband := hbands[b]
			band_offset := len(result.bands_data)
			for i in hband do append(&result.bands_data, i.idx)

			hband_header :=
				u32(band_offset - band_base) & 0xFFFF | (u32(len(hband)) & 0xFFFF) << 16
			result.bands_data[band_base + int(b)] = hband_header
		}
		for b in 0 ..< BAND_NUM {
			slice.sort_by(vbands[b][:], proc(i, j: Band_Entry) -> bool {
				return i.max > j.max
			})

			vband := vbands[b]
			band_offset := len(result.bands_data)
			for i in vband do append(&result.bands_data, i.idx)

			vband_header :=
				u32(band_offset - band_base) & 0xFFFF | (u32(len(vband)) & 0xFFFF) << 16
			result.bands_data[band_base + int(b + BAND_NUM)] = vband_header
		}

		//TODO:: see if we can scale everything in one place instead of scattering it
		glyph.bbox.pos *= em_scale
		glyph.bbox.dim *= em_scale

		append(&result.glyphs, glyph)
		result.glyph_map[glyph.id] = &result.glyphs[len(result.glyphs) - 1]
	}
	return result
}

cubic_to_quad :: proc(
	quads: ^[dynamic]Curve,
	c0, c1, c2, c3: [2]f32,
	tolerance: f32 = 0.5,
	depth := 0,
) {

	//midpoint approx from cubic to quad.
	q := Curve{c0, (3 * c1 + 3 * c2 - c0 - c3) / 4, c3, false}

	quad_approx_error: f32 = max(
		linalg.length(c1 - (q.p0 + (2.0 / 3.0) * (q.p1 - q.p0))),
		linalg.length(c2 - (q.p2 + (2.0 / 3.0) * (q.p1 - q.p2))),
	)

	if depth >= 16 || quad_approx_error <= tolerance {
		append(quads, q)
		return
	}
	split_t := [2]f32{0.5, 0.5}
	p01 := linalg.lerp(c0, c1, split_t)
	p12 := linalg.lerp(c1, c2, split_t)
	p23 := linalg.lerp(c2, c3, split_t)
	p012 := linalg.lerp(p01, p12, split_t)
	p123 := linalg.lerp(p12, p23, split_t)
	mid := linalg.lerp(p012, p123, split_t)

	cubic_to_quad(quads, c0, p01, p012, mid, tolerance, depth + 1)
	cubic_to_quad(quads, mid, p123, p23, c3, tolerance, depth + 1)
}

init_mvp :: proc(view_width, view_height: f32) -> matrix[4, 4]f32 {
	pos := [3]f32{0, 0, -1}
	rot: f32 = 0

	target := pos - [3]f32{0, 0, 1}
	camera_rot_rad := linalg.to_radians(rot)
	up := [?]f32{linalg.sin(camera_rot_rad), linalg.cos(camera_rot_rad), -1}

	projection := linalg.matrix_ortho3d_f32(0, view_width, view_height, 0, -1, 1)
	mvp := projection * linalg.matrix4_look_at(pos, target, up)

	return mvp
}
