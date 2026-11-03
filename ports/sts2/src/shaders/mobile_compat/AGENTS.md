# 兼容着色器变体

运行时按上级 render-compat.json 的资源路径、材质路径或内嵌代码哈希选择本目录变体，Vulkan/OpenGL 共用且不覆盖原始 Shader 资源。27 个基础变体固定来自 [ModinMobileSTS/sts2-android-compat](https://github.com/ModinMobileSTS/sts2-android-compat) 的 `450082d894167267408e75e014018f684253948d`；另有流畅档径向模糊及旧版 wiggle。下表按实际 uniform 接口定位变体。

## 约束

- 保留原材质参数、屏幕采样、时间、实例数据和 alpha 等效果语义；使用有界低采样代替昂贵特效，禁止黑白占位。
- 排除 Ancient 卡片普通 canvas-group mask blur 和用户 MOD；覆盖 PCK 由构建流程生成。
- `wiggle_compat.gdshader` 只供旧版映射，不属于官方原生配置的 27 个变体。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 2d_sphere_compat.gdshader | `2d_sphere_compat.gdshader` | AddColor、噪声和侧面/上下遮罩 |
| aeonglass_ray_compat.gdshader | `aeonglass_ray_compat.gdshader` | Progress、RayTex 与边缘遮罩 |
| blood_wall_compat.gdshader | `blood_wall_compat.gdshader` | 双噪声层与可反转噪声遮罩 |
| card_canvas_group_blur_compat.gdshader | `card_canvas_group_blur_compat.gdshader` | 屏幕纹理、mask_region 与 blur 开关 |
| card_portrait_blur_compat.gdshader | `card_portrait_blur_compat.gdshader` | step/radius 控制的卡图模糊 |
| dark_blur_compat.gdshader | `dark_blur_compat.gdshader` | 屏幕 LOD 与 mix_percentage |
| doom_overlay_compat.gdshader | `doom_overlay_compat.gdshader` | 屏幕纹理、亮度和 gradient_color |
| fire_shader_1_compat.gdshader | `fire_shader_1_compat.gdshader` | 双噪声、顶部渐变及 Shape_Mask |
| flipbook_compat.gdshader | `flipbook_compat.gdshader` | 帧布局、曲线、侵蚀和色相输入 |
| hsv_compat.gdshader | `hsv_compat.gdshader` | h/s/v 颜色参数 |
| molten_fist_compat.gdshader | `molten_fist_compat.gdshader` | 双噪声强度、平移和 NoiseMask |
| oil_compat.gdshader | `oil_compat.gdshader` | 法力值、槽线动画及边框颜色 |
| overlay_blend_compat.gdshader | `overlay_blend_compat.gdshader` | 屏幕纹理与 intensity 混合 |
| radial_blur_compat.gdshader | `radial_blur_compat.gdshader` | blur_center、blur_power 与采样次数 |
| radial_blur_smooth.gdshader | `radial_blur_smooth.gdshader` | 同径向接口，流畅档双采样实现 |
| rest_site_light_compat.gdshader | `rest_site_light_compat.gdshader` | 像素偏移、噪声和渐变纹理 |
| row_flipbook_compat.gdshader | `row_flipbook_compat.gdshader` | 行序列帧、侵蚀与色相曲线 |
| sand_fall_post_compat.gdshader | `sand_fall_post_compat.gdshader` | 屏幕/噪声/遮罩及流动角度 |
| scream_distortion_compat.gdshader | `scream_distortion_compat.gdshader` | 屏幕扭曲强度、平铺和偏移速度 |
| screen_chromatic_aberration_compat.gdshader | `screen_chromatic_aberration_compat.gdshader` | 屏幕采样与强度/距离曲线 |
| screen_distortion_compat.gdshader | `screen_distortion_compat.gdshader` | 屏幕纹理及基础扭曲强度 |
| scry_reveal_compat.gdshader | `scry_reveal_compat.gdshader` | 双噪声、圆形数据和网格淡出参数 |
| slash_compat.gdshader | `slash_compat.gdshader` | 形状遮罩、双噪声与 opacity |
| stepped_fire_add_compat.gdshader | `stepped_fire_add_compat.gdshader` | 内外火焰颜色、噪声及扭曲层 |
| stepped_fire_dark_compat.gdshader | `stepped_fire_dark_compat.gdshader` | GlobalOffset 与分层火焰参数 |
| stepped_fire_flat_compat.gdshader | `stepped_fire_flat_compat.gdshader` | 平面火焰颜色、噪声和遮罩 |
| water_reflection_compat.gdshader | `water_reflection_compat.gdshader` | 水面噪声、遮罩、速度和强度 |
| water_reflection_post_compat.gdshader | `water_reflection_post_compat.gdshader` | 水面参数加屏幕纹理采样 |
| wiggle_compat.gdshader | `wiggle_compat.gdshader` | 旧版 NOISE_TEXTURE 与方向/速度接口 |
