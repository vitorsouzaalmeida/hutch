(** What a sandbox can see and do, as plain data.

    Everything [hutch] decides about a sandbox ends up here first, and only then gets rendered into
    command-line arguments for the programs that enforce it. Keeping the decision separate from the
    enforcement is what makes it testable. *)

(** One entry of the sandbox's filesystem view. Order matters. Later entries are mounted on top of
    earlier ones, so a writable folder can sit inside a read-only one. *)
type mount =
  | Ro_bind of { src : string; dst : string }  (** Read-only. [src] must exist. *)
  | Ro_bind_try of { src : string; dst : string }  (** Read-only, skipped if [src] is missing. *)
  | Bind of { src : string; dst : string }  (** Read-write. *)
  | Tmpfs of string  (** An empty, writable folder. A hidden folder looks like this too. *)
  | Hidden_file of string  (** The file shows up empty and read-only. *)
  | Dir of { path : string; perms : int option }
  | Symlink of { target : string; link : string }
  | Proc of string
  | Dev of string

type net = {
  lan : bool;  (** Servers started inside are reachable from the LAN, not only from the host. *)
  host_ports : int list;  (** Ports of the host's own [127.0.0.1] the sandbox may connect to. *)
}

type t = {
  hostname : string;
  uid : int;
  gid : int;
  mounts : mount list;
  env : (string * string) list;  (** Set inside, on top of the inherited environment. *)
  unset_env : string list;
  chdir : string option;
  net : net;
}

val empty : hostname:string -> uid:int -> gid:int -> t
(** [empty ~hostname ~uid ~gid] is a sandbox with no files, no environment changes and a network
    closed in both directions except for outgoing connections to the internet. *)

val destination : mount -> string
(** [destination m] is the path that [m] creates or covers inside the sandbox. *)

val parse_host_ports : string -> (int list, string) result
(** [parse_host_ports text] is the ports listed in [text], separated by spaces, commas or newlines.
    A [#] starts a comment that runs to the end of the line. *)

val to_bwrap_args : empty_file:string -> t -> string list
(** [to_bwrap_args ~empty_file t] is the [bwrap] arguments for [t], in order, without the command to
    run. [empty_file] is a host file that is empty and read-only. It is bound over hidden files,
    because [/dev/null] cannot be read inside a sandbox whose [/dev] is mounted [nodev]. *)

val to_pasta_args : net -> string list
(** [to_pasta_args net] is the [pasta] arguments for [net], without the command to run. *)
