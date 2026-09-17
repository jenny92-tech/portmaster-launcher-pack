// INPUT:  Godot TEXTURE/UV、mask 纹理
// OUTPUT: fragment() 输出掩膜衰减后的原纹理颜色
// POS:    以两次采样透传替代水面反射噪声扭曲
shader_type canvas_item;

// Original: noise-distorted reflection, 3 samples. Compat: 2-sample pass-through.
uniform sampler2D noise : repeat_enable;
uniform sampler2D mask;
uniform float speed : hint_range(0.002,0.5) = 0.1;
uniform float strength : hint_range(0.002,0.5) = 0.1;

void fragment() {
	COLOR = texture(TEXTURE, UV);
	COLOR.a *= texture(mask, UV).a * 0.35;
}
