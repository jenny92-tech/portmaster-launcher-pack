运行器和游戏适配 ZIP 完整解压到 SD 卡根目录，保留 roms/windows/ 规范布局。
离线运行环境 ZIP 可直接放在 SD 卡根目录，由 Je-Wine 按包内身份清单识别导入，无需解压或固定外部文件名。
每个游戏包位于 roms/windows/<游戏id>/，bottle.json 描述启动与依赖，完整 Windows 游戏文件放入其 data/。
公共运行器位于 roms/windows/.winecellar/wine-loongos/，离线组件在 .winecellar/packages/，私有运行映像在 .winecellar/state/。
roms/ports/ 中仅有首页桥接脚本，供没有 Windows 分类的固件使用。
龙沉需要先在电脑准备入口，连同生成的 .wine/ 一起放进 data/，详见运行器 README。
自定义游戏参考 bottle.example.json；游戏只声明图形 API，不指定机型路径或打包公共运行库。
