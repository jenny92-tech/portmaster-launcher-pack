# Pinned LUIS components

Source: [SiENcE/luis at df9b601](https://github.com/SiENcE/luis/tree/df9b60106ee8ac29a9cfa41c8d3c0f8fc348e9e4).
`upstream.json` records the SHA256 of each original imported file. Only Button,
CheckBox, Switch and their direct dependencies are shipped. No upstream fonts,
core loop or automatic module discovery are included.

LUIS uses **MIT License with Additional Terms**, including its restriction on
machine-learning training. The full notice is in `LICENSE`; flux's original
MIT notice is in `LICENSE-flux.txt`.

Local changes, in addition to repository INPUT/OUTPUT/POS headers:

- Button: skip zero-elevation shadow draws; add optional inset border and text
  padding; omit font/text work for empty surface labels. Kit draws rich row text.
- CheckBox: optional inset border and vector checkmark for the shared theme.
- CheckBox/Switch: remove unconditional controller debug prints.
- Utils: load utf8 inside the UTF-8 helper, so the three components run on Lua 5.1
  without a UTF-8 module. Kit does not use that helper.

`../ui_components.lua` binds these actual widget objects to Kit's semantic input.
The same objects render the controls and dispatch their callbacks. Kit owns focus,
long lists, complete-path dialogs and text panning. It does not run a second LUIS
controller loop. Widget tweens settle during activation, preserving idle sleep.
