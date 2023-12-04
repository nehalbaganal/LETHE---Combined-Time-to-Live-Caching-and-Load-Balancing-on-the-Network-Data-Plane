#!/bin/bash
echo Controller: ${1} - Delay: ${2}ms - Bandwidth+TTL Info: ${3} - Num Objects: ${4} - Num Requests: ${5}
python3 ../mcloadgen_static/multirun.py ${1}_${2}msDelay_${3} 90 ${4} ${5}
python3 ../mcloadgen_static/multirun.py ${1}_${2}msDelay_${3} 95 ${4} ${5}
python3 ../mcloadgen_static/multirun.py ${1}_${2}msDelay_${3} 99 ${4} ${5}
python3 ../mcloadgen_static/multirun.py ${1}_${2}msDelay_${3} 0 ${4} ${5}
