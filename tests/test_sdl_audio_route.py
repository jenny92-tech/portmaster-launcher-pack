# INPUT:  unittest、bash 与 _kit/portmaster_common.sh
# OUTPUT: SDL 音频路由及 Loong 环境隔离回归断言
# POS:    不访问真实声卡或写文件的共享音频后端测试
import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class AudioRouteTests(unittest.TestCase):
    def route(self, plugin, cfw="TrimUI"):
        script = r'''
source "$1"
launcher_platform_display() { return 1; }
CFW_NAME="$2"
plugin="$3"
PORT_NAME=test
LOG_PREFIX=test
XDG_RUNTIME_DIR=/unused-audio-test
SDL_AUDIODRIVER=existing
AUDIODEV=existing
mkdir() { :; }
chmod() { :; }
pactl() {
  case "$1" in
    info) return 0;;
    list) echo '0 real_sink';;
  esac
}
[() {
  case "${2:-}" in
    /usr/lib/alsa-lib/libasound_module_pcm_pulse.so|/usr/share/alsa/alsa.conf.d/50-pulseaudio.conf)
      builtin [ "$plugin" = yes ]; return;;
  esac
  builtin [ "$@"
}
audio_setup >/dev/null
printf '%s|%s|%s' "$SDL_AUDIODRIVER" "$AUDIODEV" "$XDG_RUNTIME_DIR"
'''
        return subprocess.check_output(
            ["bash", "-c", script, "audio-test",
             str(ROOT / "_kit/portmaster_common.sh"), cfw, plugin], text=True
        )

    def test_alsa_pulse_bridge(self):
        self.assertEqual(self.route("yes"), "alsa|pulse|/unused-audio-test")

    def test_native_pulse_without_bridge(self):
        self.assertEqual(self.route("no"), "pulseaudio|existing|/unused-audio-test")

    def test_loong_untouched(self):
        self.assertEqual(self.route("yes", "Loong"), "existing|existing|/unused-audio-test")


if __name__ == "__main__":
    unittest.main()
