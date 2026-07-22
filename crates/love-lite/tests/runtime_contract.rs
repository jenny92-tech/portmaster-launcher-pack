use std::fs;

use love_lite::{Engine, GpuCommand};
use mlua::{String as LuaString, Table as LuaTable};
use tempfile::TempDir;

fn game(main: &str) -> TempDir {
    let directory = tempfile::tempdir().expect("temporary game directory");
    fs::write(directory.path().join("main.lua"), main).expect("write main.lua");
    directory
}

#[test]
fn lua_can_request_smooth_redraws_only_while_animating() {
    let directory = game(
        r#"
        active = false
        function love.isAnimating() return active end
        "#,
    );
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    assert!(!engine.is_animating().expect("read idle state"));
    engine
        .runtime
        .lua
        .load("active = true")
        .exec()
        .expect("enable animation");
    assert!(engine.is_animating().expect("read animation state"));
}

#[test]
fn app_graphics_can_record_a_gpu_command_frame() {
    let directory = game(
        r#"
        function love.draw()
            love.graphics.setColor(0.2, 0.3, 0.4, 0.8)
            love.graphics.rectangle("fill", 4, 5, 30, 20, 4, 4)
            love.graphics.setLineWidth(2)
            love.graphics.line(1, 2, 20, 22)
            love.graphics.polygon("fill", 3, 4, 9, 10, 2, 12)
            love.graphics.print("GPU", 8, 9)
        end
        "#,
    );
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    let commands = engine
        .draw_gpu()
        .expect("record GPU frame")
        .expect("supported GPU frame");
    assert!(matches!(commands[0], GpuCommand::Clear { .. }));
    assert!(
        commands
            .iter()
            .any(|command| matches!(command, GpuCommand::Rectangle { .. }))
    );
    assert!(
        commands
            .iter()
            .any(|command| matches!(command, GpuCommand::Line { .. }))
    );
    assert!(
        commands
            .iter()
            .any(|command| matches!(command, GpuCommand::Polygon { .. }))
    );
    assert!(
        commands
            .iter()
            .any(|command| matches!(command, GpuCommand::Image { .. }))
    );
}

#[test]
fn unsupported_stencil_frame_requests_cpu_fallback() {
    let directory = game(
        r#"
        function love.draw()
            love.graphics.stencil(function()
                love.graphics.rectangle("fill", 1, 1, 8, 8)
            end, "replace", 1)
            love.graphics.setStencilTest("equal", 0)
            love.graphics.rectangle("fill", 0, 0, 16, 16)
            love.graphics.setStencilTest()
        end
        "#,
    );
    let engine = Engine::load(directory.path(), 32, 24).expect("load runtime");
    assert!(
        engine.draw_gpu().expect("record GPU frame").is_none(),
        "stencil must use the per-frame CPU fallback"
    );
    engine.draw().expect("render CPU fallback");
}

#[test]
fn exposes_launcher_api_contract() {
    let directory = game("");
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    let functions: LuaTable = engine
        .runtime
        .lua
        .load(
            r#"
            return {
                love.event.quit,
                love.filesystem.getInfo,
                love.filesystem.getSource,
                love.filesystem.newFileData,
                love.graphics.draw,
                love.graphics.getDimensions,
                love.graphics.line,
                love.graphics.newFont,
                love.graphics.newImage,
                love.graphics.polygon,
                love.graphics.pop,
                love.graphics.print,
                love.graphics.printf,
                love.graphics.push,
                love.graphics.rectangle,
                love.graphics.setBackgroundColor,
                love.graphics.setColor,
                love.graphics.setFont,
                love.graphics.setLineWidth,
                love.graphics.setScissor,
                love.graphics.setStencilTest,
                love.graphics.stencil,
                love.graphics.translate,
            }
            "#,
        )
        .eval()
        .expect("collect API");
    assert_eq!(functions.raw_len(), 23);

    let source: String = engine
        .runtime
        .lua
        .load("return love.filesystem.getSource()")
        .eval()
        .expect("get source");
    assert_eq!(
        std::path::Path::new(&source),
        directory.path().canonicalize().expect("canonical source")
    );
}

#[test]
fn file_data_keeps_binary_contents() {
    let directory = game("");
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    let (value, size, name): (LuaString, i64, String) = engine
        .runtime
        .lua
        .load(
            r#"
            local data = love.filesystem.newFileData("a\0b", "font.ttf")
            return data:getString(), data:getSize(), data:getFilename()
            "#,
        )
        .eval()
        .expect("create FileData");
    assert_eq!(value.as_bytes().as_ref(), b"a\0b");
    assert_eq!(size, 3);
    assert_eq!(name, "font.ttf");
}

#[test]
fn loads_the_packaged_chinese_font_from_file_data() {
    let directory = game("");
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    let font_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../ports/appmanager/portable/share/NotoSansSC-Regular.ttf");
    let bytes = fs::read(font_path).expect("read packaged font");
    engine
        .runtime
        .lua
        .globals()
        .set(
            "font_bytes",
            engine.runtime.lua.create_string(&bytes).unwrap(),
        )
        .expect("publish font bytes");
    let (height, width): (f32, f32) = engine
        .runtime
        .lua
        .load(
            r#"
            local data = love.filesystem.newFileData(font_bytes, "NotoSansSC-Regular.ttf")
            local font = love.graphics.newFont(data, 20)
            return font:getHeight(), font:getWidth("中文")
            "#,
        )
        .eval()
        .expect("load font from FileData");
    assert!(
        (28.0..=30.0).contains(&height),
        "font size must retain LÖVE's pixels-per-em semantics, got height {height}"
    );
    assert!(
        (39.0..=43.0).contains(&width),
        "two full-width glyphs at 20px plus handheld weight compensation must remain about 40px wide, got {width}"
    );
}

#[test]
fn fractional_font_sizes_snap_to_physical_pixels() {
    let directory = game("");
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    let font_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../ports/appmanager/portable/share/NotoSansSC-Regular.ttf");
    let bytes = fs::read(font_path).expect("read packaged font");
    engine
        .runtime
        .lua
        .globals()
        .set(
            "font_bytes",
            engine.runtime.lua.create_string(&bytes).unwrap(),
        )
        .expect("publish font bytes");
    let (integer_width, fractional_width, integer_height, fractional_height): (f32, f32, f32, f32) =
        engine
            .runtime
            .lua
            .load(
                r#"
                local data = love.filesystem.newFileData(font_bytes, "NotoSansSC-Regular.ttf")
                local integer = love.graphics.newFont(data, 20)
                local fractional = love.graphics.newFont(data, 20.4)
                return integer:getWidth("像素 Pixel"), fractional:getWidth("像素 Pixel"),
                    integer:getHeight(), fractional:getHeight()
                "#,
            )
            .eval()
            .expect("measure snapped font sizes");
    assert!((integer_width - fractional_width).abs() < 0.001);
    assert!((integer_height - fractional_height).abs() < 0.001);
}

#[test]
fn wraps_long_paths_without_spaces() {
    let directory = game("");
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    let font_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../ports/appmanager/portable/share/NotoSansSC-Regular.ttf");
    let bytes = fs::read(font_path).expect("read packaged font");
    engine
        .runtime
        .lua
        .globals()
        .set(
            "font_bytes",
            engine.runtime.lua.create_string(&bytes).unwrap(),
        )
        .expect("publish font bytes");
    let (count, first_width, last_width): (usize, f32, f32) = engine
        .runtime
        .lua
        .load(
            r#"
            local data = love.filesystem.newFileData(font_bytes, "NotoSansSC-Regular.ttf")
            local font = love.graphics.newFont(data, 20)
            local _, lines = font:getWrap("/mnt/sdcard/roms/ports/PortMaster/libs", 120)
            return #lines, font:getWidth(lines[1]), font:getWidth(lines[#lines])
            "#,
        )
        .eval()
        .expect("wrap path");
    assert!(count >= 2, "an unbroken path was not wrapped");
    assert!(first_width <= 120.5, "first line exceeds wrap width");
    assert!(last_width <= 120.5, "last line exceeds wrap width");
}

#[test]
fn loads_the_packaged_font_directly_without_a_lua_byte_copy() {
    let directory = game("");
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    let font_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../ports/appmanager/portable/share/NotoSansSC-Regular.ttf")
        .canonicalize()
        .expect("canonical font path");
    engine
        .runtime
        .lua
        .globals()
        .set("font_path", font_path.to_string_lossy().as_ref())
        .expect("publish font path");
    let width: f32 = engine
        .runtime
        .lua
        .load(
            r#"
            local font = love.graphics.newFont(font_path, 20)
            return font:getWidth("中文")
            "#,
        )
        .eval()
        .expect("load font from absolute path");
    assert!(width > 0.0);
}

#[test]
fn font_sizes_share_one_parsed_font_file() {
    let directory = game("");
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    let font_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../ports/appmanager/portable/share/NotoSansSC-Regular.ttf");
    let bytes = fs::read(font_path).expect("read packaged font");
    engine
        .runtime
        .lua
        .globals()
        .set(
            "font_bytes",
            engine.runtime.lua.create_string(&bytes).unwrap(),
        )
        .expect("publish font bytes");
    let (first, second): (u64, u64) = engine
        .runtime
        .lua
        .load(
            r#"
            local data = love.filesystem.newFileData(font_bytes, "NotoSansSC-Regular.ttf")
            local small = love.graphics.newFont(data, 16)
            local large = love.graphics.newFont(data, 28)
            return small._font_id, large._font_id
            "#,
        )
        .eval()
        .expect("load two font sizes");
    assert_eq!(first, second, "the same font file was parsed twice");
}

#[test]
fn renders_and_preserves_quit_code() {
    let directory = game(
        r#"
        function love.keypressed(key)
            if key == "return" then love.event.quit(42) end
        end
        function love.draw()
            love.graphics.setColor(1, 0, 0, 1)
            love.graphics.rectangle("fill", 2, 2, 10, 10)
        end
        "#,
    );
    let engine = Engine::load(directory.path(), 32, 24).expect("load runtime");
    engine.update_and_draw(1.0 / 60.0).expect("draw frame");
    let frame = engine.frame_rgba();
    let pixel = ((4 * 32 + 4) * 4) as usize;
    assert_eq!(&frame[pixel..pixel + 4], &[255, 0, 0, 255]);

    engine
        .key_pressed("return", false)
        .expect("dispatch return");
    assert!(engine.should_quit());
    assert_eq!(engine.take_quit_code(), Some(42));
}

#[test]
fn update_can_poll_background_work_without_redrawing() {
    let directory = game(
        r#"
        updates = 0
        draws = 0
        function love.update() updates = updates + 1 end
        function love.draw()
            draws = draws + 1
            love.graphics.rectangle("fill", 1, 1, 2, 2)
        end
        "#,
    );
    let engine = Engine::load(directory.path(), 16, 16).expect("load runtime");
    engine.update(0.05).expect("poll first update");
    engine.update(0.05).expect("poll second update");
    let before_draw = engine.frame_rgba();
    engine.draw().expect("draw frame");
    let (updates, draws): (u32, u32) = engine
        .runtime
        .lua
        .load("return updates, draws")
        .eval()
        .expect("read callback counts");
    assert_eq!((updates, draws), (2, 1));
    assert!(before_draw.iter().all(|value| *value == 0));
    assert!(engine.frame_rgba().iter().any(|value| *value != 0));
}

#[test]
fn print_and_printf_draw_visible_text() {
    let directory = game(
        r#"
        function love.draw()
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.print("PRINT", 4, 4)
            love.graphics.printf("CENTER", 4, 24, 80, "center")
        end
        "#,
    );
    let engine = Engine::load(directory.path(), 96, 48).expect("load runtime");
    engine.update_and_draw(1.0 / 60.0).expect("draw text");
    let frame = engine.frame_rgba();

    let has_text_pixel = |top: usize, bottom: usize| {
        (top..bottom).any(|y| {
            (0..96).any(|x| {
                let pixel = (y * 96 + x) * 4;
                frame[pixel..pixel + 3] == [255, 255, 255]
            })
        })
    };
    assert!(has_text_pixel(4, 20), "love.graphics.print drew no text");
    assert!(has_text_pixel(24, 44), "love.graphics.printf drew no text");
}

#[test]
fn bitmap_font_metrics_match_rendered_cell_width() {
    let directory = game("");
    let engine = Engine::load(directory.path(), 96, 48).expect("load runtime");
    let width: f32 = engine
        .runtime
        .lua
        .load(
            r#"
            local font = love.graphics.newFont(20)
            return font:getWidth("ABCDE")
            "#,
        )
        .eval()
        .expect("measure bitmap font");
    assert_eq!(width, 100.0);
}

#[test]
fn repeated_text_draws_reuse_rasterized_images() {
    let directory = game(
        r#"
        function love.draw()
            love.graphics.print("stable label", 4, 4)
            love.graphics.printf("stable wrapped label", 4, 24, 80, "left")
        end
        "#,
    );
    let engine = Engine::load(directory.path(), 96, 64).expect("load runtime");
    engine.update_and_draw(1.0 / 60.0).expect("first draw");
    let after_first = *engine.runtime.state.next_image_id.lock();
    engine.update_and_draw(1.0 / 60.0).expect("second draw");
    let after_second = *engine.runtime.state.next_image_id.lock();
    assert_eq!(after_second, after_first, "text was rasterized twice");
}

#[test]
fn loads_the_real_launcher_uikit() {
    let directory = tempfile::tempdir().expect("temporary UIKit directory");
    fs::write(
        directory.path().join("kit.lua"),
        include_str!("../../../_kit/love/kit.lua"),
    )
    .expect("write kit.lua");
    fs::write(
        directory.path().join("launcher.lua"),
        include_str!("../../../_kit/love/launcher.lua"),
    )
    .expect("write launcher.lua");
    fs::write(
        directory.path().join("main.lua"),
        r#"
        local launcher = require("launcher")
        launcher.define {
            id = "love-lite-contract",
            title = {en = "LOVE-lite", zh = "LOVE-lite"},
            fields = {
                launcher.toggle {
                    key = "enabled",
                    label = {en = "Enabled", zh = "启用"},
                    env = "LOVE_LITE_ENABLED",
                },
            },
        }
        "#,
    )
    .expect("write main.lua");

    let engine = Engine::load(directory.path(), 480, 360).expect("load real UIKit");
    engine.update_and_draw(1.0 / 60.0).expect("draw real UIKit");
    assert!(engine.frame_rgba().iter().any(|value| *value != 0));
    engine.key_pressed("down", false).expect("move UIKit focus");
    engine
        .key_pressed("return", false)
        .expect("activate UIKit item");
}

#[test]
fn loads_the_real_app_manager_lua_frontend_at_supported_viewports() {
    let directory = tempfile::tempdir().expect("temporary App Manager directory");
    fs::write(
        directory.path().join("kit.lua"),
        include_str!("../../../_kit/love/kit.lua"),
    )
    .expect("write kit.lua");
    let source =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/love");
    for entry in fs::read_dir(source).expect("read App Manager Lua directory") {
        let entry = entry.expect("read App Manager Lua entry");
        if entry.path().extension().and_then(|value| value.to_str()) == Some("lua") {
            fs::copy(entry.path(), directory.path().join(entry.file_name()))
                .expect("copy App Manager Lua module");
        }
    }

    for (width, height, expected_scale) in
        [(640, 480, 0.80f32), (960, 720, 1.0f32), (1028, 720, 1.0f32)]
    {
        let engine = Engine::load_with_lua_setup(directory.path(), width, height, |lua| {
            let api = lua.create_table()?;
            api.set("snapshot", lua.create_function(|lua, ()| lua.create_string(
                br#"{"env":{"portmaster_health":"missing","portmaster_management":"app","device_class":"unknown-path","target_confirmed":"0","capability_install_portmaster":false,"capability_update_portmaster":false,"capability_repair_runtimes":false,"pending_install":"","install_transaction":"","portmaster_active":"","operation_active":"","size_file":""},"inventory":null}"#
            ))?)?;
            api.set("start", lua.create_function(|_, (_kind, _payload): (String, String)| {
                Err::<u64, _>(mlua::Error::external("offline test fixture"))
            })?)?;
            api.set("poll", lua.create_function(|_, ()| Ok(None::<String>))?)?;
            api.set("cancel", lua.create_function(|_, ()| Ok(()))?)?;
            lua.globals().set("appmanager", api)?;
            Ok(())
        })
            .unwrap_or_else(|error| panic!("load App Manager at {width}x{height}: {error:#}"));
        engine
            .update_and_draw(1.0 / 60.0)
            .unwrap_or_else(|error| panic!("draw App Manager at {width}x{height}: {error:#}"));
        assert!(
            engine.frame_rgba().iter().any(|value| *value != 0),
            "App Manager rendered an empty {width}x{height} frame"
        );
        let scale: f32 = engine
            .runtime
            .lua
            .load("return require('kit').debug_layout().cs")
            .eval()
            .expect("read responsive layout scale");
        assert!(
            (scale - expected_scale).abs() < 0.001,
            "unexpected layout scale {scale} at {width}x{height}"
        );
        let commands = engine
            .draw_gpu()
            .expect("record App Manager GPU frame")
            .expect("App Manager frame uses the supported GPU subset");
        assert!(
            commands.len() > 10,
            "App Manager GPU frame is unexpectedly empty at {width}x{height}"
        );
    }
}
