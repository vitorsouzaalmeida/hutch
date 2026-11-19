(** Approval of a project's own flake.

    [nix develop] evaluates a project's [flake.nix] on the host, before any sandbox exists, and code
    inside the sandbox can write the project. So, as with [direnv allow], a project flake is used
    only once the user has approved its exact contents. Approvals are stored outside the project,
    where the sandbox cannot see them.

    Not covered is a flake that reads files other than [.nix] ones from the project. *)

val digest : string -> string
(** [digest root] identifies the contents of [flake.lock] and of every [.nix] file below [root],
    with their paths. A symlink counts as its target path, not as the file it points to.
    [node_modules], [.git], [.data], [.pnpm-store] and [.claude/worktrees] are not searched. *)

val approved : file:string -> string -> bool
(** [approved ~file digest] is [true] if the approval stored in [file] is for [digest]. *)

val ensure : Project.t -> unit
(** [ensure p] returns if the flake of [p] is approved. Otherwise it asks the user on the terminal
    and stores a positive answer.

    @raise Msg.Error if the user declines, or if there is no terminal to ask on. *)
