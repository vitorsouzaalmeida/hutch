(** Starting, joining and stopping a project's sandbox.

    A sandbox is a chain of host programs started detached from the terminal. [nix develop] provides
    the project's toolchain, [pasta] an isolated network, [bwrap] the filesystem view, and inside
    runs the keeper with a tmux server. A terminal joins it later with [nsenter].

    Nothing here runs a program of the sandbox on the host. In particular no tmux client runs on the
    host, since a tmux server can tell its clients to run commands. *)

(** {1 Decisions}

    These are pure, so that what a sandbox gets can be tested without starting one. *)

type inputs = {
  uid : int;
  gid : int;
  shell : string;
  claude : Policy.mount list;
  protect : Policy.mount list;
  token : Policy.mount option;
  base : string option;  (** The built base tools, a path in the Nix store. *)
  agent : bool;  (** The project's ssh-agent is running. *)
  host_ports : int list;
  exists : string -> bool;  (** Tells whether a host path exists. *)
}

val policy : Config.t -> Project.t -> inputs -> Policy.t
(** [policy c p inputs] is everything the sandbox of [p] may see and do. *)

val clean_env : Config.t -> user:string -> env:(string * string) list -> (string * string) list
(** [clean_env c ~user ~env] is the environment the chain starts with. Of the caller's environment
    [env], only the terminal type, the locale and the time zone are kept, so nothing exported in the
    caller's shell reaches the sandbox. *)

val join_env : Config.t -> env:(string * string) list -> (string * string) list
(** [join_env c ~env] is the environment of a command that joins a sandbox, before the sandbox's own
    saved environment is loaded. Of the caller's environment [env], only the terminal type is kept.
*)

val join_args : pid:int -> cwd:string -> string list -> string list
(** [join_args ~pid ~cwd command] is the [nsenter] arguments that run [command] in folder [cwd] of
    the sandbox whose keeper is [pid]. Every program named in them is an absolute path, because
    [nsenter] would otherwise look it up on the caller's [PATH], which inside leads into folders the
    sandbox can write. *)

(** {1 Actions} *)

val running : Config.t -> Project.t -> Keeper.t option
(** [running c p] is the keeper of [p]'s sandbox, if the sandbox is up and ready for commands. *)

val up : Config.t -> Project.t -> [ `Started | `Already_running ]
(** [up c p] starts the sandbox of [p] unless it is {!running}. Concurrent calls for one project
    start a single sandbox.

    @raise Msg.Error if the sandbox cannot be started safely or does not come up. *)

val stop : Config.t -> Project.t -> unit
(** [stop c p] asks every program in the sandbox of [p] to quit, waits a few seconds for them, then
    ends the sandbox and the project's ssh-agent. *)

val attach : Config.t -> Project.t -> cwd:string -> 'a
(** [attach c p ~cwd] replaces the current process by a shell session inside the sandbox of [p], in
    the sandbox's tmux. Each call gets a view of its own, so that two terminals can show different
    windows. The view ends with its terminal, and what runs in its windows goes on.

    @raise Msg.Error if the sandbox is not running. *)

val session : Project.t -> string
(** [session p] is the name of the tmux session of [p]'s sandbox. *)
