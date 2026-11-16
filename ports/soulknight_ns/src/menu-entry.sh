#!/bin/bash
# INPUT: Sibling game data, firmware .port.sh identity and literal player arguments.
# OUTPUT: Same-PID handoff to the ordinary Shell/PortMaster owner.
# POS: Small package bridge; debug execution views remain outside Release.
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
export SOULKNIGHT_NS_INSTALLATION="$BASE/soulknight_ns"
exec -a "$0" /bin/bash "$BASE/soulknight_ns/launcher.sh" "$@"
