# src equivalents of the ghi commands. Same Herdr flow; issue and PR calls use `src`.
#   sri    → ghi
#   sris   → ghis
#   srb    → ghb
#   sripr  → ghipr
#   sriprs → ghiprs
sri() { local GHSB_FORGE=src; ghi "$@"; }
sris() { local GHSB_FORGE=src; ghis "$@"; }
srb() { local GHSB_FORGE=src; ghb "$@"; }
sripr() { local GHSB_FORGE=src; ghipr "$@"; }
sriprs() { local GHSB_FORGE=src; ghiprs "$@"; }
