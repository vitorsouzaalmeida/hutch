(** Claude Code inside a sandbox.

    Claude Code runs inside, from the host's own binary mounted read-only. Each project has its
    configuration, sessions, memory, plugins and login in its sandbox home, never in the host's
    [~/.claude]. The host's skills, agents, commands, output styles and [CLAUDE.md] are visible
    read-only. *)

val binary : Config.t -> string option
(** [binary c] is the file of the host's Claude Code, with every symlink followed. It is found
    through the [claude.bin] setting of [c] if set, or else as the first [claude] on the [PATH] of
    [c].

    @raise Msg.Error if [claude.bin] is set to something that is not a trusted program. *)

val mounts : Config.t -> string option -> Policy.mount list
(** [mounts c binary] is the read-only mounts that bring the host's Claude Code into a sandbox. The
    binary appears at its own path and as [~/.local/bin/claude]. *)

val token_mount : Config.t -> Project.t -> Policy.mount option
(** [token_mount c p] is the mount handing over the login token shared by all sandboxes, if the user
    saved one in the configuration folder of [c]. The token is copied to a host-only file. It never
    appears on a command line. *)

val prepare : Config.t -> Project.t -> unit
(** [prepare c p] brings the sandbox home of [p] up to date. It must run while no sandbox does.

    - [~/.claude/settings.json] is copied from the host, without its host-only [sandbox] section,
      whenever the host's file changed since the last copy.
    - [~/.claude.json] is created with onboarding marked as done.
    - The MCP servers of [base/mcp.json] in the configuration folder are added to it.

    Symlinks found where it writes are removed first, not followed.

    @raise Msg.Error if [base/mcp.json] is not of the form [{"mcpServers": {...}}]. *)

(** {1 JSON edits} *)

val parse : string -> Yojson.Safe.t option
(** [parse text] is the JSON object in [text], or [None] if [text] is not one. *)

val sandbox_settings : Yojson.Safe.t -> Yojson.Safe.t
(** [sandbox_settings json] is the host settings [json] as a sandbox gets them. *)

val initial_state : host:Yojson.Safe.t option -> Yojson.Safe.t
(** [initial_state ~host] is a first [~/.claude.json]. It keeps what [host], the host's own file,
    says about onboarding and nothing else, and turns automatic updates off. *)

val with_mcp : servers:(string * Yojson.Safe.t) list -> Yojson.Safe.t -> Yojson.Safe.t
(** [with_mcp ~servers json] is [json] with [servers] registered. A server of [json] with the same
    name is replaced, the others are kept. *)
