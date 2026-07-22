# shellcheck shell=bash
# SSH helpers for remote-host targets (generic ssh, aws-single, gcp-single).
# Reads SSH_HOST / SSH_USER / SSH_KEY_PATH from state (or from .env.<target>
# as a fallback for CI/scripted use).

ssh_host()     { state_get ssh_host     || env_get "$(env_file_for "$TARGET")" SSH_HOST; }
ssh_user()     { state_get ssh_user     || env_get "$(env_file_for "$TARGET")" SSH_USER; }
ssh_key_path() { state_get ssh_key_path || env_get "$(env_file_for "$TARGET")" SSH_KEY_PATH; }

ssh_opts() {
  local key
  key="$(ssh_key_path)"
  local -a opts=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
  [[ -n "$key" ]] && opts+=(-i "$key")
  printf '%s\n' "${opts[@]}"
}

ssh_target() {
  local host user
  host="$(ssh_host)"; user="$(ssh_user)"
  [[ -n "$host" ]] || die "SSH_HOST not set (state or .env.$TARGET)"
  [[ -n "$user" ]] || die "SSH_USER not set (state or .env.$TARGET)"
  printf "%s@%s" "$user" "$host"
}

ssh_run() {
  local -a opts
  mapfile -t opts < <(ssh_opts)
  ssh "${opts[@]}" "$(ssh_target)" "$@"
}

# Rsync a local path (dir or file) to the remote deploy dir.
ssh_rsync() {
  local src=$1 dst=${2:-.}
  local remote_dir
  remote_dir="$(state_get remote_dir)"
  [[ -n "$remote_dir" ]] || remote_dir="/opt/caytu-client"

  local -a opts
  mapfile -t opts < <(ssh_opts)
  local ssh_cmd="ssh"
  for o in "${opts[@]}"; do ssh_cmd+=" $o"; done

  rsync -az --delete --exclude '.git' --exclude 'backups' --exclude 'certbot' \
    -e "$ssh_cmd" \
    "$src" "$(ssh_target):${remote_dir}/${dst}"
}

ssh_remote_dir() {
  local d
  d="$(state_get remote_dir)"
  [[ -n "$d" ]] && printf '%s\n' "$d" || printf '/opt/caytu-client\n'
}
