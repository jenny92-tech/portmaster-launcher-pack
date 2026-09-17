// INPUT:  Godot TEXTURE/UV/COLOR、distortion_base_intensity
// OUTPUT: vertex() 传递颜色，fragment() 输出衰减遮罩
// POS:    以纹理红色通道遮罩代替屏幕扭曲采样
shader_type canvas_item;
render_mode blend_mix;

uniform float distortion_base_intensity = 0.05;

varying vec4 vertex_color;

void vertex() {
	vertex_color = COLOR;
}

void fragment()
{
	float distortion_mask = texture(TEXTURE, UV).r;
	float alpha = clamp(distortion_mask * vertex_color.a * distortion_base_intensity * 6.0, 0.0, 1.0);
	COLOR = vec4(vec3(1.0), alpha * 0.22);
}
