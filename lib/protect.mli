(** Project files a sandbox must not change.

    Some files in a project are trusted and acted on by programs outside the sandbox (git, mise,
    nix, editors) or by the coding agent itself (hooks, MCP servers, instructions), and some get
    committed and pushed. Inside the sandbox they are read-only, so a malicious dependency cannot
    plant a hook, an MCP server, prompt text or git configuration.

    A file or folder is protected by mounting it read-only on itself. This also pins its name, since
    a mount point can be neither renamed nor removed. Only what exists when the sandbox starts can
    be protected, which is why {!prepare} creates the top-level entries first. *)

val files : string list
(** The names of protected files, at any depth. *)

val top_files : string list
(** The names of files protected only at the top of the project or of a worktree. *)

val dirs : string list
(** The names of protected folders, at any depth. *)

val parse_hide : string -> (string list, string) result
(** [parse_hide text] is the paths listed in [text], one per line, relative to the project. A [#]
    starts a comment. It is an error for a path to be absolute or to contain [..]. *)

val prepare : root:string -> unit
(** [prepare ~root] creates what must exist to be protected in the project at [root]. It creates the
    protected folders, [.claude/worktrees], an empty [.mcp.json] and [CLAUDE.md], and lists the
    files only [hutch] needs in [.git/info/exclude]. It must run while no sandbox does.

    @raise Msg.Error if a protected top-level folder is a symlink or a file. *)

val mounts : root:string -> hide:string list -> Policy.mount list
(** [mounts ~root ~hide] is the mounts to apply, in order, on top of a writable mount of the project
    at [root]. It covers the protected entries of the project and of each of its worktrees, down to
    five levels, and [.git]. [.claude/worktrees] stays writable. Each path of [hide] appears empty.

    A protected file that is a symlink cannot be pinned. If it points to a file in the project, that
    file is made read-only and a warning is printed. Otherwise only the warning is.

    @raise Msg.Error if a path of [hide] is a symlink. *)
