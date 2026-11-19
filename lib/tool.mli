(** Host programs that are safe to run or to hand to a sandbox.

    Everything [hutch] executes on the host goes through a {!t}. A sandbox can write into its
    project and its home folder, so a program found there could have been planted. *)

type t = private string
(** The type for checked programs. A value is an absolute path to an executable file that no sandbox
    can replace. *)

val check : Config.t -> string -> (t, string) result
(** [check c path] is [path] as a checked program. It is an error if [path] is relative, is not an
    executable file, or resolves into the projects folder or the sandbox homes of [c]. *)

val find_opt : Config.t -> string -> t option
(** [find_opt c name] is the first program called [name] in the [PATH] of [c] that passes {!check}.
    Relative [PATH] entries are skipped. *)

val find : Config.t -> string -> t
(** [find c name] is as {!find_opt}.

    @raise Msg.Error if there is no such program. *)

val real : t -> string
(** [real t] is the file [t] resolves to, with every symlink followed. *)
