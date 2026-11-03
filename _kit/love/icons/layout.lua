-- INPUT:  Pinned Fluent SVGs and upstream.json via _kit/build_ui_icons.cjs
-- OUTPUT: Physical-size icon atlas geometry and semantic row indices
-- POS:    Generated icon layout; rebuild rather than edit by hand
return {
    width=1230,height=700,min_size=8,max_size=48,padding=1,row_height=50,
    names={
        menu=0,
        app=1,
        games=2,
        install=3,
        cleanup=4,
        repair=5,
        package=6,
        remote=7,
        settings=8,
        diagnostics=9,
        help=10,
        quit=11,
        refresh=12,
        language=13,
    },
}
