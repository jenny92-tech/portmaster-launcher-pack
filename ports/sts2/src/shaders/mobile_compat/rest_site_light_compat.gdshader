// INPUT:  原材质 uniform、纹理及 Godot canvas_item
// OUTPUT: 保留参数和混合语义的移动端 Shader 变体
// POS:    Vulkan/OpenGL 共用兼容资源，由 render-compat.json 精确选择
shader_type canvas_item;
render_mode blend_mix;

uniform vec2 pixel_offset;
uniform sampler2D noise_texture : source_color, repeat_enable;
uniform sampler2D ramp_texture : source_color, repeat_enable;

varying vec2 scale;
varying vec2 uvOffset;
varying vec4 modulate;

void vertex() {
	modulate = COLOR;
	scale = vec2(
		length(vec3(MODEL_MATRIX[0][0], MODEL_MATRIX[0][1], MODEL_MATRIX[0][2])),
		length(vec3(MODEL_MATRIX[1][0], MODEL_MATRIX[1][1], MODEL_MATRIX[1][2])));
	uvOffset = pixel_offset / scale * TEXTURE_PIXEL_SIZE;
}

void fragment() {
	vec2 timeUv = vec2(TIME * 0.5, 0.0);
	vec2 distort = texture(noise_texture, timeUv).xy;
	vec2 uv = (UV - 0.5) / distort + 0.5 - uvOffset;

	vec4 origColor = texture(TEXTURE, UV);
	vec4 distortColor = texture(TEXTURE, uv);
	COLOR = distortColor * texture(ramp_texture, timeUv) * modulate;
	COLOR.a = origColor.a * distortColor.a * modulate.a;
}
