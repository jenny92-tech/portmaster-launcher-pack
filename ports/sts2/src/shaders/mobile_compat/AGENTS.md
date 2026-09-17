# 移动端替代着色器

> 提供低采样或静态化的 Godot canvas_item 特效。

## 地位

由 make-overlay-pck.py 打包、ShaderCompatibilityPatches 按资源路径替换的着色器资源。

## 逻辑

保留原材质常用 uniform 接口，将模糊、扭曲和混合运算简化为单/双次采样、静态覆盖或透明输出。

## 约束

- 资源文件名和路径必须与 ShaderCompatibilityPatches 映射一致。
- 保留调用方材质参数接口；不恢复昂贵的 SCREEN_TEXTURE 复制或多采样特效。
- 仅修改源码时不自动重建 port_compat.pck。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| dark_blur_compat.gdshader | `dark_blur_compat.gdshader` | 以静态暗化替代昂贵的屏幕模糊 |
| doom_overlay_compat.gdshader | `doom_overlay_compat.gdshader` | 以无三角函数的渐变替代动态 doom 覆盖特效 |
| overlay_blend_compat.gdshader | `overlay_blend_compat.gdshader` | 将叠加混合特效降为单次纹理采样 |
| radial_blur_compat.gdshader | `radial_blur_compat.gdshader` | 以静态光晕代替多次屏幕采样径向模糊 |
| sand_fall_post_compat.gdshader | `sand_fall_post_compat.gdshader` | 以两次采样透传替代落沙噪声扭曲 |
| scream_distortion_compat.gdshader | `scream_distortion_compat.gdshader` | 以单次纹理采样替代尖叫特效的极坐标扭曲 |
| screen_distortion_compat.gdshader | `screen_distortion_compat.gdshader` | 以纹理红色通道遮罩代替屏幕扭曲采样 |
| water_reflection_post_compat.gdshader | `water_reflection_post_compat.gdshader` | 以两次采样透传替代水面反射噪声扭曲 |
| wiggle_compat.gdshader | `wiggle_compat.gdshader` | 关闭热浪屏幕扭曲以免复制屏幕纹理 |

