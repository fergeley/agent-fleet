#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/agent-fleet"
BIN_DIR="$HOME/.local/bin"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Agent Fleet requires python3." >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "Agent Fleet requires git." >&2
  exit 1
fi
if ! command -v tmux >/dev/null 2>&1; then
  echo "Agent Fleet requires tmux." >&2
  exit 1
fi

mkdir -p "$INSTALL_ROOT/state" "$BIN_DIR"
cp "$SCRIPT_DIR/agent_fleet.py" "$INSTALL_ROOT/agent_fleet.py"
chmod +x "$INSTALL_ROOT/agent_fleet.py"

for name in agent-fleet fleet; do
  cat > "$BIN_DIR/$name" <<EOF
#!/usr/bin/env sh
exec python3 "$INSTALL_ROOT/agent_fleet.py" "\$@"
EOF
  chmod +x "$BIN_DIR/$name"
done

if [ "$#" -gt 0 ]; then
  exec python3 "$INSTALL_ROOT/agent_fleet.py" "$@"
fi
echo "Installed Agent Fleet to $INSTALL_ROOT and $BIN_DIR/agent-fleet"
