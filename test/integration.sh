#!/usr/bin/env bash
# End-to-end test of a built hutch, on a throwaway project with its own home, configuration and
# state, so it never touches a real sandbox.
#
#   test/integration.sh PATH/TO/hutch        (or: dune build @integration)
#
# Needs bwrap, pasta, nsenter, tmux, git, python3 and script(1) on the host, and the internet.
set -u
hutch=$(readlink -f "${1:?usage: integration.sh PATH/TO/hutch}")
here=$(dirname "$(readlink -f "$0")")

T=$(mktemp -d "${TMPDIR:-/tmp}/hutch-it.XXXXXX")
real_path=$PATH
export HOME="$T/home"
export HUTCH_STATE="${XDG_RUNTIME_DIR:?}/hutch-it-${T##*.}"
unset HUTCH_PROJECTS HUTCH_CONFIG HUTCH_SB_ROOT HUTCH_LAN HUTCH_NO_BASE HUTCH_SANDBOX XDG_CONFIG_HOME SSH_ASKPASS
# As on a real machine, PATH starts with a folder of the home, which inside is sandbox-writable.
export PATH="$HOME/.local/bin:$real_path"
name=it-demo
proj="$HOME/Projects/$name"
sb="$HOME/.sb/$name"
outside="$T/outside"

fails=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
exits() { local want=$1 d=$2; shift 2; "$@" >/dev/null 2>&1; local got=$?
          if [[ $got == "$want" ]]; then ok "$d"; else bad "$d (exit $got, expected $want)"; fi; }
# Runs a command inside the sandbox the way a shell opened with `hutch` would see things: it joins
# the keeper's namespaces and loads the environment the sandbox saved when it started.
inside() {
  local pid; pid=$(cut -d' ' -f1 "$HUTCH_STATE/$name.pid") || return 125
  nsenter --target "$pid" --user --mount --net --pid --ipc --uts --cgroup --preserve-credentials \
    --root --wd /usr/bin/env -i HOME="$HOME" /usr/bin/bash -c '
      while IFS= read -r -d "" kv; do
        case ${kv%%=*} in ""|[0-9]*|*[!A-Za-z0-9_]*|BASH*|SHELLOPTS|PWD|SHLVL|_) continue ;; esac
        export "$kv" 2>/dev/null
      done < "$HOME/.hutch-env0"
      exec "$@"' inside "$@"
}
# hutch in a pseudo-terminal: open the shell inside, wait, then detach (tmux: Ctrl-b d).
attach() { (sleep "$1"; printf '\002d'; sleep 0.5) | script -qec "'$hutch'" /dev/null 2>&1; }
sessions() { inside tmux -S "$HOME/tmux.sock" list-sessions | wc -l; }
windows()  { inside tmux -S "$HOME/tmux.sock" list-windows -t "=$name" | wc -l; }
keepers() { pgrep -u "$UID" -f -- "^bash -c .*hutch-keeper $name " | wc -l; }
agents()  { pgrep -u "$UID" -f -- "^ssh-agent -a $HUTCH_STATE/" | wc -l; }

listener=""
cleanup() {
  ( cd "$proj" 2>/dev/null && "$hutch" stop ) >/dev/null 2>&1
  [[ -n $listener ]] && kill "$listener" 2>/dev/null
  rm -rf -- "${T:?}" "${HUTCH_STATE:?}"
}
trap cleanup EXIT

mkdir -p "$proj" "$HOME/.ssh" "$HOME/.claude" "$HOME/.local/bin" "$outside"
echo secret > "$HOME/.ssh/id_test"
echo '{}' > "$HOME/.claude/.credentials.json"
printf '[user]\n\tname = it\n\temail = it@example.invalid\n' > "$HOME/.gitconfig"
git init -q "$proj"
cd "$proj" || exit 1
echo hello > README.md

echo "Start and status"
exits 3 "stopped before the first start"            "$hutch" status
check   "asking for the status creates nothing"     test ! -e "$HOME/.sb"
exits 0 "hutch up"                                    "$hutch" up
exits 0 "running after it"                          "$hutch" status
exits 0 "hutch up again changes nothing"              "$hutch" up
check   "one sandbox"                               test "$(keepers)" = 1
check   "state is private"                          test "$(stat -c %a "$HUTCH_STATE")" = 700

echo "Inside (probe suite)"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -m http.server --bind 127.0.0.1 "$port" >/dev/null 2>&1 &
listener=$!
sleep 0.5
if inside env HUTCH_PROBE_HOST_PORTS="$port" bash -s < "$here/probe.sh"; then ok "probe suite"; else bad "probe suite"; fi

echo "The shell inside"
out=$(attach 1.5)
if [[ $out == *detached* ]]; then ok "hutch opens the shell inside, and detaches"; else bad "hutch opens the shell inside, and detaches"; fi
check   "still running after detaching"             "$hutch" status
check   "the terminal's view is gone"               test "$(sessions)" = 1
attach 3 >/dev/null & first=$!
sleep 1
attach 1.2 >/dev/null & second=$!
sleep 0.7
check   "two terminals get a view each"             test "$(sessions)" = 3
check   "and a window each"                         test "$(windows)" = 2
wait "$first" "$second"
check   "both views are gone, the windows stay"     test "$(sessions) $(windows)" = "1 2"
mkdir -p "$sb/.local/bin"
for planted in env bash sh setpriv; do
  printf '#!/bin/sh\n/usr/bin/env > "$HOME/leak"\nexec /usr/bin/%s "$@"\n' "$planted" > "$sb/.local/bin/$planted"
  chmod +x "$sb/.local/bin/$planted"
done
SECRET_IT=leak attach 1 >/dev/null
check   "a planted program runs inside only"        test -s "$sb/leak"
check   "and gets no variable of the host shell"    sh -c "! grep -q SECRET_IT '$sb/leak'"
rm -f "$sb/leak" "$sb/.local/bin/env" "$sb/.local/bin/bash" "$sb/.local/bin/sh" "$sb/.local/bin/setpriv"
exits 125 "hutch refuses to run inside a sandbox"     env HUTCH_SANDBOX="$name" "$hutch" status
exits 124 "hutch run is not a command"                "$hutch" run true
exits 124 "hutch claude is not a command"             "$hutch" claude --version

if command -v ssh-keygen >/dev/null 2>&1; then
  echo "SSH key"
  ssh-keygen -q -t ed25519 -N "" -f "$T/key"
  exits 0 "hutch ssh-add gives the sandbox a key"     "$hutch" ssh-add "$T/key"
  if inside ssh-add -l | grep -q ED25519; then ok "the key is listed inside"; else bad "the key is listed inside"; fi
  if inside test -e "$T/key"; then bad "its file is not visible inside"; else ok "its file is not visible inside"; fi
fi

echo "A lost record, a second start, a foreign sandbox"
rm -f "$HUTCH_STATE/$name.pid"
exits 3 "without its record the sandbox isn't trusted" "$hutch" status
exits 0 "hutch up replaces it"                        "$hutch" up
check   "one sandbox"                               test "$(keepers)" = 1
check   "the project's ssh-agent runs"              test "$(agents)" = 1
exits 0 "hutch stop"                                  "$hutch" stop
exits 3 "stopped"                                   "$hutch" status
check   "no process left"                           test "$(keepers)" = 0
check   "no ssh-agent left"                         test "$(agents)" = 0
"$hutch" up >/dev/null 2>&1 & a=$!
"$hutch" up >/dev/null 2>&1 & b=$!
"$hutch" up >/dev/null 2>&1 & c=$!
wait "$a" "$b" "$c"
check   "three hutch up at once start one sandbox"    test "$(keepers)" = 1
exits 0 "running"                                   "$hutch" status
"$hutch" stop >/dev/null 2>&1
attach 2 >/dev/null
exits 0 "hutch starts the sandbox by itself, and the sandbox outlives it" "$hutch" status
"$hutch" stop >/dev/null 2>&1
bash -c 'sleep 30; :' hutch-keeper "$name" other-instance 0123 & fake=$!   # another instance's keeper
sleep 0.2
exits 125 "refuses to start next to another instance's sandbox" "$hutch" up
kill "$fake" 2>/dev/null; wait "$fake" 2>/dev/null

mkdir -p "$HOME/Projects/it.dot"
dotted() ( cd "$HOME/Projects/it.dot" && "$hutch" up && "$hutch" status && "$hutch" stop )
check   "a project name with a dot works"           dotted

echo "Symlinks left by a sandbox (planted while stopped)"
echo host > "$outside/target.json"
rm -rf "$sb/.claude"; ln -s "$outside" "$sb/.claude"
rm -f "$sb/.claude.json"; ln -s "$outside/target.json" "$sb/.claude.json"
rm -f "$sb/.gitconfig"; ln -s "$outside/created-by-bwrap" "$sb/.gitconfig"
rm -f "$sb/.zshrc"; ln -s "$outside/zshrc" "$sb/.zshrc"
exits 0 "hutch up with links in the sandbox home"     "$hutch" up
check   "nothing was written through them"          test "$(ls "$outside")" = target.json
check   "a linked file is untouched"                test "$(cat "$outside/target.json")" = host
for f in .claude .claude.json .gitconfig .zshrc; do
  check "$f is no longer a link"                    test ! -L "$sb/$f"
done
"$hutch" stop >/dev/null 2>&1
rmdir "$proj/.vscode"; ln -s "$outside" "$proj/.vscode"
exits 125 "a symlinked .vscode in the project is refused" "$hutch" up
check   "and left in place"                         test -L "$proj/.vscode"
check   "nothing was written through it"            test "$(ls "$outside")" = target.json
rm "$proj/.vscode"

echo "Flake approval"
echo '{ outputs = { self }: { }; }' > "$proj/flake.nix"
exits 125 "an unapproved project flake is refused without a terminal" "$hutch" up < /dev/null
exits 3 "and nothing was started"                   "$hutch" status
rm "$proj/flake.nix"

echo
if (( fails )); then echo "$fails check(s) failed"; exit 1; else echo "all checks passed"; fi
