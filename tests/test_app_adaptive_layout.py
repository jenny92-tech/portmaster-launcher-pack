#!/usr/bin/env python3
# INPUT:  Real Kit/LUIS/QR modules, Lua 5.1/5.4 and isolated drawing recorder
# OUTPUT: Shared page tools/forms, dialog actions, scrolling, navigation and QR assertions
# POS:    Adaptive handheld UI regression independent of native business operations
from pathlib import Path
import tempfile
import unittest

from test_luis_components import DRAW_MOCK, KIT, Lua51, Lua54

SETUP = r'''
love.filesystem={getInfo=function() return nil end,getSource=function() return SOURCE end}
love.event={quit=function() end}
love.graphics.getDimensions=function() return WIDTH,HEIGHT end
love.graphics.setBackgroundColor=function() end
love.graphics.newFont=function(px)
    return {getHeight=function() return px end,getWidth=function(_,v) return #tostring(v)*px*.5 end,
        getWrap=function(_,v) return 1,{tostring(v)} end}
end
love.graphics.setFont=function() end
love.graphics.print=function(v) painted[tostring(v)]=true end
love.graphics.printf=love.graphics.print
love.graphics.setScissor=function() end
love.graphics.polygon=function() end
love.graphics.push=function() end
love.graphics.pop=function() end
love.graphics.translate=function() end
painted={}
'''


class AdaptiveApp(unittest.TestCase):
    def test_shared_page_tools_fit_and_navigation_keeps_its_position(self):
        for runtime in (Lua51, Lua54):
            for width, height in ((320, 240), (480, 320), (640, 480), (1280, 720)):
                with self.subTest(lua=runtime.__module__, size=(width, height)), tempfile.TemporaryDirectory() as source:
                    lua = runtime(unpack_returned_tuples=True)
                    lua.globals().SOURCE = source
                    lua.globals().WIDTH, lua.globals().HEIGHT = width, height
                    lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
                    lua.execute(f"package.path={str(KIT.parent.parent / 'ports/appmanager/love/?.lua')!r}..';'..package.path")
                    lua.execute(DRAW_MOCK + SETUP)
                    lua.execute(r'''
                        local k=require('kit')
                        local model={kit=k,L=function(en,zh) return {en=en,zh=zh} end,
                            pages={HOME=1,ZIP=2,STORAGE=3,SYSTEM=4,REMOTE=5,SETTINGS=6,
                                GAMES=7,ITEM=8,JUNK=9,TRASH=10,MANAGE=11,RUNTIME=12,ENV=13,ABOUT=14,DEVICE=16}}
                        local shell=require('app_shell').new(model,{show_exit_dialog=function() end})
                        local count=0
                        local function build(index)
                            local rows={
                                k.button(function() return 'Repair ('..count..')' end,function() end,{id='repair',inline='tools'}),
                                k.button('Select all',function() end,{id='all',inline='tools'}),
                                k.button('Select none',function() end,{id='none',inline='tools'}),
                                k.button('Item',function() k.push_page(13) end,{id='item'}),
                            }
                            shell.set_page(index,'Page',rows)
                        end
                        k.run({state={ui_lang='en'},theme={kind='app'},build_pages=function()
                            build(1);build(2);build(6)
                            shell.set_page(13,'Details',{k.textview('Path','/roms/ports',{id='path'})})
                            k.goto_page(2)
                        end})
                        love.load();k.goto_page(2);love.draw()
                        local first=k.debug_sidebar_geometry()
                        local layout=k.debug_layout()
                        for i=1,3 do
                            local g=layout.geometry[i]
                            assert(g.fixed and g.x>=0 and g.x+g.w<=WIDTH+.01)
                            assert(g.y+g.h<=layout.geometry[4].y,'tools and content stay separate')
                        end
                        assert(painted['Repair (0)'] and painted['Select all'] and painted['Select none'],'tool labels stay complete')
                        k.input('confirm');assert(k.debug_page().index==13)
                        k.input('cancel');assert(k.debug_page().index==2)
                        assert(k.debug_page().row_ids[k.debug_focus().focus_i]=='item')
                        k.goto_page(6);love.draw()
                        local second=k.debug_sidebar_geometry()
                        assert(first.viewport_top==second.viewport_top and first.y7==second.y7,'page tools never move the main navigation')
                        count=12345;painted={};love.draw()
                        assert(painted['Repair (12345)'],'changing selection counts remeasures tool widths')
                    ''')

    def test_app_dialog_actions_and_single_acknowledgement(self):
        for runtime in (Lua51, Lua54):
            for width, height in ((320, 240), (640, 480), (1280, 720)):
                with self.subTest(lua=runtime.__module__, size=(width, height)), tempfile.TemporaryDirectory() as source:
                    lua = runtime(unpack_returned_tuples=True)
                    lua.globals().SOURCE = source
                    lua.globals().WIDTH, lua.globals().HEIGHT = width, height
                    lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
                    lua.execute(DRAW_MOCK + SETUP)
                    lua.execute(r'''
                        local k=require('kit')
                        k.run({state={ui_lang='en'},theme={kind='app'},build_pages=function()
                            k.add_page('Settings',{k.button('About',function() end,{id='about'})})
                        end})
                        love.load()
                        local confirmed,cancelled=0,0
                        for _,danger in ipairs({false,true}) do
                            k.dialog({title='Review',message='Continue?',danger=danger,
                                on_confirm=function() confirmed=confirmed+1 end,
                                on_cancel=function() cancelled=cancelled+1 end})
                            love.draw()
                            local d=k.debug_dialog();local g=d.geometry
                            assert(d.focus=='cancel' and g.cancel_x<g.confirm_x)
                            assert(g.action_y>g.content_y and g.action_bottom<=HEIGHT)
                            k.input('right');assert(k.debug_dialog().focus=='confirm')
                            k.input('left');assert(k.debug_dialog().focus=='cancel')
                            k.input('cancel');assert(cancelled==confirmed+1)
                            k.dialog({title='Review',on_confirm=function() confirmed=confirmed+1 end})
                            k.input('right');k.input('confirm');assert(confirmed==cancelled)
                        end
                        k.dialog({title='Result',confirm='OK',single_action=true,
                            on_confirm=function() confirmed=confirmed+1 end})
                        painted={};love.draw()
                        assert(k.debug_dialog().focus=='confirm' and painted.OK and not painted.Cancel)
                        k.input('left');k.input('down');assert(k.debug_dialog().focus=='confirm')
                        k.input('confirm');assert(confirmed==3 and not k.debug_dialog().open)
                        k.dialog({title='Result',single_action=true})
                        k.input('cancel');assert(not k.debug_dialog().open)
                        local replacement
                        k.dialog({title='Install',items={'First archive','Second archive'},scroll_items=true,
                            checkbox={label='Replace existing files'},on_confirm=function(_,checked) replacement=checked end})
                        love.draw();k.input('down');assert(k.debug_dialog().item_index==2)
                        k.input('down');assert(k.debug_dialog().focus=='checkbox','a scrolling list never traps focus above the option')
                        k.input('confirm');assert(k.debug_dialog().checkbox_checked)
                        k.input('down');assert(k.debug_dialog().focus=='cancel')
                        k.input('right');k.input('confirm');assert(replacement==true)
                        assert(k.debug_page().row_ids[k.debug_focus().focus_i]=='about')
                        k.get_state().swap_ab='1';painted={};love.draw()
                        assert(painted['A Confirm    B Back'] and not painted['B Confirm    A Back'])
                        k.dialog({title='Result',single_action=true});painted={};love.draw()
                        assert(painted['A Confirm    B Back'] and not painted['B Confirm    A Back'])
                        k.input('cancel')
                    ''')

    def test_button_correction_keeps_logical_labels_in_every_overlay(self):
        for runtime in (Lua51, Lua54):
            for width, height in ((320, 240), (1280, 720)):
                with self.subTest(lua=runtime.__module__, size=(width, height)), tempfile.TemporaryDirectory() as source:
                    lua = runtime(unpack_returned_tuples=True)
                    lua.globals().SOURCE = source
                    lua.globals().WIDTH, lua.globals().HEIGHT = width, height
                    lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
                    lua.execute(DRAW_MOCK + SETUP)
                    lua.execute(r'''
                        local k=require('kit')
                        k.run({state={ui_lang='en'},theme={kind='app'},build_pages=function()
                            k.add_page('Settings',{k.button('About',function() end,{id='about'})})
                        end})
                        love.load()
                        for _,lang in ipairs({'en','zh'}) do
                            local st=k.get_state();st.ui_lang=lang
                            local expected=lang=='zh' and 'A 确认    B 返回' or 'A Confirm    B Back'
                            local reversed=lang=='zh' and 'B 确认    A 返回' or 'B Confirm    A Back'
                            for _,ab in ipairs({'0','1'}) do
                                for _,xy in ipairs({'0','1'}) do
                                    st.swap_ab=ab;st.swap_xy=xy
                                    local function check_hint()
                                        painted={};love.draw()
                                        assert(painted[expected] and not painted[reversed],
                                            'button correction must not change logical A/B labels')
                                    end
                                    check_hint()
                                    k.dialog({title='Review'});check_hint();k.input('cancel')
                                    k.dialog({title='Uninstall',danger=true,
                                        item_groups={{title='Game',items={'/roms/ports/Game.sh'}}}})
                                    check_hint();k.input('cancel')
                                    k.password_dialog({on_confirm=function() end})
                                    painted={};love.draw()
                                    local password_hint=lang=='zh' and 'A 输入 · B 返回 · L1/R1 切换字符' or
                                        'A Type · B Back · L1/R1 Characters'
                                    assert(painted[password_hint],'password input follows the same logical labels')
                                    k.input('cancel')
                                end
                            end
                        end
                    ''')

    def test_library_toolbar_stays_visible_while_content_scrolls(self):
        for runtime in (Lua51, Lua54):
            for width, height in ((320, 240), (480, 320), (640, 480), (1280, 720)):
                with self.subTest(lua=runtime.__module__, size=(width, height)), tempfile.TemporaryDirectory() as source:
                    lua = runtime(unpack_returned_tuples=True)
                    lua.globals().SOURCE = source
                    lua.globals().WIDTH, lua.globals().HEIGHT = width, height
                    lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
                    lua.execute(DRAW_MOCK + SETUP)
                    lua.execute(r'''
                        local k=require('kit')
                        local loaded={}
                        love.graphics.newImage=function(path)
                            loaded[path]=true
                            return {getDimensions=function() return 64,64 end}
                        end
                        love.graphics.draw=function() end
                        local rows={
                            k.select('',{'all','game'},{all='All',game='Games'},'filter',{
                                id='filter',dropdown=true,surface=false,header_toolbar=true,toolbar_width=106}),
                            k.button('Refresh',function() end,{id='refresh',header_toolbar=true,toolbar_align='right',toolbar_width=84}),
                            k.button('Manage',function() end,{id='manage',header_toolbar=true,toolbar_align='right',toolbar_width=124}),
                        }
                        for i=1,20 do rows[#rows+1]=k.button('Game '..i,function() end,{
                            id='game:'..i,thumbnail='cover-'..i..'.png',library_item=true,default_focus=i==1}) end
                        k.run({state={ui_lang='en',filter='all'},theme={kind='app'},build_pages=function()
                            k.add_page('Installed',rows,{root=true,navigation=true,row_layout={mode='flow',max_columns=1},sidebar={
                                k.button('Installed',function() end,{active=true}),
                                k.button('Exit',function() k.dialog({title='Exit'}) end,{id='nav:quit',group='bottom'})}})
                        end})
                        love.load();love.draw()
                        local initial=k.debug_layout()
                        local toolbar_y=initial.geometry[1].y
                        for i=1,3 do
                            local g=initial.geometry[i]
                            assert(g.fixed and g.x>=0 and g.x+g.w<=WIDTH and g.y>=0)
                            assert(g.y+g.h<=initial.geometry[4].y,'toolbar must not overlap the first item')
                        end
                        if WIDTH==320 then
                            assert(initial.geometry[6].y+initial.geometry[6].h<=HEIGHT-27,'three readable rows fit on 320x240')
                        end
                        for i=1,19 do k.input('down') end
                        painted={}
                        love.draw()
                        local scrolled=k.debug_layout()
                        assert(k.debug_focus().focus_i==23 and scrolled.scroll_y>0)
                        assert(scrolled.geometry[1].y==toolbar_y,'list scrolling never moves the toolbar')
                        assert(not loaded['cover-10.png'],'scrolling to the end must not decode skipped covers')
                        assert(not painted['Game 1'] and painted['Game 20'],'offscreen items must not be painted behind fixed tools')
                        k.dialog({title='Uninstall',danger=true,item_groups={{title='Game',items={'/roms/ports/Game.sh'}}}})
                        love.draw()
                        local d=k.debug_dialog();local g=d.geometry
                        assert(d.focus=='cancel' and g.cancel_x<g.confirm_x)
                        assert(g.action_y>g.content_y and g.action_bottom<=HEIGHT)
                        if WIDTH<600 then assert(g.top==0 and g.bottom==HEIGHT,'small uninstall review uses the full screen') end
                        k.input('left');assert(k.debug_dialog().focus=='cancel')
                        k.input('right');assert(k.debug_dialog().focus=='confirm')
                        k.input('cancel');assert(not k.debug_dialog().open and k.debug_focus().focus_i==23)
                    ''')

    def test_dropdown_confirms_or_cancels_and_restores_focus(self):
        for runtime in (Lua51, Lua54):
            for width, height in ((320, 240), (640, 480), (1280, 720)):
                with self.subTest(lua=runtime.__module__, size=(width, height)), tempfile.TemporaryDirectory() as source:
                    lua = runtime(unpack_returned_tuples=True)
                    lua.globals().SOURCE = source
                    lua.globals().WIDTH, lua.globals().HEIGHT = width, height
                    lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
                    lua.execute(DRAW_MOCK + SETUP)
                    lua.execute(r'''
                        local k=require('kit')
                        local changes=0
                        local build
                        build=function()
                            k.set_page(1,'Installed',{
                                k.select('',{'all','game','app'},{all='All',game='Games',app='Apps'},'filter',{
                                    id='filter',dropdown=true,surface=false,inline='tools',inline_columns=3,height=44,
                                    on_change=function() changes=changes+1; build() end}),
                                k.button('Refresh',function() end,{inline='tools',inline_columns=3,height=44}),
                                k.button('Uninstall',function() end,{inline='tools',inline_columns=3,height=44}),
                            },{root=true,navigation=true,preserve_focus=true,
                                sidebar={k.button('Installed',function() end,{id='nav:library',active=true})},
                                row_layout={mode='flow',max_columns=1}})
                        end
                        k.run({state={ui_lang='en',filter='all'},theme={kind='app'},build_pages=build})
                        love.load(); love.draw()
                        local l=k.debug_layout()
                        assert(l.geometry[1].h==44*l.cs and l.geometry[1].y==l.geometry[3].y)
                        k.input('confirm'); love.draw()
                        local d=k.debug_dialog(); local g=d.geometry
                        assert(d.select and d.selected_value=='all')
                        assert(g.left>=0 and g.right<=WIDTH and g.top>=0 and g.bottom<=HEIGHT)
                        k.input('down'); assert(k.debug_dialog().selected_value=='game')
                        assert(k.get_state().filter=='all' and changes==0)
                        k.input('cancel'); assert(not k.debug_dialog().open)
                        assert(k.get_state().filter=='all' and k.debug_focus().focus_i==1)
                        k.input('confirm'); k.input('down'); k.input('down'); k.input('confirm')
                        assert(k.get_state().filter=='app' and changes==1 and not k.debug_dialog().open)
                        assert(k.debug_focus().zone=='rows' and k.debug_focus().focus_i==1)
                        k.input('right'); assert(k.debug_focus().focus_i==2)
                        k.input('left'); assert(k.debug_focus().focus_i==1 and k.get_state().filter=='app')
                        k.input('left'); assert(k.debug_focus().zone=='sidebar')
                    ''')

    def test_empty_messages_do_not_draw_icons_or_take_focus(self):
        for runtime in (Lua51, Lua54):
            for width, height in ((320, 240), (640, 480), (1280, 720)):
                with self.subTest(lua=runtime.__module__, size=(width, height)), tempfile.TemporaryDirectory() as source:
                    lua = runtime(unpack_returned_tuples=True)
                    lua.globals().SOURCE = source
                    lua.globals().WIDTH, lua.globals().HEIGHT = width, height
                    lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
                    lua.execute(DRAW_MOCK + SETUP)
                    lua.execute(r'''
                        local k=require('kit')
                        local activated=0
                        local empty=k.empty('Nothing to repair',{id='empty'})
                        assert(not empty.focusable)
                        local nav={k.button('Environment',function() end,{id='nav:system',icon='runtime',active=true})}
                        k.run({state={ui_lang='en'},theme={kind='app'},build_pages=function()
                            k.add_page('Actions',{
                                k.button('Before',function() activated=activated+1 end),empty,
                                k.button('After',function() activated=activated+1 end),
                            },{root=true,navigation=true,sidebar=nav,row_layout={mode='flow',max_columns=1}})
                            k.add_page('Empty',{k.empty('Nothing to repair')},
                                {navigation=true,sidebar=nav,row_layout={mode='flow',max_columns=1}})
                        end})
                        local icons=require('ui_icons')
                        local draw_icon=icons.draw
                        icons.draw=function(name,...)
                            assert(name~='games','empty messages must not draw a gamepad placeholder')
                            draw_icon(name,...)
                        end
                        love.load(); love.draw()
                        assert(painted['Nothing to repair'])
                        assert(k.debug_focus().zone=='rows' and k.debug_focus().focus_i==1)
                        k.input('confirm'); k.input('down')
                        assert(k.debug_focus().zone=='rows' and k.debug_focus().focus_i==3)
                        k.input('confirm'); assert(activated==2)
                        k.push_page(2); love.draw()
                        assert(k.debug_focus().zone=='sidebar','empty text must never receive focus')
                        k.input('right'); assert(k.debug_focus().zone=='sidebar')
                        k.input('cancel')
                        assert(k.debug_page().index==1 and k.debug_focus().focus_i==3)
                    ''')

    def test_function_navigation_and_inline_actions(self):
        for runtime in (Lua51, Lua54):
            for width, height in ((320, 240), (480, 320), (640, 480), (720, 720), (1280, 720)):
                with self.subTest(lua=runtime.__module__, size=(width, height)), tempfile.TemporaryDirectory() as source:
                    lua = runtime(unpack_returned_tuples=True)
                    lua.globals().SOURCE = source
                    lua.globals().WIDTH, lua.globals().HEIGHT = width, height
                    lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
                    lua.execute(DRAW_MOCK + SETUP)
                    lua.execute(r'''
                        local k=require('kit')
                        local names={'Installed','Install','Storage','Environment','Remote','Settings'}
                        local selections,exits=0,0
                        local function build(index)
                            local nav={}
                            for i,name in ipairs(names) do
                                local target=i
                                nav[i]=k.button(name,function() selections=selections+1; k.goto_page(target) end,
                                    {id='nav:'..i,active=i==index,icon='app',select_on_focus=true})
                            end
                            nav[#nav+1]=k.button('Exit',function() exits=exits+1; k.dialog({title='Exit'}) end,
                                {id='nav:quit',group='bottom'})
                            local rows={}
                            for i=1,3 do
                                rows[i]=k.button('Filter '..i,function() end,{id='filter:'..i,inline='filters',inline_columns=3,height=46})
                            end
                            rows[4]=k.button('Refresh',function() end,{inline='actions',height=46})
                            rows[5]=k.button('Manage',function() end,{inline='actions',height=46})
                            rows[6]=k.button('Game',function() k.push_page(7) end,{id='game',default_focus=true})
                            k.set_page(index,names[index],rows,{root=true,navigation=true,sidebar=nav,row_layout={mode='flow',max_columns=1}})
                        end
                        k.run({state={ui_lang='en'},theme={kind='app'},on_home_cancel=function()
                            exits=exits+1; k.dialog({title='Exit'})
                        end,build_pages=function()
                            for i=1,6 do build(i) end
                            k.set_page(7,'Item',{k.button('Launch',function() end)},{sidebar={}})
                        end})
                        love.load()
                        assert(k.debug_focus().focus_i==6)
                        local l=k.debug_layout()
                        local g=l.geometry
                        assert(g[1].content_y==g[2].content_y and g[2].content_y==g[3].content_y)
                        assert(g[4].content_y==g[5].content_y and g[4].content_y>g[1].content_y)
                        assert(g[6].content_y>g[4].content_y and g[6].w==l.w)
                        k.input('confirm'); assert(k.debug_page().index==7 and k.debug_navigation().depth==1)
                        k.input('cancel'); assert(k.debug_page().index==1 and k.debug_focus().focus_i==6)
                        k.input('left'); assert(k.debug_focus().zone=='sidebar')
                        painted={}; love.draw()
                        assert(painted.Installed,'the first destination starts in view')
                        assert(painted.Exit and painted['A Confirm    B Back'])
                        local nav_layout=k.debug_sidebar_geometry()
                        assert(nav_layout.h1>=32 and nav_layout.h7>=32,'navigation rows must not shrink to fit')
                        if WIDTH<600 then assert(nav_layout.scroll,'short menus scroll instead of compressing') end
                        local exit_y=nav_layout.y7
                        for i=2,5 do
                            k.input('down')
                            assert(k.debug_page().index==i and k.debug_focus().zone=='sidebar' and k.debug_focus().sidebar_i==i)
                            painted={}; love.draw()
                            assert(painted[names[i]] and painted.Exit,'focus scrolls into view while Exit remains pinned')
                            local scrolled=k.debug_sidebar_geometry()
                            assert(scrolled.y7==exit_y)
                            if scrolled.scroll then
                                assert(scrolled['y'..i]>=scrolled.viewport_top-0.01)
                                assert(scrolled['y'..i]+scrolled['h'..i]<=scrolled.viewport_bottom+0.01)
                            end
                        end
                        assert(selections==4,'one page selection per focus movement')
                        k.input('confirm'); assert(k.debug_page().index==5 and k.debug_navigation().depth==0)
                        assert(selections==4 and k.debug_focus().zone=='rows','confirm enters content without selecting twice')
                        k.input('cancel'); assert(k.debug_focus().zone=='sidebar' and k.debug_focus().sidebar_i==5)
                        k.input('cancel'); assert(k.debug_focus().zone=='sidebar' and k.debug_dialog().open and exits==1)
                        k.input('cancel'); assert(k.debug_focus().zone=='sidebar' and not k.debug_dialog().open)
                        k.input('down'); k.input('down')
                        assert(k.debug_page().index==6 and k.debug_page().sidebar_ids[k.debug_focus().sidebar_i]=='nav:quit' and exits==1)
                        painted={}; love.draw(); assert(painted.Exit,'Exit stays visible on the smallest screen')
                        k.input('confirm'); assert(k.debug_dialog().open and exits==2)
                        k.input('cancel'); k.input('up'); k.input('up'); k.input('confirm')
                        assert(k.debug_page().index==5 and k.debug_focus().zone=='rows')
                        -- Inline siblings consume horizontal movement before the drawer.
                        k.input('up'); assert(k.debug_focus().focus_i==4 or k.debug_focus().focus_i==5)
                        if k.debug_focus().focus_i==5 then k.input('left') end
                        k.input('right'); assert(k.debug_focus().focus_i==5)
                        k.input('left'); assert(k.debug_focus().focus_i==4 and k.debug_focus().zone=='rows')
                        if WIDTH<600 then
                            k.input('left'); assert(k.debug_focus().zone=='sidebar' and k.debug_focus().sidebar_i==5)
                            k.input('right'); assert(k.debug_focus().zone=='rows')
                            -- Root header has a single row and no Back action.
                            while k.debug_focus().zone~='bar' do k.input('up') end
                            k.input('confirm'); assert(k.debug_focus().zone=='sidebar' and k.debug_focus().sidebar_i==5)
                            k.set_page(5,'Settings',{k.select('Language',{'en','zh'},nil,'ui_lang')},
                                {root=true,navigation=true,sidebar={k.button('Settings',function() end,{active=true})}})
                            k.goto_page(5); k.input('left')
                            assert(k.get_state().ui_lang=='zh' and k.debug_focus().zone=='rows')
                        end
                        local actions=0
                        k.set_page(8,'Actions',{k.button('Row',function() end)}, {navigation=false,sidebar={
                            k.button('Delete',function() actions=actions+1 end,{select_on_focus=true})}})
                        k.goto_page(8); k.input('right')
                        assert(k.debug_focus().zone=='sidebar' and actions==0,'context actions never execute on focus')
                        k.input('confirm'); assert(actions==1)
                    ''')

    def test_responsive_panes_and_focus(self):
        for runtime in (Lua51, Lua54):
            for width, height in ((320, 240), (480, 320), (640, 480), (720, 720), (1280, 720)):
                with self.subTest(lua=runtime.__module__, size=(width, height)), tempfile.TemporaryDirectory() as source:
                    lua = runtime(unpack_returned_tuples=True)
                    lua.globals().SOURCE = source
                    lua.globals().WIDTH, lua.globals().HEIGHT = width, height
                    lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
                    lua.execute(DRAW_MOCK + SETUP)
                    lua.execute(r'''
                        local k=require('kit')
                        k.run({state={ui_lang='en'},theme={kind='app'},build_pages=function()
                            k.add_page('Home',{k.button('Game',function() end,{id='game'})},{navigation=false,sidebar={
                                k.button('Refresh',function() end,{id='refresh'}),
                                k.button('Left',function() end,{half=true,id='left'}),
                                k.button('Right',function() end,{half=true,id='right'}),
                                k.button('Last',function() end,{id='last'})}})
                        end})
                        love.load()
                        local l=k.debug_layout()
                        assert(l.band>0 and l.x>=0 and l.x+l.w<=WIDTH)
                        assert(l.compact==(WIDTH<600))
                        if l.compact then
                            assert(l.w>WIDTH*0.85)
                            k.input('right'); assert(k.debug_focus().zone=='sidebar')
                            k.input('down'); assert(k.debug_focus().sidebar_i==2)
                            k.input('right'); assert(k.debug_focus().sidebar_i==3)
                            k.input('left'); assert(k.debug_focus().sidebar_i==2)
                            k.input('up'); k.input('up'); assert(k.debug_focus().zone=='bar')
                            painted={}; love.draw()
                            assert(painted.Refresh and not painted.Game,'tools stay visible while header is focused')
                            k.input('down'); k.input('cancel')
                            assert(k.debug_focus().zone=='rows' and k.debug_focus().focus_i==1)
                            painted={}; love.draw(); assert(painted.Game and not painted.Refresh)
                            local tools={}
                            for i=1,10 do tools[i]=k.button('Tool '..i,function() end,{id='tool:'..i}) end
                            k.set_page(1,'Home',{k.button('Game',function() end)}, {navigation=false,sidebar=tools})
                            k.input('right'); painted={}; love.draw()
                            assert(painted['Tool 1'],'the compact action grid starts at its first row')
                            for i=1,9 do k.input('down') end
                            painted={}; love.draw()
                            assert(k.debug_focus().sidebar_i==10 and painted['Tool 10'])
                            k.input('cancel'); assert(k.debug_focus().zone=='rows')
                            local changes=0
                            local toggle={kind='switch',label='Remote',checked=false,
                                on_toggle=function(on) assert(on); changes=changes+1 end}
                            k.set_page(1,'Header',{k.button('Game',function() end)}, {header_action=toggle,sidebar={}})
                            circles={}; love.draw(); local before=circles[#circles].x
                            k.input('up'); k.input('confirm'); circles={}; love.draw()
                            assert(toggle.checked and changes==1 and circles[#circles].x>before)
                        else
                            assert(l.x+l.w<l.side_x)
                            k.input('right'); assert(k.debug_focus().zone=='sidebar')
                            k.input('left'); assert(k.debug_focus().zone=='rows')
                        end
                    ''')

    def test_pairing_qr_uses_integer_modules_and_compact_margin(self):
        for runtime in (Lua51, Lua54):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute(f"package.path={str(KIT / '?.lua')!r}..';'..package.path")
            lua.execute(DRAW_MOCK)
            lua.execute(r'''
                local qr=require('qr_view')
                local url='http://192.0.2.91:8080/123456'
                local matrix=qr.matrix(url)
                assert(qr.matrix(url)==matrix and #matrix==25)
                local updated=qr.matrix('http://192.0.2.91:8080/654321')
                assert(updated~=matrix)
                qr.draw(url,3.5,6.5,131,137)
                local paper=rects[1]
                local unit=paper.w/(#matrix+4)
                assert(unit==math.floor(unit) and paper.x==math.floor(paper.x) and paper.y==math.floor(paper.y))
                for i=2,#rects do
                    local r=rects[i]
                    assert(r.x>=paper.x+unit*2 and r.y>=paper.y+unit*2)
                    assert(r.x+r.w<=paper.x+paper.w-unit*2 and r.y+r.h<=paper.y+paper.h-unit*2)
                    assert(r.x==math.floor(r.x) and r.y==math.floor(r.y) and r.h==unit)
                end
                assert(not pcall(qr.matrix,''))
                assert(not pcall(qr.matrix,string.rep('x',513)))
            ''')


if __name__ == '__main__':
    unittest.main()
