// INPUT:  原材质 uniform、纹理及 Godot canvas_item
// OUTPUT: 保留参数和混合语义的移动端 Shader 变体
// POS:    Vulkan/OpenGL 共用兼容资源，由 render-compat.json 精确选择
shader_type canvas_item;

// Preserve the original one-tap backbuffer darkening. The previous mobile
// placeholder discarded the scene and returned only a black alpha overlay.
uniform float lod: hint_range(0.0, 5.0) = 5.0;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform float mix_percentage: hint_range(0.0, 1.0) = 0.3;

void fragment() {
    vec4 color = texture(SCREEN_TEXTURE, SCREEN_UV, lod);
    COLOR = mix(color, vec4(0.0, 0.0, 0.0, 1.0), clamp(mix_percentage, 0.0, 1.0));
}
