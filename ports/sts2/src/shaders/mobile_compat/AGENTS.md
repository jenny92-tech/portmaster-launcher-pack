# 兼容着色器变体

27 个基础变体来自 [ModinMobileSTS/sts2-android-compat](https://github.com/ModinMobileSTS/sts2-android-compat)，固定 revision `450082d894167267408e75e014018f684253948d`（Shader 更新 2026-10-08）。它们由 Vulkan/OpenGL 共用；`render-compat.json` 按精确路径、材质路径或内嵌代码哈希选择，原始 Shader 资源不被覆盖。

## 约束

- 保留原材质参数、屏幕采样、时间、实例数据和 alpha 等效果语义；使用有界低采样代替昂贵特效，禁止黑白占位。
- 排除 Ancient 卡片普通 canvas-group mask blur 和用户 MOD；覆盖 PCK 由构建流程生成。
- `wiggle_compat.gdshader` 只供旧版映射，不属于官方原生配置的 27 个变体。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| 2d_sphere_compat.gdshader | `2d_sphere_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| aeonglass_ray_compat.gdshader | `aeonglass_ray_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| blood_wall_compat.gdshader | `blood_wall_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| card_canvas_group_blur_compat.gdshader | `card_canvas_group_blur_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| card_portrait_blur_compat.gdshader | `card_portrait_blur_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| dark_blur_compat.gdshader | `dark_blur_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| doom_overlay_compat.gdshader | `doom_overlay_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| fire_shader_1_compat.gdshader | `fire_shader_1_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| flipbook_compat.gdshader | `flipbook_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| hsv_compat.gdshader | `hsv_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| molten_fist_compat.gdshader | `molten_fist_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| oil_compat.gdshader | `oil_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| overlay_blend_compat.gdshader | `overlay_blend_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| radial_blur_compat.gdshader | `radial_blur_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| radial_blur_smooth.gdshader | `radial_blur_smooth.gdshader` | 流畅档双采样径向模糊，保留原 uniform |
| rest_site_light_compat.gdshader | `rest_site_light_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| row_flipbook_compat.gdshader | `row_flipbook_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| sand_fall_post_compat.gdshader | `sand_fall_post_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| scream_distortion_compat.gdshader | `scream_distortion_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| screen_chromatic_aberration_compat.gdshader | `screen_chromatic_aberration_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| screen_distortion_compat.gdshader | `screen_distortion_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| scry_reveal_compat.gdshader | `scry_reveal_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| slash_compat.gdshader | `slash_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| stepped_fire_add_compat.gdshader | `stepped_fire_add_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| stepped_fire_dark_compat.gdshader | `stepped_fire_dark_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| stepped_fire_flat_compat.gdshader | `stepped_fire_flat_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| water_reflection_compat.gdshader | `water_reflection_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| water_reflection_post_compat.gdshader | `water_reflection_post_compat.gdshader` | 上游兼容变体，保留对应效果与参数 |
| wiggle_compat.gdshader | `wiggle_compat.gdshader` | 旧版映射保留，官方原生配置不收录 |
