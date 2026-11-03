// INPUT:  原材质 uniform、纹理及 Godot canvas_item
// OUTPUT: 保留参数和混合语义的移动端 Shader 变体
// POS:    Vulkan/OpenGL 共用兼容资源，由 render-compat.json 精确选择
shader_type canvas_item;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture;
uniform float intensity : hint_range(0.0, 1.0) = 1.0;

vec4 overlay(vec4 base, vec4 blend) {
    vec4 limit = step(vec4(0.5), base);
    return mix(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), limit);
}

void fragment() {
    vec4 background = texture(SCREEN_TEXTURE, SCREEN_UV);
    COLOR.rgb = mix(COLOR, overlay(background, COLOR), intensity).rgb;
}
