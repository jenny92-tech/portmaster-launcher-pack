#!/usr/bin/env python3
# INPUT:  JSON 安装路径清单、环境和启动参数
# OUTPUT: 经验证的 D2R_INSTALL_* 环境与 Bash 游戏执行入口
# POS:    将路径作为数据交给 2G 运行逻辑，避免执行配置文本
import json
import os
from pathlib import Path
import sys

FIELDS = ('runtime', 'game', 'profile', 'controllers', 'native', 'overlay', 'cache',
          'state', 'shader_misses', 'snapshot_cache', 'launcher_logs')


def load_paths(path):
    data = json.loads(Path(path).read_text())
    if set(data) != set(FIELDS):
        raise ValueError('incomplete D2R installation paths')
    for value in data.values():
        if (not isinstance(value, str) or not Path(value).is_absolute() or
                any(char in value for char in ('\0', '\n', '\r'))):
            raise ValueError('D2R installation paths must be absolute')
    return data


def main():
    data = load_paths(sys.argv[1])
    env = dict(os.environ)
    env.update({'D2R_INSTALL_' + key.upper(): value for key, value in data.items()})
    runner = Path(__file__).resolve().with_name('run-game.sh')
    os.execve('/bin/bash', ['/bin/bash', str(runner), *sys.argv[2:]], env)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit('D2R 2G: ' + str(error) + '; build with D2R_NS_2G_ENTRY from the prepared installation.')
