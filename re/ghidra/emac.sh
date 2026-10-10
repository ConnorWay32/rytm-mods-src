#!/usr/bin/env bash
# Build a copy of Ghidra whose ColdFire language decompiles EMAC code.
#
# Stock Ghidra's 68000.sinc has mac/msac but no movclr, so every function that
# reads an accumulator (the machines, the noise generator, the pitch helpers)
# decompiles only up to its first movclr. This copy adds movclr.l ACCn,Rx and
# makes mac.l/msac.l fractional, (x * y) >> 31, as MAIN OS runs the EMAC.
# Scale factors are ignored; MAIN OS does not use them.
#
# The copy is an APFS clone at build/ghidra-emac. Point the existing scripts at
# it with GHIDRA=build/ghidra-emac; projects made by either install open in both.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC="${GHIDRA:-$HOME/Downloads/ghidra_12.1.2_PUBLIC}"
DST="build/ghidra-emac"
LANG_DIR="$DST/Ghidra/Processors/68000/data/languages"

[ -d "$SRC" ] || { echo "set GHIDRA to your Ghidra install (got $SRC)"; exit 1; }
rm -rf "$DST"
mkdir -p build
cp -cR "$SRC" "$DST"

python3 - "$LANG_DIR/68000.sinc" <<'EOF'
import re, sys
path = sys.argv[1]
lines = open(path).read().split('\n')
out, i = [], 0
while i < len(lines):
    line = lines[i]
    if re.match(r'^:(mac|msac)\.l ', line):
        out.append(line)
        i += 1
        while not lines[i].startswith('}'):
            m = re.match(r'\s*local tmp = (\S+) \* (\S+);', lines[i])
            if m:
                out.append('  local p:8 = sext(%s) * sext(%s);' % m.groups())
                out.append('  local q:8 = p s>> 31; local tmp:4 = q:4;')
            elif 'scalefactor ==' not in lines[i]:
                out.append(lines[i])
            i += 1
    out.append(lines[i])
    i += 1
s = '\n'.join(out)
anchor = ':move.l moveaccreg, reg03y  is'
movclr = (':movclr.l moveaccreg, reg03y  is op=0b1010 & op11=0 & moveaccreg & op8=1 '
          '& op47=0b1100 & reg03y    { reg03y = moveaccreg; moveaccreg = 0; }\n')
assert s.count(anchor) == 1 and 'movclr' not in s
open(path, 'w').write(s.replace(anchor, movclr + anchor))
EOF

(cd "$LANG_DIR" && "$OLDPWD/$DST/support/sleigh" coldfire.slaspec)
echo "EMAC-aware Ghidra at $DST"
