// INPUT:  Godot TEXTURE、UV、顶点 COLOR
// OUTPUT: fragment() 输出纹理与顶点色乘积
// POS:    将叠加混合特效降为单次纹理采样
shader_type canvas_item;

uniform float intensity : hint_range(0,1) = 1.0;

void fragment()
{
	COLOR = texture(TEXTURE, UV) * COLOR;
}
