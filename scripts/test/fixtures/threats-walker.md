# THREATS - the walker's own list (a fixture for scripts/threat-diff.sh and scripts/next.sh)

Written in phase 2 from doctrine/HOOK-ATTACKS.md and the spec; the matching lines filled once the independent list was in.

W-1: a stranger / pool A's fees / a second pool naming the hook, then a claim on it
from: doctrine/HOOK-ATTACKS.md class 3
matches: T-1

W-2: a router / the refund owed to the swapper / hookData that names a recipient
from: doctrine/HOOK-ATTACKS.md class 9
matches: T-2 (the same, seen from the router's side)

W-3: the owner's key / every LP's fees / setFee above the cap, then a swap
from: SPEC.md section 3 row 2
new
