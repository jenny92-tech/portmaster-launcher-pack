// INPUT:  原材质 uniform、纹理及 Godot canvas_item
// OUTPUT: 保留参数和混合语义的移动端 Shader 变体
// POS:    Vulkan/OpenGL 共用兼容资源，由 render-compat.json 精确选择
shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float distortion_base_intensity = 0.05;

varying vec4 vertex_color;

void vertex() {
    vertex_color = COLOR;
}

void fragment() {
    vec2 direction = normalize(vec2(0.5) - UV);
    float distortion_mask = texture(TEXTURE, UV).r;
    vec2 offset = distortion_base_intensity * vertex_color.a * distortion_mask * direction;
    COLOR = textureLod(screen_texture, SCREEN_UV + offset, 0.0);
}
