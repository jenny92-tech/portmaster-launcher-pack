// INPUT:  Godot canvas_item、mix_percentage uniform
// OUTPUT: fragment() 输出半透明黑色 COLOR
// POS:    以静态暗化替代昂贵的屏幕模糊
shader_type canvas_item;

uniform float lod: hint_range(0.0, 5.0) = 5.0;
uniform float mix_percentage: hint_range(0.0, 1.0) = 0.3;
uniform bool use_simple_darken = false;

void fragment(){
	COLOR = vec4(0.0, 0.0, 0.0, clamp(mix_percentage, 0.0, 1.0));
}
