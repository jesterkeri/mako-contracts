#!/usr/bin/env bash
# The official way to run the T0.1 archive proof (a PROOF_STANDARD Version 3 Type B1 record).
#
#   bash script/run-proof.sh
#
# Starts Node from a STRIPPED environment: `env -i` with PATH set to the directory holding `node`, and
# nothing else. Nothing in the caller's shell (an old MAKO_RPC_* credential, NODE_OPTIONS enabling
# diagnostic reports, proxy settings, extra CA certificates) reaches the proof process. The probe itself
# refuses a --as-proof run from any environment beyond that minimum, so the proof cannot be produced from a
# credentialed shell by calling node directly.
#
# Added after Codex diff review round 7. The provider URLs are fixed in script/providers.json.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
node_bin="$(command -v node)" || { echo "node is not on PATH" >&2; exit 2; }
exec env -i PATH="$(dirname "$node_bin")" "$node_bin" "$here/probe-archive.mjs" --as-proof
