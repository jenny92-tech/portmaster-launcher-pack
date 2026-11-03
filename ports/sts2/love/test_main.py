#!/usr/bin/env python3
# INPUT:  STS2 main.lua, shared LÖVE launcher/kit, Lupa and mocked device capabilities
# OUTPUT: isolated checks for backend availability, saved state, page layout and launch environment
# POS:    STS2 frontend contract regression without device or game files
import ast
from pathlib import Path
import tempfile
import unittest

try:
    from lupa import LuaRuntime
except ImportError:
    LuaRuntime = None

ROOT = Path(__file__).resolve().parents[3]
MAIN = ROOT / 'ports/sts2/love/main.lua'
SHARED_TEST = ROOT / 'tests/test_love_lua_modules.py'
tree = ast.parse(SHARED_TEST.read_text(encoding='utf-8'))
MOCK = next(ast.literal_eval(node.value) for node in tree.body
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'mock' for t in node.targets))


@unittest.skipUnless(LuaRuntime, 'lupa unavailable')
class Sts2LauncherUiTest(unittest.TestCase):
    def make_ui(self, source, vulkan, gles, saved, swaps=('off', 'on'),
                initial_language=None, initial_quality=None, composition_available=None, composition=None, preferred=None):
        if saved is not None:
            state = f'ui_lang=zh\nlanguage=en_US\nquality=quality\nswap_ab={swaps[0]}\nswap_xy={swaps[1]}\n'
            if saved != '__missing__':
                state += 'graphics_api=' + saved + '\nperf_overlay=on\ndiagnostics=on\n'
            if composition is not None:
                state += 'weston_composition=' + composition + '\n'
            (source / 'state.txt').write_text(state, encoding='utf-8')
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().SOURCE = str(source)
        lua.execute(MOCK)
        lua.globals().VK = vulkan
        lua.globals().GLES = gles
        lua.globals().INITIAL_LANGUAGE = initial_language
        lua.globals().INITIAL_QUALITY = initial_quality
        lua.globals().COMPOSITION_AVAILABLE = composition_available
        lua.globals().PREFERRED = preferred
        lua.execute('''
            os.getenv=function(key)
                if key == "SLL_VULKAN_AVAILABLE" then return VK end
                if key == "SLL_GLES_AVAILABLE" then return GLES end
                if key == "SLL_INITIAL_LANGUAGE" then return INITIAL_LANGUAGE end
                if key == "SLL_INITIAL_QUALITY" then return INITIAL_QUALITY end
                if key == "SLL_WESTON_COMPOSITION_AVAILABLE" then return COMPOSITION_AVAILABLE end
                if key == "SLL_GRAPHICS_PREFERRED" then return PREFERRED end
                return nil
            end
        ''')
        lua.execute(f"package.path={str(ROOT / '_kit/love/?.lua')!r}..';'..package.path")
        lua.execute('''
            local k=require('kit')
            PAGES={}
            local add=k.add_page
            k.add_page=function(title,rows,...)
                PAGES[#PAGES+1]=rows
                return add(title,rows,...)
            end
            local run=k.run
            k.run=function(port) PORT=port; return run(port) end
        ''')
        lua.execute(f'dofile({str(MAIN)!r}); love.load()')
        return lua

    def test_initial_game_settings_and_existing_state_priority(self):
        for lang, quality, saved, expected in [
            ('en_US', 'smooth', None, ('en_US', 'smooth')),
            ('zh_CN', 'quality', None, ('zh_CN', 'quality')),
            ('zh_CN', 'balanced', None, ('zh_CN', 'balanced')),
            ('bad', 'bad', None, ('zh_CN', 'balanced')),
            ('zh_CN', 'smooth', 'vulkan', ('en_US', 'quality')),
        ]:
            with self.subTest(lang=lang, quality=quality, saved=saved), tempfile.TemporaryDirectory() as tmp:
                lua = self.make_ui(Path(tmp), '1', '0', saved,
                                   initial_language=lang, initial_quality=quality)
                state = lua.eval("require('kit').get_state()")
                self.assertEqual((state.language, state.quality), expected)
                lua.execute("love.keypressed('return')")
                self.assertEqual(lua.globals().LAST_QUIT, 42)
                env = (Path(tmp) / 'launch_config.env').read_text(encoding='utf-8')
                self.assertIn(f"SLL_LANGUAGE='{expected[0]}'", env)
                self.assertIn(f"SLL_QUALITY='{expected[1]}'", env)

    def test_picker_skips_unavailable_backend(self):
        for vk, gl, expected in [('1', '0', 'auto'), ('1', '1', 'auto')]:
            with self.subTest(vk=vk, gl=gl), tempfile.TemporaryDirectory() as tmp:
                lua = self.make_ui(Path(tmp), vk, gl, None)
                lua.globals().EXPECTED_API = expected
                lua.execute('''
                    local k=require('kit')
                    k.goto_page(2)
                    local index
                    for i,row in ipairs(PAGES[2]) do if row.key=='graphics_api' then index=i end end
                    for _=1,20 do
                        local current=k.debug_focus().focus_i
                        if current==index then break end
                        k.input(current>index and 'up' or 'down')
                    end
                    assert(k.debug_focus().focus_i==index)
                    assert(PAGES[2][index].dropdown)
                    k.input('confirm'); assert(k.debug_dialog().select)
                    k.input('down'); k.input('up')
                    assert(k.debug_dialog().selected_value==EXPECTED_API)
                    k.input('confirm'); assert(k.get_state().graphics_api==EXPECTED_API)
                ''')
    def test_backend_options_state_and_env(self):
        for vk, gl, saved, expected in [
            ('1', '1', None, 'gles'), ('1', '1', 'gles', 'gles'),
            ('1', '1', 'vulkan', 'vulkan'), ('1', '0', 'gles', None),
            ('0', '1', 'vulkan', None), ('0', '1', 'invalid', 'gles'),
            ('1', '1', '__missing__', 'gles'), ('0', '1', '__missing__', 'gles'),
            ('true', '01', 'gles', None), (None, None, None, None),
        ]:
            with self.subTest(vk=vk, gl=gl, saved=saved), tempfile.TemporaryDirectory() as tmp:
                source = Path(tmp)
                lua = self.make_ui(source, vk, gl, saved)
                lua.globals().EXPECT_VK = vk == '1'
                lua.globals().EXPECT_GLES = gl == '1'
                lua.execute('''
                    local k=require('kit')
                    local rows={}
                    for _,row in ipairs(PAGES[1]) do if row.key then rows[row.key]=row end end
                    assert(rows.language and rows.quality and not rows.graphics_api)
                    local advanced={}
                    for _,row in ipairs(PAGES[2]) do if row.key then advanced[row.key]=row end end
                    assert(advanced.swap_ab and advanced.swap_xy and advanced.weston_composition and advanced.perf_overlay and advanced.diagnostics)
                    assert(advanced.graphics_api.disabled_values.vulkan == not EXPECT_VK)
                    assert(advanced.graphics_api.disabled_values.gles == not EXPECT_GLES)
                    assert(#advanced.graphics_api.values==3)
                    assert(PORT.strings[advanced.graphics_api.labels.gles].zh=='SDL2（OpenGL）')
                    assert(PORT.strings[advanced.graphics_api.labels.vulkan].zh=='Vulkan')
                    assert(not rows.perf_overlay and not rows.diagnostics)
                ''')
                state = lua.eval("require('kit').get_state()")
                if saved is not None:
                    self.assertEqual((state.language, state.quality, state.swap_ab, state.swap_xy),
                                     ('en_US', 'quality', 'off', 'on'))
                else:
                    self.assertEqual((state.language, state.quality, state.swap_ab, state.swap_xy),
                                     ('zh_CN', 'balanced', 'on', 'off'))
                    self.assertEqual((state.perf_overlay, state.diagnostics), ('off', 'off'))
                if expected is None:
                    self.assertEqual(state.graphics_api, saved if saved in ('gles', 'vulkan') else 'auto')
                    lua.execute("OUT={value='',write=function(self,s) self.value=self.value..s; return true end}; OK=PORT.write_env(OUT,require('kit').get_state(),require('kit'))")
                    self.assertFalse(lua.globals().OK)
                    self.assertEqual(lua.globals().OUT.value, '')
                    lua.execute("love.keypressed('return')")
                    self.assertNotEqual(lua.globals().LAST_QUIT, 42)
                    self.assertFalse((source / 'launch_config.env').exists())
                else:
                    selected = saved if saved in ('gles', 'vulkan') else 'auto'
                    self.assertEqual(state.graphics_api, selected)
                    lua.execute("love.keypressed('return')")
                    self.assertEqual(lua.globals().LAST_QUIT, 42)
                    env = (source / 'launch_config.env').read_text(encoding='utf-8')
                    self.assertIn(f"SLL_GRAPHICS_API='{expected}'", env)
                    self.assertIn('graphics_api=' + selected, (source / 'state.txt').read_text(encoding='utf-8'))
                    switch = 'on' if saved not in (None, '__missing__') else 'off'
                    self.assertIn(f"SLL_PERF_OVERLAY='{switch}'", env)
                    self.assertIn(f"SLL_DIAGNOSTICS='{switch}'", env)
                    self.assertNotIn('SLL_UI_CONTROL', env)
                    self.assertNotIn('SLL_UI_DIAG', env)
                    self.assertNotIn('SLL_TEXTURE_DIAG', env)
                    unavailable_values = ['bogus'] + ([] if gl == '1' else ['gles']) + ([] if vk == '1' else ['vulkan'])
                    for unavailable in unavailable_values:
                        lua.globals().UNAVAILABLE = unavailable
                        lua.execute("local s=require('kit').get_state(); s.graphics_api=UNAVAILABLE; OUT={value='',write=function(self,s) self.value=self.value..s; return true end}; OK=PORT.write_env(OUT,s,require('kit'))")
                        self.assertFalse(lua.globals().OK)
                        self.assertEqual(lua.globals().OUT.value, '')

    def test_auto_uses_available_device_preference_without_overwriting_selection(self):
        cases = [('1', '1', 'vulkan', 'vulkan'), ('1', '1', 'gles', 'gles'),
                 ('1', '1', 'bad', 'gles'), ('1', '0', 'gles', 'vulkan'),
                 ('0', '1', 'vulkan', 'gles'), ('0', '0', 'vulkan', None)]
        for vk, gl, preferred, expected in cases:
            with self.subTest(vk=vk, gl=gl, preferred=preferred), tempfile.TemporaryDirectory() as tmp:
                source = Path(tmp)
                lua = self.make_ui(source, vk, gl, 'auto', preferred=preferred)
                self.assertEqual(lua.eval("require('kit').get_state().graphics_api"), 'auto')
                lua.execute("love.keypressed('return')")
                if expected is None:
                    self.assertNotEqual(lua.globals().LAST_QUIT, 42)
                    self.assertFalse((source / 'launch_config.env').exists())
                    continue
                self.assertEqual(lua.globals().LAST_QUIT, 42)
                self.assertIn(f"SLL_GRAPHICS_API='{expected}'", (source / 'launch_config.env').read_text())
                self.assertIn('graphics_api=auto', (source / 'state.txt').read_text())
                reloaded = self.make_ui(source, vk, gl, None, preferred=preferred)
                self.assertEqual(reloaded.eval("require('kit').get_state().graphics_api"), 'auto')

    def test_switching_backend_refreshes_composition_without_losing_preference(self):
        with tempfile.TemporaryDirectory() as tmp:
            lua = self.make_ui(Path(tmp), '1', '1', 'vulkan',
                               composition_available='1', composition='on')
            lua.execute('''
                local k=require('kit')
                local composition
                for _,row in ipairs(PAGES[2]) do
                    if row.key=='weston_composition' then composition=row end
                end
                assert(not composition.disabled)
                k.goto_page(2)
                for _=1,20 do
                    if PAGES[2][k.debug_focus().focus_i].key=='graphics_api' then break end
                    k.input('up')
                end
                assert(PAGES[2][k.debug_focus().focus_i].key=='graphics_api')
                k.input('confirm'); k.input('up'); k.input('confirm')
                assert(k.get_state().graphics_api=='gles')
                assert(composition.disabled and k.get_state().weston_composition=='on')
                local out={value='',write=function(self,s) self.value=self.value..s; return true end}
                assert(PORT.write_env(out,k.get_state(),k))
                assert(out.value:find("SLL_GRAPHICS_API='gles'",1,true))
                assert(out.value:find("SLL_WESTON_COMPOSITION='off'",1,true))
                k.input('confirm'); k.input('down'); k.input('confirm')
                assert(k.get_state().graphics_api=='vulkan' and not composition.disabled)
                assert(k.get_state().weston_composition=='on')
                out.value=''
                assert(PORT.write_env(out,k.get_state(),k))
                assert(out.value:find("SLL_WESTON_COMPOSITION='on'",1,true))
            ''')

    def test_composition_picker_saves_and_exports_each_choice(self):
        for value, steps in [('on', 0), ('off', 1)]:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp:
                source = Path(tmp)
                lua = self.make_ui(source, '1', '0', None, composition_available='1')
                lua.globals().STEPS = steps
                lua.globals().EXPECTED = value
                lua.execute('''
                    local k=require('kit')
                    local index, row
                    for i,r in ipairs(PAGES[2]) do
                        if r.key=='weston_composition' then index=i; row=r end
                    end
                    assert(row and not row.disabled)
                    assert(PORT.strings[row.label].zh=='强制合成:')
                    assert(k.get_state().weston_composition=='on')
                    for _,value in ipairs(row.values or {}) do assert(value=='on' or value=='off') end
                    k.goto_page(2)
                    for _=1,20 do
                        local current=k.debug_focus().focus_i
                        if current==index then break end
                        k.input(current>index and 'up' or 'down')
                    end
                    assert(k.debug_focus().focus_i==index)
                    for _=1,STEPS do k.input('left') end
                    assert(k.get_state().weston_composition==EXPECTED)
                    k.goto_page(1); k.input('confirm')
                ''')
                self.assertEqual(lua.globals().LAST_QUIT, 42)
                self.assertIn(f'weston_composition={value}', (source / 'state.txt').read_text(encoding='utf-8'))
                self.assertIn(f"SLL_WESTON_COMPOSITION='{value}'", (source / 'launch_config.env').read_text(encoding='utf-8'))
                reloaded = self.make_ui(source, '1', '0', None, composition_available='1')
                self.assertEqual(reloaded.eval("require('kit').get_state().weston_composition"), value)

    def test_composition_unavailable_exports_off_and_preserves_preference(self):
        for capability in [None, '0', 'true']:
            for preference in ['on', 'off']:
                with self.subTest(capability=capability, preference=preference), tempfile.TemporaryDirectory() as tmp:
                    source = Path(tmp)
                    lua = self.make_ui(source, '1', '0', 'vulkan', composition_available=capability,
                                       composition=preference)
                    lua.globals().EXPECTED = preference
                    lua.execute('''
                        local k=require('kit')
                        local row
                        for _,r in ipairs(PAGES[2]) do if r.key=='weston_composition' then row=r end end
                        assert(row and row.disabled)
                        assert(k.get_state().weston_composition==EXPECTED)
                        local out={value='',write=function(self,s) self.value=self.value..s; return true end}
                        assert(PORT.write_env(out,k.get_state(),k))
                        assert(out.value:find("SLL_WESTON_COMPOSITION='off'",1,true))
                        k.input('confirm')
                    ''')
                    self.assertEqual(lua.globals().LAST_QUIT, 42)
                    self.assertIn(f'weston_composition={preference}', (source / 'state.txt').read_text(encoding='utf-8'))
                    self.assertIn("SLL_WESTON_COMPOSITION='off'", (source / 'launch_config.env').read_text(encoding='utf-8'))
                    reloaded = self.make_ui(source, '1', '0', None, composition_available='1')
                    self.assertEqual(reloaded.eval("require('kit').get_state().weston_composition"), preference)

    def test_removed_composition_auto_uses_existing_default_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)
            lua = self.make_ui(source, '1', '0', 'vulkan',
                               composition_available='1', composition='auto')
            self.assertEqual(lua.eval("require('kit').get_state().weston_composition"), 'on')
            lua.execute("love.keypressed('return')")
            self.assertEqual(lua.globals().LAST_QUIT, 42)
            self.assertIn('weston_composition=on', (source / 'state.txt').read_text())
            self.assertIn("SLL_WESTON_COMPOSITION='on'", (source / 'launch_config.env').read_text())

    def test_button_swap_disabled_and_preserves_saved_choice(self):
        with tempfile.TemporaryDirectory() as tmp:
            lua = self.make_ui(Path(tmp), '1', '1', 'gles', swaps=('on', 'on'))
            lua.execute('''
                local k=require('kit')
                local state=k.get_state()
                local rows={}
                for _,row in ipairs(PAGES[2]) do if row.key then rows[row.key]=row end end
                assert(state.graphics_api=='gles')
                assert(state.swap_ab=='on' and state.swap_xy=='on')
                assert(rows.swap_ab.disabled and rows.swap_xy.disabled)
                assert(PORT.strings[rows.swap_ab.label].zh:find('暂不支持',1,true))
                assert(PORT.strings[rows.swap_xy.label].zh:find('暂不支持',1,true))
                local out={value='',write=function(self,s) self.value=self.value..s; return true end}
                assert(PORT.write_env(out,state,k))
                assert(out.value:find("SLL_SWAP_AB='off'",1,true))
                assert(out.value:find("SLL_SWAP_XY='off'",1,true))
            ''')


if __name__ == '__main__':
    unittest.main()
