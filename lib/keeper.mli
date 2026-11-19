(** Which process is a project's sandbox.

    A sandbox's first process, its keeper, lives exactly as long as the sandbox. Joining a sandbox
    means entering the namespaces of its keeper, so [hutch] must never mistake another process for
    it. Code inside any sandbox can give a process whatever command line it likes. What it cannot
    know is the random nonce [hutch] passes to each keeper it starts, since a sandbox sees neither
    the host's processes nor the host-only state file where the nonce is kept. *)

type t = { pid : int; nonce : string }

val nonce : unit -> string
(** [nonce ()] is a fresh random nonce. *)

val args : Config.t -> Project.t -> nonce:string -> string list
(** [args c p ~nonce] is the arguments to give the keeper script of [p] after the script itself.
    They are what identifies the keeper afterwards. *)

type claim =
  | Ours of string
      (** A keeper of this project started by this [hutch] instance, with its nonce. *)
  | Foreign
      (** A keeper of this project started by another [hutch] instance, one with another state
          folder. *)
  | Unrelated

val classify : Config.t -> Project.t -> string list -> claim
(** [classify c p argv] is what the command line [argv] claims to be. *)

val current : Config.t -> Project.t -> t option
(** [current c p] is the keeper recorded for [p], if it is still running, belongs to the user and
    carries the recorded nonce. *)

val find : Config.t -> Project.t -> nonce:string -> t option
(** [find c p ~nonce] is the running keeper of [p] started with [nonce]. *)

val record : Project.t -> t -> unit
(** [record p t] makes [t] the keeper that {!current} looks for. *)

val forget : Project.t -> unit
(** [forget p] removes the record of {!record}. *)

val leftovers : Config.t -> Project.t -> int list * int list
(** [leftovers c p] is the processes of the user that claim to be a keeper of [p], whatever is
    recorded. The first list holds the {!Ours}, the second the {!Foreign}. *)

val stop : ?grace:float -> Config.t -> Project.t -> unit
(** [stop c p] waits for every keeper of [p] that is {!Ours} to end, and terminates those that have
    not ended after [grace] seconds. A sandbox ends with its keeper. [grace] defaults to [10.].

    @raise Msg.Error if a keeper survives that. *)
