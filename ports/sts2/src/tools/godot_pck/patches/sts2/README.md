# STS2 PCK overlays

Game-specific extension mappings, Sentry stubs and project edits for the
[shared texture pipeline](../../README.md).

From the `godot_pck` directory:

```sh
patches/sts2/build.sh /path/to/SlayTheSpire2.pck
# Output: work/sts2/output.pck
```

The final PCK patches the original package, preserving resources the host editor
cannot rebuild. Recovered and merged-overlay trees are disposable working data.

| Input | Purpose |
|---|---|
| `overlay/addons/fmod/` | ARM64 GDExtension mappings; the device supplies native libraries |
| `overlay/addons/spine/` | ARM64 Spine extension mappings |
| `overlay/addons/sentry/SentryInit.gd` | No-op Node replacing unavailable native Sentry initialization |
| `overlay/addons/sentry/user_feedback/user_feedback_form.gd` | Control stub without missing Sentry SDK types |
| `apply.sh` | Copy static overrides; remove SentryInit autoload and Sentry extension config |

When the game changes extension paths or Sentry callers, rederive mappings and
stubs from that exact build. Native libraries are external inputs, not included
in the PCK overlay. Full source navigation is in [AGENTS.md](AGENTS.md).
