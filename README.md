# hutch

`hutch` runs each project in its own sandbox. Your tools, your database, your dev server and Claude
Code all run inside it, so they can't touch the rest of your computer.

It works on Linux and uses bubblewrap, pasta and Nix.

## Install

```sh
nix build                   # makes result/bin/dev
nix profile install .       # or put result/bin/dev on your PATH
```

You need `bwrap`, `pasta`, `nsenter`, `setsid`, `tmux` and `bash` on your computer. You need `nix` for
projects that have a `flake.nix`, and `ssh-agent` and `ssh-add` for `hutch ssh-add`.

## Commands

```sh
hutch                 # open a shell inside the sandbox
hutch up              # start the sandbox without opening it
hutch status          # say if it is running
hutch stop            # stop everything inside
hutch ssh-add KEY     # give the sandbox one SSH key
```

`hutch` opens a shell in a tmux session inside the sandbox. Each terminal gets its own view. When you close a terminal, what you started
keeps running. `hutch stop` ends it all.

## Claude Code

Type `claude` in the shell that `hutch` opens.

It is the same Claude Code as on your computer, but it cannot change itself from inside. Each
project has its own login, sessions and memory, in `~/.sb/<project>/.claude`.

To log in once for all projects: run `claude setup-token` on your computer and save the token in `~/.config/hutch/claude-oauth-token`.

Your `~/.claude/settings.json` is copied in when it changes. Your skills, agents, commands and
`~/.claude/CLAUDE.md` can be read inside but not changed.

## What the sandbox can do

- Read and write the project folder.
- Use the internet.
- Use the tools from the project's `flake.nix`, such as node, postgres, or whatever.
- Start servers. They show up on your computer at `127.0.0.1`
- Keep its own home folder, in `~/.sb/<project>`.

## What it cannot do

- See your real home folder: `~/.ssh`, cloud keys, `~/.claude`, other projects.
- See the variables you exported in your shell.
- Reach services on your computer's localhost, unless you list their port.
- Change files that tools trust: `.claude/`, `.mcp.json`, `CLAUDE.md`, `.git/config`,
  `.git/hooks`, `flake.nix`, `.envrc`, `.npmrc`, mise files, `.vscode/`, `.zed/`, `.idea/`.

## Settings

All of them are optional.

`~/.config/hutch/config.toml`:

```toml
projects = "~/Projects"            # where your projects are

[claude]
bin = "~/.local/bin/claude"        # which Claude Code to use

[ssh]
askpass = "/usr/bin/ssh-askpass"   # the program that asks before an SSH key is used
```

One folder for each project, `~/.config/hutch/projects/<project>/`:

- `flake.nix`: optional. By default `hutch` uses the `flake.nix` of the project itself. Put one here
  only if the project has none, or if you want other tools. Then `hutch` uses this one.
- `hide`: files and folders that look empty inside, one on each line, such as `.env.production`.
- `host-ports`: ports of your computer the sandbox may reach, such as `11434`.

One folder for all sandboxes, `~/.config/hutch/base/`:

- `flake.nix`: tools that every sandbox gets.
- `mcp.json`: MCP servers that Claude Code gets in every sandbox.

For example, this gives every sandbox `ripgrep` and `jq`, and one MCP server.

`~/.config/hutch/base/flake.nix`:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      packages.x86_64-linux.default = pkgs.buildEnv {
        name = "hutch-base";
        paths = [
          pkgs.ripgrep
          pkgs.jq
        ];
      };
    };
}
```

`~/.config/hutch/base/mcp.json`:

```json
{
  "mcpServers": {
    "my-server": {
      "type": "stdio",
      "command": "/opt/hutch-base/bin/my-mcp-server",
      "args": ["--some-option"]
    }
  }
}
```

Inside the sandbox, these tools are in `/opt/hutch-base/bin`. A tool from the project wins if both
have the same name.

Set `HUTCH_LAN=1` when you start a sandbox to also show its servers to your local network.

## Build and test

```sh
nix develop                 # a shell with OCaml and dune
dune build
dune test                   # unit tests
dune build @integration     # starts real sandboxes on a test project
```
