(** Writing into folders a sandbox can write to.

    A sandbox may leave a symlink where [hutch] is about to write, hoping the write lands on a host
    file. These functions never write through a symlink. They are only safe while no sandbox of the
    project runs, since nothing here guards against a link created during the call. *)

val no_links : root:string -> string -> bool
(** [no_links ~root path] is [true] if neither [root], [path], nor any folder between them is a
    symlink. Missing components are not symlinks.

    @raise Invalid_argument if [path] is not [root] or below it. *)

val write : ?perm:int -> root:string -> string -> string -> unit
(** [write ~root path contents] replaces the file [path] by one holding [contents], creating the
    missing folders. A symlink at [path] is replaced, not followed. [perm] defaults to [0o600].

    @raise Msg.Error if a folder from [root] down to [path] is a symlink. *)

val drop_link : string -> unit
(** [drop_link path] removes [path] if it is a symlink. *)

val drop_links : root:string -> string -> string list
(** [drop_links ~root path] removes every symlink found below [root] on the way down to [path],
    [path] included, and is the list of removed paths. *)
