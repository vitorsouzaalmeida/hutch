#!/usr/bin/env bash
# Runs INSIDE a hutch sandbox: copy it into the project, open the shell with `hutch`, then run
#   bash probe.sh
# Tries what a malicious dependency or a prompt-injected agent would try, plus the things daily
# work needs. Prints one line per check; exits non-zero if any check fails.
#
#   HUTCH_PROBE_HOST_PORTS  ports the host listens on (127.0.0.1) that must NOT be reachable
#   HUTCH_PROBE_TOOL        a command the project's flake provides, expected first on PATH
set -u
proj=${PROJECT_ROOT:?not inside a hutch sandbox}
fails=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }
# refused DESC CMD...: the command must fail (blocked).  works DESC CMD...: it must succeed.
refused() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d (was allowed)"; else ok "$d"; fi; }
works()   { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d (failed)"; fi; }
w() { ( : >> "$1" ) 2>/dev/null; }          # can I write/create this file?

echo "Host secrets and other projects"
refused "the host's ~/.ssh is not visible"          test -e "$HOME/.ssh"
refused "the host's Claude login is not visible"    test -e "$HOME/.claude/.credentials.json"
refused "other projects are not visible"            sh -c "ls '${proj%/*}' | grep -qvx '${proj##*/}'"
refused "no Wayland/X11 socket"                     sh -c 'ls /run/user/*/wayland-* /tmp/.X11-unix/X* 2>/dev/null | grep -q .'
refused "no Docker socket"                          test -S /run/docker.sock
refused "no D-Bus session bus"                      sh -c 'ls /run/user/*/bus 2>/dev/null | grep -q .'
refused "no Nix daemon socket"                      test -S /nix/var/nix/daemon-socket/socket

echo "Files the host or Claude Code trust"
for f in .claude/settings.json .claude/hooks/probe.sh .mcp.json CLAUDE.md .zed/tasks.json .vscode/tasks.json \
         .idea/workspace.xml .git/config .git/hooks/pre-commit .git/info/attributes flake.nix; do
  if [[ $f == flake.nix && ! -e $proj/flake.nix ]]; then continue; fi
  if [[ $f == .git/* && ! -d $proj/.git ]]; then continue; fi
  refused "can't write $f" w "$proj/$f"
done
# Renames only: a recursive delete can't remove a protected folder, but it would empty the
# writable parts of .git.
for d in .claude .vscode .zed .idea .mcp.json CLAUDE.md .git; do
  [[ -e $proj/$d ]] || continue
  refused "can't rename $d away"   mv -T "$proj/$d" "$proj/$d.probe"
  [[ -e $proj/$d.probe ]] && mv -T "$proj/$d.probe" "$proj/$d"
done
for f in .mcp.json CLAUDE.md; do
  refused "can't delete $f"        rm -f "$proj/$f"
done
if [[ -d $proj/.git ]]; then
  works "git can read the repository"               git -C "$proj" status
  works "git can write the repository"              sh -c "cd '$proj' && git stash list && : >> .git/probe && rm -f .git/probe"
fi
works   "can write .claude/worktrees/ (Claude's worktrees)"  sh -c ": >> '$proj/.claude/worktrees/.probe' && rm -f '$proj/.claude/worktrees/.probe'"
works   "can write ordinary project files"                   sh -c "touch '$proj/.probe-file' && rm -f '$proj/.probe-file'"

echo "Generated shell files can't be changed or swapped"
refused "can't write ~/.zshrc"                      w "$HOME/.zshrc"
refused "can't replace ~/.zshrc with a symlink"     ln -sfn /etc/passwd "$HOME/.zshrc"
refused "can't write ~/.zshenv"                     w "$HOME/.zshenv"
refused "can't write ~/.hutch-env.sh"                 w "$HOME/.hutch-env.sh"
refused "can't write /etc/hosts"                    w /etc/hosts
if command -v claude >/dev/null 2>&1; then
  refused "can't change the Claude Code binary"     w "$(readlink -f "$(command -v claude)")"
fi

echo "Network"
probe_port() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
for p in ${HUTCH_PROBE_HOST_PORTS:-}; do
  refused "host localhost:$p not reachable"         probe_port 127.0.0.1 "$p"
done
works   "internet reachable (HTTPS to github.com)"  timeout 8 curl -sS -o /dev/null https://github.com

echo "Daily work"
works   "XDG_RUNTIME_DIR exists and is private"     sh -c '[ -d "$XDG_RUNTIME_DIR" ] && [ "$(stat -c %a "$XDG_RUNTIME_DIR")" = 700 ]'
works   "/tmp is writable"                          sh -c 'f=$(mktemp) && rm -f "$f"'
works   "the home folder is writable"               sh -c ': >> "$HOME/.probe" && rm -f "$HOME/.probe"'
works   "Claude config is this project's own"       test "$(readlink -f "$HOME/.claude")" = "$HOME/.claude"
if command -v claude >/dev/null 2>&1; then
  works "Claude Code runs"                          claude --version
else
  echo "  skip  Claude Code is not installed on the host"
fi
if [[ -d /opt/hutch-base/bin ]]; then
  works "base tools are on PATH"                    sh -c 'case ":$PATH:" in *:/opt/hutch-base/bin:*) exit 0;; *) exit 1;; esac'
fi
if [[ -n ${HUTCH_PROBE_TOOL:-} ]]; then
  works "the project's $HUTCH_PROBE_TOOL is first on PATH" sh -c 'case "$(command -v "$HUTCH_PROBE_TOOL")" in /nix/store/*) exit 0;; *) exit 1;; esac'
fi

echo
if (( fails )); then echo "$fails check(s) failed"; exit 1; else echo "all checks passed"; fi
