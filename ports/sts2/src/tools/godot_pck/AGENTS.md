# Godot PCK 资源处理

> 恢复、重导入和覆盖打包掌机可用的 Godot 纹理资源。

## 地位

STS2 移植工具中的通用资源处理流水线与游戏专属方案入口。

## 逻辑

extract 恢复项目，Python 工具调整尺寸/压缩/mipmap，reimport 生成设备纹理，strip 工具裁剪冗余内容，apply_overlay 或 repack 输出资源包。

## 约束

- GDRE/Godot 工具和 work 中间目录属于外部依赖/生成物，不作为仓库源码维护。
- 优先理解覆盖与全量重打包的区别；缺少扩展的宿主编辑器无法完整重建原游戏资源。
- 多数脚本会写项目或删除冗余资源，验证文档只做解析/静态检查，不直接运行转换流水线。

## 业务域清单

| 名称 | 文件/子目录 | 职责 |
|------|------------|------|
| apply_overlay.py | `apply_overlay.py` | 将恢复资源覆盖到原始包并保留无法重建的扩展资源 |
| cap_particle_amount.py | `cap_particle_amount.py` | 在离线资源处理中降低粒子发射数量 |
| force_vram_compress.py | `force_vram_compress.py` | 为重导入提前将无损纹理切换到 GPU 压缩模式 |
| limit_texture_size.py | `limit_texture_size.py` | 按全局与路径规则限制移动端纹理重导入尺寸 |
| patch_project.py | `patch_project.py` | 配置恢复工程的 ASTC/ETC2 压缩目标及定制编辑器参数 |
| set_mipmaps.py | `set_mipmaps.py` | 在重导入前统一控制移动端纹理 mipmap 链 |
| strip_non_astc.py | `strip_non_astc.py` | 在重导入后移除 Mali 无法使用的 BPTC/S3TC 资源 |
| strip_sources.py | `strip_sources.py` | 在重打包前移除已被导入资源替代的冗余源图片 |
| extract.sh | `extract.sh` | 为资源压缩与覆盖补丁准备 PCK 恢复工作树 |
| reimport.sh | `reimport.sh` | 按修改后的纹理策略清理缓存并重新导入资源 |
| repack.sh | `repack.sh` | 为可完整重建的 Godot 项目提供直接重打包入口 |
| verify_astc_8x8.sh | `verify_astc_8x8.sh` | 只读检查移动纹理重导入是否生成预期 ASTC 8x8 格式 |
| README.md | `README.md` | 纹理压缩流水线与使用说明 |
| bin-README.md | `bin-README.md` | 外部 GDRE/Godot 工具准备说明 |
| .gitignore | `.gitignore` | 外部工具、工作树与资源产物忽略规则 |
| patches | `patches/` | 按游戏组织的覆盖内容和构建方案 |
