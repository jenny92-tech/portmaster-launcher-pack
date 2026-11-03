// INPUT:  Engine/GpuCommand、mlua、临时 Lua 程序及仓库真实 UIKit/APP 前端资源
// OUTPUT: 绘制、字体、事件调度、任务桥接和真实页面的运行时契约测试
// POS:    验证 LOVE-lite 子集满足 APP Manager 实际前端需求
use std::fs;

use love_lite::{Engine, GpuCommand};
use mlua::{String as LuaString, Table as LuaTable};
use tempfile::TempDir;

#[test]
fn calibration_overlay_draws_all_steps_and_routes_buttons() {
    let directory = game("function love.draw() normal_drawn=true end");
    stage_shared_ui(directory.path());
    let engine = Engine::load(directory.path(), 640, 480).unwrap();
    let font = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/portable/share/NotoSansSC-Regular.ttf");
    engine.runtime.lua.globals().set("preview_font", font.to_string_lossy().as_ref()).unwrap();
    let source = include_str!("../../../ports/appmanager/love/app_input.lua");
    let module: LuaTable = engine.runtime.lua.load(source).eval().unwrap();
    engine.runtime.lua.globals().set("input_ui", module).unwrap();
    engine.runtime.lua.load(r#"
        status={active=false, step=0, elapsed=0}
        input_ui.install({input_status=function() return status end,
            input_command=function(c) command=c end},
            {font=function(px) return love.graphics.newFont(preview_font,math.max(9,math.floor(px*1.08+0.5))) end})
    "#).exec().unwrap();
    engine.draw().unwrap();
    assert!(engine.runtime.lua.globals().get::<bool>("normal_drawn").unwrap());
    let font = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/portable/share/NotoSansSC-Regular.ttf");
    engine.runtime.lua.globals().set("preview_font", font.to_string_lossy().as_ref()).unwrap();
    engine.runtime.lua.load("love.graphics.setFont(love.graphics.newFont(preview_font,16))").exec().unwrap();
    assert!(!source.contains("Tab") && !source.contains("Esc") && !source.contains("Enter"));
    for step in 0..=13 {
        engine.runtime.lua.load(format!("status={{active=true,step={step},elapsed=0.5}} normal_drawn=false")).exec().unwrap();
        engine.draw().unwrap();
        if step==5 {
            let pixels=engine.frame_rgba();
            for (index,(dx,dy)) in [(-165.,-40.),(-165.,40.),(-205.,0.),(-125.,0.),(205.,0.),(165.,40.),(165.,-40.),(125.,0.)].iter().enumerate() {
                let (x,y,scale):(f64,f64,f64)=engine.runtime.lua.load("local g=input_ui._geometry; return g.controller_x,g.controller_y,g.controller_scale").eval().unwrap();
                let cx=(x+dx*scale).floor()+0.5;
                let cy=(y+dy*scale).floor()+0.5;
                let mut ink=Vec::new();
                for y in (cy as usize-11)..=(cy as usize+11) {
                    for x in (cx as usize-11)..=(cx as usize+11) {
                        let p=&pixels[(y*640+x)*4..][..3];
                        if p.iter().all(|v| *v>200) { ink.push((x,y)); }
                    }
                }
                assert!(!ink.is_empty(),"button {index} has no legend");
                let ink_x=(ink.iter().map(|p|p.0).min().unwrap()+ink.iter().map(|p|p.0).max().unwrap()) as f64/2.0+0.5;
                let ink_y=(ink.iter().map(|p|p.1).min().unwrap()+ink.iter().map(|p|p.1).max().unwrap()) as f64/2.0+0.5;
                assert!((ink_x-cx).abs()<=1.0 && (ink_y-cy).abs()<=1.0,"button {index}: ink ({ink_x},{ink_y}), center ({cx},{cy})");
            }
            if let Some(path)=std::env::var_os("PAM_CALIBRATION_PREVIEW_PPM") {
                let mut ppm=b"P6\n640 480\n255\n".to_vec();
                for pixel in engine.frame_rgba().chunks_exact(4) { ppm.extend_from_slice(&pixel[..3]); }
                fs::write(path,ppm).unwrap();
            }
        }
        assert!(!engine.runtime.lua.globals().get::<bool>("normal_drawn").unwrap());
    }
    engine.runtime.lua.load("local y=input_ui._geometry.hint_y+1; love.calibrationClick(250,y); assert(command==4); love.calibrationClick(400,y); assert(command==2)").exec().unwrap();
}

fn game(main: &str) -> TempDir {
    let directory = tempfile::tempdir().expect("temporary game directory");
    fs::write(directory.path().join("main.lua"), main).expect("write main.lua");
    directory
}

fn stage_shared_ui(directory: &std::path::Path) {
    let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../_kit/stage_love_ui.sh");
    let status = std::process::Command::new("bash")
        .arg(script)
        .arg(directory)
        .status()
        .expect("stage actual shared UI payload");
    assert!(status.success(), "shared UI payload staging failed");
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
fn lua_can_request_event_driven_redraws_and_wake_intervals() {
    let directory = game(
        r#"
        dirty = true
        wake = nil
        function love.needsRedraw() return dirty end
        function love.takeDirty()
            local value = dirty
            dirty = false
            return value
        end
        function love.wakeInterval() return wake end
        "#,
    );
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    assert!(engine.needs_redraw().expect("read dirty flag"));
    assert!(engine.take_dirty().expect("consume dirty flag"));
    assert!(!engine.needs_redraw().expect("dirty flag cleared"));
    assert!(!engine.take_dirty().expect("second take is clean"));
    assert_eq!(engine.wake_interval().expect("idle wake"), None);
    engine
        .runtime
        .lua
        .load("wake = 0.1")
        .exec()
        .expect("set wake interval");
    assert_eq!(engine.wake_interval().expect("task wake"), Some(0.1));
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
            love.graphics.circle("fill", 40, 20, 8)
            love.graphics.ellipse("line", 70, 24, 12, 7)
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
            .any(|command| matches!(command, GpuCommand::Ellipse { fill: true, .. }))
    );
    assert!(
        commands
            .iter()
            .any(|command| matches!(command, GpuCommand::Ellipse { fill: false, .. }))
    );
    assert!(
        commands
            .iter()
            .any(|command| matches!(command, GpuCommand::Image { .. }))
    );
}

#[test]
fn rotated_circle_rejects_the_gpu_frame() {
    let directory = game(
        r#"
        function love.draw()
            love.graphics.translate(40, 30)
            love.graphics.rotate(0.4)
            love.graphics.circle("fill", 0, 0, 10)
        end
        "#,
    );
    let engine = Engine::load(directory.path(), 96, 72).expect("load runtime");
    assert!(
        engine.draw_gpu().expect("record GPU frame").is_none(),
        "rotated circles must fall back to the CPU renderer"
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
fn app_small_viewports_keep_modal_controls_and_guide_targets_visible() {
    let directory = game(r#"
        local k=require('kit')
        local nav={}
        for i=1,6 do nav[i]=k.button('Section '..i,function() end,
            {id='nav:'..i,active=i==1,select_on_focus=true}) end
        nav[7]=k.button('Exit',function() end,{id='nav:quit',group='bottom'})
        k.run({state={ui_lang='en'},theme={kind='app'},build_pages=function()
            k.add_page('Home',{k.button('PortMaster',function() end,{detail='Ready to use'}),
                k.checkbox('I understand this device has not been tested',{id='risk:modify'})},
                {root=true,navigation=true,sidebar=nav,row_layout={mode='flow',max_columns=1}})
            k.add_page('Details',{k.button('Item',function() end)},
                {navigation=true,sidebar=nav,row_layout={mode='flow',max_columns=1}})
        end})
    "#);
    stage_shared_ui(directory.path());
    let root=std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    fs::copy(root.join("ports/appmanager/portable/share/NotoSansSC-Regular.ttf"),directory.path().join("font.ttf")).unwrap();
    fs::copy(root.join("ports/appmanager/love/app_input.lua"),directory.path().join("app_input.lua")).unwrap();
    for (width,height) in [(320,240),(480,320),(640,480),(1280,720)] {
        let engine=Engine::load(directory.path(),width,height).unwrap();
        engine.runtime.lua.load(r#"
            local k=require('kit')
            local layout=k.debug_layout(); local row=layout.geometry[2]
            local font=k.font(22*layout.cs)
            local _,lines=font:getWrap('I understand this device has not been tested',row.w-88*layout.cs)
            assert(#lines*font:getHeight()<=row.h-20*layout.cs+0.01)
            k.password_dialog({title='Archive password',message='Enter the password for the encrypted game archive. ',on_confirm=function() end})
        "#).exec().unwrap();
        engine.draw().unwrap();
        engine.runtime.lua.load(r#"
            local k=require('kit'); local g=k.debug_password_dialog().geometry
            assert(g.key_h>=12 and g.grid_bottom<g.action_y)
            assert(g.action_bottom<g.hint_y and g.hint_y<g.bottom)
            k.close_password_dialog()
            k.dialog({title='Some Runtimes were not repaired',
                message='Repaired 1 Runtime. Failed items:',items={'godot_4.5.squashfs: download failed. Check the network connection.'},scroll_items=true})
        "#).exec().unwrap();
        engine.draw().unwrap();
        engine.runtime.lua.load(r#"
            local k=require('kit'); local g=k.debug_dialog().geometry
            assert(g.content_y>g.title_bottom and g.content_y<g.action_y)
            k.close_dialog()
            k.set_busy(true,'Repairing Runtimes…',{stage='Downloading…',detail='godot_4.5.squashfs',
                footer_left='52.0 MiB / 125.0 MiB',footer_right='2.0 MiB/s',on_cancel=function() end})
        "#).exec().unwrap();
        engine.draw().unwrap();
        engine.runtime.lua.load(r#"
            local k=require('kit'); local g=k.debug_busy().geometry
            local _,height=love.graphics.getDimensions()
            assert(g.top>=0 and g.bottom<=height and g.cancel_y>g.metrics_bottom)
            k.set_busy(false)
            -- Page builders can open a guide immediately before pushing their child page.
            k.guide({callouts={{target='nav:6',title='Settings',body='Choose a function.'}}})
            k.push_page(2)
        "#).exec().unwrap();
        engine.draw().unwrap();
        engine.runtime.lua.load(r#"
            local k=require('kit'); local target=k.debug_guide().target_rect
            local side=k.debug_sidebar_geometry()
            assert(target and math.abs(target.y-side.y6)<0.01 and math.abs(target.h-side.h6)<0.01)
            if k.debug_layout().compact then
                assert(k.debug_focus().zone=='sidebar' and k.debug_focus().sidebar_i==6)
                assert(target.y>=side.viewport_top and target.y+target.h<=side.viewport_bottom+0.01)
            end
            k.close_guide()
            -- Overlays own their clip, including controls outside the page body.
            local set_scissor,printf=love.graphics.setScissor,love.graphics.printf
            local clipped,body_y,saw_count,saw_button
            love.graphics.setScissor=function(x,y,w,h)
                clipped=x~=nil;return set_scissor(x,y,w,h)
            end
            love.graphics.printf=function(value,x,y,...)
                if value=='1 / 1' then
                    assert(not clipped,'guide counter must not inherit the page clip');saw_count=true
                elseif value=='Done' then
                    assert(not clipped,'guide action must not inherit the page clip');saw_button=true
                elseif tostring(value):find('Complete feedback',1,true) then body_y=y end
                return printf(value,x,y,...)
            end
            k.guide({confirm='Done',callouts={{target='nav:6',title='Feedback',
                body='Complete feedback '..string.rep('/roms/ports/long-feedback-folder ',30)}}})
            love.draw()
            assert(saw_count and saw_button and body_y)
            assert(k.wake_interval() and k.wake_interval()<0.1,'overflowing guide text keeps scrolling')
            local first_y=body_y;k.update(3);love.draw()
            assert(body_y<first_y,'complete guide text pans into view')
            love.graphics.setScissor=set_scissor;love.graphics.printf=printf
            k.close_guide()
            assert(k.debug_page().index==2 and k.debug_focus().zone=='rows')
            k.input('cancel'); assert(k.debug_page().index==1)
            input_ui=require('app_input')
            input_ui.install({input_status=function() return {active=true,step=5,can_cancel=true,
                message='未收到可用的新按键，请松开所有按键后重试，或检查控制器连接。'} end},k)
        "#).exec().unwrap();
        engine.draw().unwrap();
        engine.runtime.lua.load(r#"
            local g=input_ui._geometry; local _,height=love.graphics.getDimensions()
            assert(g.controller_scale>=0.38 and g.graphic_bottom>g.graphic_top)
            assert(g.controller_y-127*g.controller_scale>=g.graphic_top)
            assert(g.controller_y+102*g.controller_scale<=g.graphic_bottom+0.01)
            assert(g.footer_bottom<height)
        "#).exec().unwrap();
    }
}

#[test]
fn remote_page_keeps_the_complete_pairing_url_with_real_font() {
    let directory = tempfile::tempdir().unwrap();
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    for entry in fs::read_dir(root.join("ports/appmanager/love")).unwrap() {
        let entry = entry.unwrap();
        if entry.path().extension().and_then(|value| value.to_str()) == Some("lua") {
            fs::copy(entry.path(), directory.path().join(entry.file_name())).unwrap();
        }
    }
    stage_shared_ui(directory.path());
    fs::copy(root.join("ports/appmanager/portable/share/NotoSansSC-Regular.ttf"), directory.path().join("font.ttf")).unwrap();
    for language in ["zh", "en"] {
        for (width,height) in [(320,240),(480,320),(640,480),(720,720),(480,640),(960,720),(1280,720)] {
            fs::write(directory.path().join("state.txt"),format!("ui_lang={language}\nonboarding_seen=1\nweb_enabled=1\n")).unwrap();
            let engine=Engine::load_with_lua_setup(directory.path(),width,height,|lua| {
                lua.load(r#"
            local snapshot={
                env={web_url="http://192.168.255.255",portmaster_health="healthy",portmaster_management="app",
                    capability_inventory_ports=true,capability_manage_ports=true,capability_install_ports=true,
                    capability_trash=true,capability_leftovers=true,capability_repair_runtimes=true,
                    capability_update_portmaster=false},
                inventory={ports={{script="Game.sh",path="/roms/ports/Game.sh"}},data_refcount={},
                    orphan_dirs={},orphan_images={},dead_scripts={},trash={},runtimes={need={},facts={}}},
                revision=string.rep("a",64),sizes={},runtime_metadata={}}
            local initial=false
            appmanager={request=function(method,payload)
                if method=="start" and payload.kind=="initial-snapshot" then
                    initial=true; return {ok=true,value=1}
                elseif method=="start" then return {ok=false,error={code="offline",message="fixture"}}
                elseif method=="poll" then
                    if not initial then return {ok=true} end
                    initial=false
                    return {ok=true,value={task_id=1,kind="initial-snapshot",status="complete",data={snapshot=snapshot}}}
                elseif method=="web-set" then
                    remote_start_calls=(remote_start_calls or 0)+1
                    assert(payload==true)
                    return {ok=true,value={port=65535,code="012345"}}
                end
                error("unexpected native request: "..method)
            end}
            local value="http://192.168.255.255:65535/012345"
            local original=love.graphics.printf
            local original_print=love.graphics.print
            local original_rectangle=love.graphics.rectangle
            local set_scissor=love.graphics.setScissor
            local set_font=love.graphics.setFont
            local clip,font
            love.graphics.setScissor=function(...)
                local x,y,w,h=...
                clip=x and {x=x,y=y,w=w,h=h} or nil
                set_scissor(...)
            end
            love.graphics.setFont=function(f) font=f; set_font(f) end
            local left_right,right_left,footer_bottom
            love.graphics.rectangle=function(mode,x,y,w,h,...)
                -- Observe the top-row panels before the title is drawn.
                if mode=="fill" and y>0 and h>y*2 and h<y*4 then
                    local width=love.graphics.getDimensions()
                    if x<width/2 then left_right=x+w else right_left=x end
                end
                original_rectangle(mode,x,y,w,h,...)
            end
            love.graphics.print=function(text,x,y)
                if text:match("^http://") then
                    banner_metrics="address width "..font:getWidth(text)..", available "..clip.w
                end
                original_print(text,x,y)
            end
            love.graphics.printf=function(text,x,y,w,align)
                if text:match("^开发:") or text:match("^Developer:") or text:match("^QQ") then
                    local _,lines=font:getWrap(text,w)
                    assert(not footer_bottom or y>=footer_bottom-0.51,"sidebar footer lines overlap")
                    footer_bottom=y+#lines*font:getHeight()
                end
                if text=="远程管理" or text=="Remote management" or text=="Remote" then
                    title_seen=true
                    local width=love.graphics.getDimensions()
                    assert(x>=0 and x+font:getWidth(text)<=width,"title leaves the screen")
                    assert(not right_left or x+font:getWidth(text)<=right_left+1.51,"title overlaps language control")
                end
                if text==value then
                    banner_seen=true
                    assert(clip and clip.h>=font:getHeight()-0.01,"pairing URL must fit vertically")
                    local width,height=love.graphics.getDimensions()
                    assert(clip.x>=0 and clip.x+clip.w<=width and clip.y>=0 and clip.y+clip.h<=height,
                        "banner must stay inside the display")
                    assert(y>=clip.y-0.51 and y+font:getHeight()<=clip.y+clip.h+0.51,"banner must not pan or clip")
                    for line in (text.."\n"):gmatch("(.-)\n") do
                        assert(font:getWidth(line)<=clip.w,"each explicit line must fit horizontally")
                    end
                end
                original(text,x,y,w,align)
            end
        "#).exec()?;
                Ok(())
            }).unwrap();
            engine.update_and_draw(0.2).unwrap_or_else(|error| panic!("{language} {width}x{height}: {error:#}"));
            engine.runtime.lua.load(r#"
                local k=require('kit')
                local width=love.graphics.getDimensions()
                assert(k.get_state().web_enabled=='0' and not remote_start_calls)
                k.input('left')
                for _=1,16 do
                    local p=k.debug_page()
                    local label=p.sidebar_labels[k.debug_focus().sidebar_i]
                    if label=='远程管理' or label=='Remote' then break end
                    k.input('down')
                end
                k.input('confirm')
                assert(k.debug_page().index==10)
                assert(k.get_state().web_enabled=='0' and not remote_start_calls)
                k.input('confirm')
                assert(remote_start_calls==1 and k.get_state().web_enabled=='1')
                assert(k.debug_page().row_kinds[2]=='qrcode')
                k.input('down')
                k.input('down')
            "#).exec().unwrap();
            engine.draw().unwrap();
            if let Some(path)=std::env::var_os("PAM_REMOTE_PREVIEW_DIR") {
                let mut ppm=format!("P6\n{width} {height}\n255\n").into_bytes();
                for pixel in engine.frame_rgba().chunks_exact(4) { ppm.extend_from_slice(&pixel[..3]); }
                fs::write(std::path::Path::new(&path).join(format!("remote-{language}-{width}x{height}.ppm")),ppm).unwrap();
            }
            engine.runtime.lua.load("assert(title_seen,'page title was not drawn'); assert(banner_seen,banner_metrics or 'address was not drawn'); assert(require('kit').wake_interval()==nil,'idle remote page must not animate')").exec().unwrap_or_else(|error| panic!("{language} {width}x{height}: {error}"));
        }
    }
}

#[test]
fn grouped_uninstall_dialog_scrolls_all_paths_and_keeps_safe_actions_visible() {
    let directory = game(r#"
        local k=require('kit')
        review_groups,review_expected={},{}
        for i=1,8 do
            local paths={'/roms/ports/Game'..i..'.sh','/roms/ports/images/Game'..i..'.png',
                '/roms/ports/游戏目录'..i..'/'}
            if i==4 then paths[3]='/roms/ports/'..string.rep('很长的目录VeryLongFolder/',20)..'SaveData/' end
            review_groups[i]={title='游戏 '..i,items=paths}
            for _,path in ipairs(paths) do review_expected[path]=true end
        end
        function open_group_review()
            k.dialog({title={zh='卸载所选项目',en='Uninstall selected items'},
                message={zh='将永久删除以下内容（目录含全部文件），无法还原。',
                    en='These files and folders will be deleted permanently. Folders include all their contents.'},
                item_groups=review_groups,danger=true,
                confirm={zh='确认卸载',en='Uninstall'},cancel={zh='取消',en='Cancel'},
                on_confirm=function() review_confirmed=true end,
                on_cancel=function() review_cancelled=true end})
        end
        k.run({state={ui_lang=review_language},theme={kind='app'},
            build_pages=function() k.add_page('APP',{}) end,on_load=open_group_review})
        local printf,print,scissor=love.graphics.printf,love.graphics.print,love.graphics.setScissor
        local clip
        review_seen={}
        love.graphics.setScissor=function(x,y,w,h)
            clip=x and {y=y,w=w,h=h} or nil
            scissor(x,y,w,h)
        end
        local function record(text,x,y)
            local font=love.graphics.getFont()
            local width,height=love.graphics.getDimensions()
            if text=='取消' or text=='Cancel' or text=='确认卸载' or text=='Uninstall' then
                assert(not clip,'actions must be outside the scrolling clip')
                assert(y>=0 and y+font:getHeight()<=height and x>=0 and x+font:getWidth(text)<=width)
                review_actions_visible=true
            end
            local path=text:gsub('\n','')
            if clip and review_expected[path] then
                local seen=review_seen[path] or {lines={},count=0}
                local i=0
                for line in (text..'\n'):gmatch('(.-)\n') do
                    i=i+1
                    assert(font:getWidth(line)<=clip.w+0.51,'path must wrap within the dialog')
                    if y+(i-1)*font:getHeight()>=clip.y-0.51 and y+i*font:getHeight()<=clip.y+clip.h+0.51 then
                        seen.lines[i]=true
                    end
                end
                seen.count=i
                review_seen[path]=seen
            end
        end
        love.graphics.printf=function(text,x,y,...) record(text,x,y); printf(text,x,y,...) end
        love.graphics.print=function(text,x,y,...) record(text,x,y); print(text,x,y,...) end
    "#);
    stage_shared_ui(directory.path());
    fs::copy(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/portable/share/NotoSansSC-Regular.ttf"),directory.path().join("font.ttf")).unwrap();
    for language in ["zh","en"] {
        for (width,height) in [(320,240),(640,480),(1280,720)] {
            let engine=Engine::load_with_lua_setup(directory.path(),width,height,|lua| {
                lua.globals().set("review_language",language)?;
                Ok(())
            }).unwrap();
            let mut reached_end=false;
            for _ in 0..400 {
                engine.update_and_draw(0.0).unwrap();
                let at_end:bool=engine.runtime.lua.load(r#"
                    local d=require('kit').debug_dialog()
                    assert(d.focus=='cancel' and d.group_count==8 and d.max_scroll>0 and review_actions_visible)
                    return d.scroll_y>=d.max_scroll
                "#).eval().unwrap();
                if at_end { reached_end=true; break }
                engine.key_pressed("down",false).unwrap();
                engine.key_released("down").unwrap();
            }
            assert!(reached_end,"{language} {width}x{height}: review must reach its last item");
            engine.runtime.lua.load(r#"
                for path in pairs(review_expected) do
                    local seen=assert(review_seen[path],path)
                    for i=1,seen.count do assert(seen.lines[i],'unreadable path line '..i..': '..path) end
                end
                local k=require('kit')
                k.input('confirm')
                assert(review_cancelled and not review_confirmed and not k.debug_dialog().open)
                open_group_review()
                assert(k.debug_dialog().scroll_y==0 and k.debug_dialog().focus=='cancel')
                k.input('right'); k.input('confirm')
                assert(review_confirmed and not k.debug_dialog().open)
            "#).exec().unwrap_or_else(|error| panic!("{language} {width}x{height}: {error}"));
        }
    }
}

#[test]
fn uninstall_review_scrolls_every_complete_path_at_small_viewports() {
    let directory = game(r#"
        local k=require("kit")
        review_paths={}
        for i=1,12 do review_paths[i]="/roms/ports/游戏目录/VeryLongFolderName_"..i.."/Game.sh" end
        review_paths[6]="/roms/ports/"..string.rep("VeryLongFolderName/",30).."Game.sh"
        function open_review()
            k.dialog({title={zh="卸载所选项目",en="Uninstall selected items"},
                message={zh="以下文件和目录将永久删除，目录包含全部内容，无法还原。",
                    en="These files and folders will be deleted permanently, including all folder contents."},
                items=review_paths,scroll_items=true,danger=true,
                confirm={zh="确认卸载",en="Uninstall"},cancel={zh="取消",en="Cancel"},
                on_confirm=function() review_confirmed=true end,
                on_cancel=function() review_cancelled=true end})
        end
        k.run({state={ui_lang=review_language},theme={kind="app"},
            build_pages=function() k.add_page("APP",{}) end,on_load=open_review})
        local printf,print=love.graphics.printf,love.graphics.print
        local scissor=love.graphics.setScissor
        local clip
        love.graphics.setScissor=function(x,y,w,h)
            clip=x and {y=y,w=w,h=h} or nil
            scissor(x,y,w,h)
        end
        local function record(text,y)
            local path=k.debug_dialog().current_item
            local raw=text:gsub("\n","")
            if #raw>0 and path:find(raw,1,true) then
                review_drawn=(review_drawn or "")..raw
                local font=love.graphics.getFont()
                local _,lines=font:getWrap(path,clip.w)
                review_lines,review_visible_lines=#lines,clip.h/font:getHeight()
                assert(math.abs(review_visible_lines-math.floor(review_visible_lines+0.01))<0.01,
                    "deletion review must not clip a partial text line")
                review_text_y,review_clip_y=y,clip.y
            end
        end
        love.graphics.printf=function(text,x,y,...) record(text,y); printf(text,x,y,...) end
        love.graphics.print=function(text,x,y,...) record(text,y); print(text,x,y,...) end
    "#);
    stage_shared_ui(directory.path());
    fs::copy(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/portable/share/NotoSansSC-Regular.ttf"),directory.path().join("font.ttf")).unwrap();
    for language in ["zh","en"] {
        for (width,height) in [(320,240),(640,480)] {
            let engine=Engine::load_with_lua_setup(directory.path(),width,height,|lua| {
                lua.globals().set("review_language",language)?;
                Ok(())
            }).unwrap();
            for index in 1..=12 {
                engine.runtime.lua.load("review_drawn=''").exec().unwrap();
                engine.update_and_draw(0.2).unwrap();
                engine.runtime.lua.load(format!(
                    "local d=require('kit').debug_dialog(); assert(d.item_index=={index} and d.focus=='cancel'); assert(d.current_item==review_paths[{index}]); assert(review_drawn==d.current_item,review_drawn)"
                )).exec().unwrap();
                if index==6 {
                    assert!(engine.wake_interval().unwrap().is_some(),"long paths must keep scrolling while the dialog is open");
                    engine.update_and_draw(3.0).unwrap();
                    engine.runtime.lua.load("assert(review_text_y<review_clip_y,'overflow must actually scroll through the path')").exec().unwrap();
                } else {
                    engine.runtime.lua.load("assert(review_lines<=review_visible_lines+0.01,string.format('path lines %d, visible %.1f',review_lines,review_visible_lines))").exec()
                        .unwrap_or_else(|error| panic!("{language} {width}x{height} path {index}: {error}"));
                }
                if (index==1 || index==12) && let Some(path)=std::env::var_os("PAM_UNINSTALL_PREVIEW_DIR") {
                    let mut ppm=format!("P6\n{width} {height}\n255\n").into_bytes();
                    for pixel in engine.frame_rgba().chunks_exact(4) { ppm.extend_from_slice(&pixel[..3]); }
                    fs::write(std::path::Path::new(&path).join(format!("uninstall-{language}-{width}x{height}-{index}.ppm")),ppm).unwrap();
                }
                engine.key_pressed("down",false).unwrap();
                engine.key_released("down").unwrap();
            }
            engine.runtime.lua.load(r#"
                local k=require("kit")
                k.input("confirm")
                assert(review_cancelled and not review_confirmed and not k.debug_dialog().open)
                open_review()
                assert(k.debug_dialog().item_index==1 and k.debug_dialog().focus=="cancel")
                k.input("right"); k.input("confirm")
                assert(review_confirmed and not k.debug_dialog().open)
            "#).exec().unwrap();
        }
    }
}

#[test]
fn loads_the_real_launcher_uikit() {
    let directory = tempfile::tempdir().expect("temporary UIKit directory");
    stage_shared_ui(directory.path());
    fs::write(directory.path().join("graphics.lua"), include_str!("../../../_kit/love/graphics.lua")).unwrap();
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
fn urgent_dialog_can_recover_a_busy_native_task() {
    let directory = tempfile::tempdir().expect("temporary UIKit directory");
    stage_shared_ui(directory.path());
    fs::write(
        directory.path().join("main.lua"),
        r#"
        local kit=require("kit")
        confirmed=false
        kit.run({
            theme={kind="app"},
            state={},
            build_pages=function(k)
                k.add_page("Task",{k.textview("Status","Working",{focusable=false})})
            end,
            on_load=function(k)
                k.set_busy(true,"Working")
                k.dialog({
                    title="Connection interrupted",
                    message="Retry",
                    confirm="Retry",
                    cancel="Return",
                    over_busy=true,
                    on_confirm=function() confirmed=true end,
                })
            end,
        })
        "#,
    )
    .expect("write main.lua");

    let engine = Engine::load(directory.path(), 640, 480).expect("load real UIKit");
    engine
        .update_and_draw(1.0 / 60.0)
        .expect("draw busy dialog");
    engine
        .key_pressed("right", false)
        .expect("focus dialog confirmation");
    engine
        .key_pressed("return", false)
        .expect("confirm busy dialog");
    let (confirmed, busy): (bool, bool) = engine
        .runtime
        .lua
        .load("return confirmed, require('kit').debug_busy().busy")
        .eval()
        .expect("read dialog result");
    assert!(confirmed, "the urgent dialog must receive input over busy");
    assert!(
        busy,
        "recovering the bridge must not unlock the native task"
    );
}

#[test]
fn loads_the_real_app_manager_lua_frontend_at_supported_viewports() {
    let directory = tempfile::tempdir().expect("temporary App Manager directory");
    stage_shared_ui(directory.path());
    let source =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/love");
    for entry in fs::read_dir(source).expect("read App Manager Lua directory") {
        let entry = entry.expect("read App Manager Lua entry");
        if entry.path().extension().and_then(|value| value.to_str()) == Some("lua") {
            fs::copy(entry.path(), directory.path().join(entry.file_name()))
                .expect("copy App Manager Lua module");
        }
    }
    // Skip the first-run guide: it is drawn with stencil operations that are
    // intentionally outside the supported GPU command subset, and this test
    // verifies page rendering, not the onboarding overlay.
    fs::write(
        directory.path().join("state.txt"),
        "ui_lang=zh\nonboarding_seen=1\n",
    )
    .expect("write App Manager state");

    for (width, height, expected_scale) in
        [(640, 480, 0.80f32), (960, 720, 1.0f32), (1028, 720, 1.0f32)]
    {
        let engine = Engine::load_with_lua_setup(directory.path(), width, height, |lua| {
            let api = lua.create_table()?;
            api.set(
                "request",
                lua.create_function(|lua, (method, payload): (String, Option<mlua::Value>)| {
                    let response = lua.create_table()?;
                    response.set("ok", true)?;
                    match method.as_str() {
                        "snapshot" => {
                            let value = lua
                                .load(
                                    r#"return {
                                        env={
                                            portmaster_health="missing",
                                            portmaster_management="app",
                                            device_class="unknown-path",
                                            target_confirmed="0",
                                            capability_install_portmaster=false,
                                            capability_update_portmaster=false,
                                            capability_repair_runtimes=false,
                                            pending_install_exists=false,
                                            install_transaction_exists=false,
                                            portmaster_active_exists=false,
                                            operation_active_exists=false
                                        },
                                        inventory=nil,
                                        runtime_metadata={}
                                    }"#,
                                )
                                .eval::<mlua::Table>()?;
                            response.set("value", value)?;
                        }
                        "start" => {
                            assert!(matches!(payload, Some(mlua::Value::Table(_))));
                            response.set("value", 1u64)?;
                        }
                        // A malformed native value must be caught by app_native.
                        // main.lua must keep the task blocked and retry instead
                        // of pretending a native mutation has completed.
                        "poll" => response.set(
                            "value",
                            mlua::Value::LightUserData(mlua::LightUserData(std::ptr::null_mut())),
                        )?,
                        "cancel" => response.set("value", true)?,
                        _ => panic!("unexpected bridge method {method}"),
                    }
                    Ok(response)
                })?,
            )?;
            lua.globals().set("appmanager", api)?;
            Ok(())
        })
        .unwrap_or_else(|error| panic!("load App Manager at {width}x{height}: {error:#}"));
        engine
            .update_and_draw(0.2)
            .unwrap_or_else(|error| panic!("draw App Manager at {width}x{height}: {error:#}"));
        let busy: bool = engine
            .runtime
            .lua
            .load("return require('kit').debug_busy().busy")
            .eval()
            .expect("read App Manager busy state");
        assert!(
            !busy,
            "the startup device-config refresh must stay off the foreground busy lane"
        );
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
            commands.iter().any(|command| matches!(command, GpuCommand::Image { .. })),
            "App Manager GPU frame has no rendered text at {width}x{height}"
        );
        assert!(
            commands.iter().any(|command| matches!(command, GpuCommand::Rectangle { .. })),
            "App Manager GPU frame has no UI surfaces at {width}x{height}"
        );
    }
}

#[test]
fn runtime_repair_completion_rebuilds_overviews_and_runtime_page() {
    let lua = mlua::Lua::new();
    let app_lua =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/love");
    lua.globals()
        .set("APP_LUA", app_lua.to_string_lossy().as_ref())
        .expect("publish App Manager Lua directory");
    lua.load(
        r#"
        package.path=APP_LUA.."/?.lua;"..package.path
        local calls={home=0,storage=0,system=0,runtime=0,goto_page=0}
        local kit={
            set_busy=function() end,
            toast=function() end,
            goto_page=function(page) calls.goto_page=page end,
        }
        local native={}
        local model=require("app_model").new(kit,native)
        local function snapshot(health)
            return {
                env={libs_dir="/libs"},
                inventory={
                    ports={{script="Game.sh",dir="Game",data_path="/data/Game",images={}}},
                    data_refcount={["/data/Game"]=1},orphan_dirs={},orphan_images={},dead_scripts={},trash={},
                    runtimes={
                        need={godot_4_6_3={"Game.sh"}},
                        facts={{name="godot_4_6_3",health=health,bytes=health=="healthy" and 4096 or 0}},
                    },
                },
                runtime_metadata={},
            }
        end
        assert(model.apply_snapshot(snapshot("missing")))
        assert(model.missing_runtime("Game.sh")=="godot_4_6_3")

        local operations=require("app_operations").new(model)
        operations.bind({
            reset_selection=function() end,
            build_home=function() calls.home=calls.home+1 end,
            build_storage=function() calls.storage=calls.storage+1 end,
            build_system=function() calls.system=calls.system+1 end,
            build_runtime=function() calls.runtime=calls.runtime+1 end,
        },{})
        operations.confirm_return=model.pages.RUNTIME
        operations.task={
            kind="operation",
            plan={{kind="INSTALL_RUNTIME",arg="godot_4_6_3"}},
        }
        operations.finish_task({
            status="complete",
            data={snapshot=snapshot("healthy"),operation={failed=false}},
        })

        assert(model.missing_runtime("Game.sh")=="")
        assert(calls.home==1,"Runtime repair must rebuild the cached Home page")
        assert(calls.storage==1 and calls.system==1,"Returning to an overview must show the current snapshot")
        assert(calls.runtime==1,"Runtime repair must rebuild its current page")
        assert(calls.goto_page==model.pages.RUNTIME)

        operations.task={
            kind="operation",
            plan={{kind="INSTALL_RUNTIME",arg="godot_4_6_3"}},
        }
        operations.finish_task({status="error",data={}})
        assert(#model.ensure_report().ports==1,
            "A failed task without a replacement snapshot must keep the last usable inventory")
        "#,
    )
    .exec()
    .expect("exercise Runtime completion page refresh");
}

#[test]
fn background_update_result_survives_a_concurrent_foreground_snapshot() {
    let lua = mlua::Lua::new();
    let app_lua =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/love");
    lua.globals()
        .set("APP_LUA", app_lua.to_string_lossy().as_ref())
        .expect("publish App Manager Lua directory");
    lua.load(
        r#"
        package.path=APP_LUA.."/?.lua;"..package.path
        local calls={home=0,storage=0,system=0}
        local kit={
            set_busy=function() end,
            toast=function() end,
            goto_page=function() end,
        }
        local model=require("app_model").new(kit,{})
        local function snapshot()
            return {
                env={update_checked=0,update_status="unknown",portmaster_latest=""},
                inventory={ports={},data_refcount={},orphan_dirs={},orphan_images={},dead_scripts={},
                    trash={},runtimes={need={},facts={}}},
                runtime_metadata={},
            }
        end
        assert(model.apply_snapshot(snapshot()))

        local operations=require("app_operations").new(model)
        operations.bind({
            reset_selection=function() end,
            build_home=function() calls.home=calls.home+1 end,
            build_storage=function() calls.storage=calls.storage+1 end,
            build_system=function() calls.system=calls.system+1 end,
        },{build_manage=function() end})
        operations.task={kind="operation",plan={}}
        operations.accept_background_update({
            update_checked=123,update_status="ok",portmaster_latest="2026.07",
        })
        assert(model.env.update_status=="unknown")
        operations.finish_task({
            status="complete",
            data={snapshot=snapshot(),operation={failed=false}},
        })
        assert(model.env.update_checked==123)
        assert(model.env.update_status=="ok")
        assert(model.env.portmaster_latest=="2026.07")
        assert(calls.home==1 and calls.storage==1 and calls.system==1)
        "#,
    )
    .exec()
    .expect("merge background update after foreground snapshot");
}

#[test]
fn manual_update_wait_does_not_reserve_the_foreground_lane() {
    let lua = mlua::Lua::new();
    let app_lua =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/love");
    lua.globals()
        .set("APP_LUA", app_lua.to_string_lossy().as_ref())
        .expect("publish App Manager Lua directory");
    lua.load(
        r#"
        package.path=APP_LUA.."/?.lua;"..package.path
        local starts={}
        local kit={
            toast=function() end,
            button=function() end,
            textview=function() end,
            set_busy=function() end,
            goto_page=function() end,
        }
        local native={
            start=function(kind)
                starts[#starts+1]=kind
                return 99
            end,
        }
        local model=require("app_model").new(kit,native)
        model.env={
            portmaster_management="app",
            target_confirmed="1",
            portmaster_target="/mnt/PortMaster",
            capability_manage_portmaster=true,
            capability_install_portmaster=true,
            capability_update_portmaster=true,
            portmaster_release_install_allowed=true,
            update_status="unknown",
        }
        local operations=require("app_operations").new(model)
        local environment=require("app_environment").new(model,operations,{set_page=kit.set_page})
        operations.bind({build_home=function() end,build_storage=function() end,build_system=function() end},environment)
        operations.background_task={id=7,kind="update-check-background"}

        environment.start_update_check()
        assert(operations.task==nil)
        assert(operations.background_task.id==7)
        assert(operations.forced_update_pending==true)
        assert(#starts==0)
        model.inventory_revision=string.rep("a",64)
        operations.confirm_plan={{kind="CLEAN_APPLEDOUBLE",arg=""}}
        operations.confirm_revision=model.inventory_revision
        operations.start_apply()
        assert(#starts==1 and starts[1]=="apply")

        operations.finish_background_update({
            update_checked=1,update_status="ok",portmaster_latest="cached",
        })
        assert(#starts==1)
        operations.task=nil
        operations.try_start_forced_update()
        assert(#starts==2 and starts[2]=="update-check")
        assert(operations.task.id==99 and operations.task.kind=="update-check")
        assert(operations.forced_update_pending==false)
        assert(model.env.portmaster_latest=="")
        "#,
    )
    .exec()
    .expect("defer a manual forced check until the automatic check exits");
}

#[test]
fn leftover_cleanup_keeps_shared_launcher_selection_bound_to_exact_script() {
    let lua = mlua::Lua::new();
    let app_lua =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ports/appmanager/love");
    lua.globals()
        .set("APP_LUA", app_lua.to_string_lossy().as_ref())
        .expect("publish App Manager Lua directory");
    lua.load(
        r#"
        package.path=APP_LUA.."/?.lua;"..package.path

        local captured=nil
        local kit={_junk_rows={}}
        function kit.get_state()
            return {ui_lang="en",onboarding_seen="1",onboarding_games="1",
                onboarding_launcher="1",onboarding_junk="1",onboarding_runtime="1",
                onboarding_pm="1"}
        end
        function kit.checkbox(label,opts)
            opts.kind="checkbox"; opts.label=label
            opts.on_toggle=opts.on_toggle or opts.on_change
            return opts
        end
        function kit.textview(label,value,opts)
            opts=opts or {}; opts.kind="textview"; opts.label=label; opts.value=value
            return opts
        end
        function kit.empty(value,opts)
            opts=opts or {}; opts.kind="empty"; opts.value=value
            return opts
        end
        function kit.section(label,opts)
            opts=opts or {}; opts.kind="section"; opts.label=label
            return opts
        end
        function kit.button(label,action,opts)
            opts=opts or {}; opts.kind="button"; opts.label=label; opts.action=action
            return opts
        end
        function kit.set_page(_,_,rows,opts)
            kit._junk_rows=rows
            kit.sidebar=opts.sidebar
        end
        function kit.back_page() end
        function kit.badge(text) return {text=text} end

        local report={
            ports={
                {script="A_Game.sh",path="/scripts/A_Game.sh",dir="Shared",data_path="/data/Shared",images={}},
                {script="B_Game.sh",path="/scripts/B_Game.sh",dir="Shared",data_path="/data/Shared",images={}},
            },
            data_refcount={["/data/Shared"]=2},orphan_dirs={},orphan_images={},dead_scripts={},
        }
        local model={
            kit=kit,
            L=function(en,zh) return {en=en,zh=zh} end,
            support_label=function() return {en="Supported",zh="支持"} end,
            env={
                scripts_dir="/scripts",gamedirs_dir="/data",
                capability_cleanup_appledouble=false,
            },
            report=report,pages={HOME=1,JUNK=2,TRASH=3,ENV=4,RUNTIME=5,MANAGE=6},
            ensure_report=function() return report end,
            display_name=function(name)
                return (name:gsub("%.[^.]+$",""):gsub("^[A-Z]_",""))
            end,
            join=function(parts) return table.concat(parts," · ") end,
            selected_count=function(values)
                local count=0
                for _,value in pairs(values) do if value then count=count+1 end end
                return count
            end,
            dynamic_count=function(_,_,values)
                return function()
                    local count=0
                    for _,value in pairs(values) do if value then count=count+1 end end
                    return tostring(count)
                end
            end,
            missing_runtime=function() return "" end,
            human=function() return "0 B" end,
            runtime_issue_count=function() return 0 end,
            update_state=function() return "unknown" end,
            trash_items=function() return {} end,
        }
        local operations={
            show_confirm=function(_,plan,labels)
                captured={plan=plan,labels=labels}
            end,
            refresh_inventory=function() end,
        }
        local pages=require("app_pages").new(model,operations,{set_page=kit.set_page})
        pages.build_junk()

        local first,second
        for _,row in ipairs(kit._junk_rows) do
            if row.kind=="checkbox" and row.meta and row.meta.path=="/scripts/A_Game.sh" then first=row end
            if row.kind=="checkbox" and row.meta and row.meta.path=="/scripts/B_Game.sh" then second=row end
        end
        assert(first and second,"both shared launchers must be individually selectable")
        assert(first.label=="A_Game.sh" and second.label=="B_Game.sh",
            "shared launchers must show their exact filenames")

        second.on_toggle(true,second.meta,second)
        kit.sidebar[1].action()
        assert(captured and #captured.plan==1)
        assert(captured.plan[1].arg=="/scripts/B_Game.sh",
            "the selected launcher path must be the path sent to Rust")

        -- If a refreshed inventory removes the selected item, preserving page
        -- focus must not preserve a now-invisible destructive action.
        captured=nil
        report.ports={
            {script="A_Game.sh",path="/scripts/A_Game.sh",dir="Shared",data_path="/data/Shared",images={}},
        }
        report.data_refcount={["/data/Shared"]=1}
        pages.build_junk(true)
        assert(#kit.sidebar==1,"only the back action remains on an empty cleanup page")
        assert(captured==nil,
            "an item no longer present on the page must not remain in the delete plan")

        -- A display name without an authoritative inventory path must fail
        -- closed. Never reconstruct a destructive path from root + name.
        report.ports={}
        report.data_refcount={}
        report.entries={}
        report.orphan_dirs={{name="Unverified",path=""}}
        captured=nil
        pages.build_junk()
        assert(#kit.sidebar==1,"unverified items expose no cleanup/selection actions")
        assert(captured==nil,
            "an unverified orphan name must not produce a destructive action")

        -- A verified orphan keeps the exact path supplied by the Rust
        -- inventory even when its display name suggests another root.
        report.entries={{
            root="game-dirs",name="Verified",path="/wrong/name-search-result",
        }}
        report.orphan_dirs={{
            root="game-dirs",name="Verified",path="/authoritative/Verified",
        }}
        captured=nil
        pages.build_junk()
        kit.sidebar[2].action() -- Select all.
        kit.sidebar[1].action()
        assert(captured and #captured.plan==1)
        assert(captured.plan[1].arg=="/authoritative/Verified")
        assert(captured.plan[1].arg~="/data/Verified",
            "orphan cleanup must use the inventory path, not root + display name")

        -- The Home page uses friendly names normally. If two launcher
        -- filenames collapse to the same friendly name, show the exact names
        -- and keep uninstall bound to the selected inventory path.
        report.ports={
            {script="A_Game.sh",path="/scripts/A_Game.sh",dir="Shared",
                data_path="/authoritative/Shared",images={}},
            {script="B_Game.sh",path="/scripts/B_Game.sh",dir="Shared",
                data_path="/authoritative/Shared",images={}},
        }
        report.data_refcount={["/authoritative/Shared"]=2}
        report.orphan_dirs={}
        model.env.capability_manage_ports=true
        model.env.capability_trash=true
        model.env.capability_leftovers=false
        model.env.capability_repair_runtimes=false
        model.env.portmaster_management="app"
        pages.bind_environment({build_manage=function() end})
        captured=nil
        pages.build_games()
        first,second=nil,nil
        for _,row in ipairs(kit._junk_rows) do
            if row.kind=="checkbox" and row.id=="home:/scripts/A_Game.sh" then first=row end
            if row.kind=="checkbox" and row.id=="home:/scripts/B_Game.sh" then second=row end
        end
        assert(first and second)
        assert(first.label=="A_Game.sh" and second.label=="B_Game.sh",
            "colliding friendly names must be disambiguated")
        second.on_toggle(true,second.meta,second)
        kit.sidebar[1].action()
        assert(captured and #captured.plan==1)
        assert(captured.plan[1].arg=="/scripts/B_Game.sh",
            "Home uninstall must use the selected inventory path")

        captured=nil
        first.on_toggle(true,first.meta,first)
        kit.sidebar[1].action()
        assert(captured and #captured.plan==3)
        local saw_data=false
        for _,action in ipairs(captured.plan) do
            assert(action.arg~="/data/Shared",
                "Home uninstall must never reconstruct a data path from its display name")
            if action.arg=="/authoritative/Shared" then saw_data=true end
        end
        assert(saw_data,"Home uninstall must use the authoritative inventory data path")
        "#,
    )
    .exec()
    .expect("exercise exact shared launcher cleanup selection");
}
