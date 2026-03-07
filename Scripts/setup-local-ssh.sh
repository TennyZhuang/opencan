#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_DIR="$REPO_ROOT/.local-ssh"
PORT="${OPENCAN_LOCAL_SSH_PORT:-22222}"
SFTP_SERVER="/usr/libexec/sftp-server"

if [[ ! -x "$SFTP_SERVER" ]]; then
  echo "error: missing SFTP server at $SFTP_SERVER" >&2
  echo "SFTP is required because OpenCAN deploys opencan-daemon over SFTP." >&2
  exit 1
fi

mkdir -p "$SSH_DIR"

if [[ ! -f "$SSH_DIR/test_key" ]]; then
  ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/test_key" -N "" -q
  echo "Generated test SSH key: $SSH_DIR/test_key"
fi

if [[ ! -f "$SSH_DIR/host_key" ]]; then
  ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/host_key" -N "" -q
  echo "Generated host key: $SSH_DIR/host_key"
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
pub_key="$(cat "$SSH_DIR/test_key.pub")"
if ! grep -qF "$pub_key" "$HOME/.ssh/authorized_keys"; then
  echo "$pub_key" >> "$HOME/.ssh/authorized_keys"
  echo "Added test key to $HOME/.ssh/authorized_keys"
fi

cat > "$SSH_DIR/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $SSH_DIR/host_key
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
PidFile $SSH_DIR/sshd.pid
Subsystem sftp $SFTP_SERVER
# Citadel/NIOSSH may offer RSA auth as ssh-rsa only.
PubkeyAcceptedAlgorithms +ssh-rsa
HostkeyAlgorithms +ssh-rsa
AllowUsers $(whoami)
EOF

echo ""
echo "Local SSH test server configured."
echo "  Port:   $PORT"
echo "  Key:    $SSH_DIR/test_key"
echo "  Config: $SSH_DIR/sshd_config"
echo ""
echo "Start server:"
echo "  /usr/sbin/sshd -f $SSH_DIR/sshd_config"
echo "Stop server:"
echo "  kill \$(cat $SSH_DIR/sshd.pid)"
echo "Verify connection:"
echo "  ssh -i $SSH_DIR/test_key -p $PORT -o StrictHostKeyChecking=no localhost whoami"
echo ""
echo "Add this to .env:"
echo "  OPENCAN_TEST_NODE_NAME=local"
echo "  OPENCAN_TEST_NODE_HOST=127.0.0.1"
echo "  OPENCAN_TEST_NODE_PORT=$PORT"
echo "  OPENCAN_TEST_NODE_USERNAME=$(whoami)"
echo "  OPENCAN_TEST_WORKSPACE_NAME=home"
echo "  OPENCAN_TEST_WORKSPACE_PATH=$HOME"
echo "  OPENCAN_TEST_SSH_KEY_PATH=$SSH_DIR/test_key"
echo "  OPENCAN_TEST_AGENT_COMMAND=$HOME/.opencan/bin/mock-acp-server"
echo ""
echo "Cleanup note:"
echo "  This script leaves the test key in ~/.ssh/authorized_keys for reuse."
echo "  Remove it with:"
echo "  awk 'NR==FNR { drop[\$0]=1; next } !(\$0 in drop)' $SSH_DIR/test_key.pub \"$HOME/.ssh/authorized_keys\" > \"$HOME/.ssh/authorized_keys.tmp\" && mv \"$HOME/.ssh/authorized_keys.tmp\" \"$HOME/.ssh/authorized_keys\""
echo ""
echo "If auth fails, confirm macOS Remote Login is enabled in System Settings > General > Sharing."
