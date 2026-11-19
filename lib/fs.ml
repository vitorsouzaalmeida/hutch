type kind = Missing | File | Dir | Link | Other

(* [lstat], so a symlink is reported as a link whatever it points to. *)
let kind path =
  match (Unix.lstat path).st_kind with
  | S_REG -> File
  | S_DIR -> Dir
  | S_LNK -> Link
  | S_CHR | S_BLK | S_FIFO | S_SOCK -> Other
  | exception Unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> Missing

let is_under ~root path = path = root || String.starts_with ~prefix:(root ^ "/") path
let read path = In_channel.with_open_bin path In_channel.input_all
let read_opt path = try Some (read path) with Sys_error _ -> None

let write ?(perm = 0o644) path contents =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm path
    (fun oc -> Out_channel.output_string oc contents)

let rec mkdir_p ?(perm = 0o755) dir =
  if kind dir = Missing then begin
    mkdir_p ~perm (Filename.dirname dir);
    try Unix.mkdir dir perm with Unix.Unix_error (EEXIST, _, _) -> ()
  end

let remove path = try Unix.unlink path with Unix.Unix_error (ENOENT, _, _) -> ()

let rec remove_tree path =
  match kind path with
  | Missing -> ()
  | Dir ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | File | Link | Other -> Unix.unlink path

(* Symlinks are reported but never entered: a link could lead out of [root]. *)
let walk ?(max_depth = max_int) root ~visit =
  let rec go depth rel =
    let dir = if rel = "" then root else Filename.concat root rel in
    match Sys.readdir dir with
    | exception Sys_error _ -> ()
    | names ->
        Array.sort String.compare names;
        Array.iter (entry depth rel) names
  and entry depth rel name =
    let rel = if rel = "" then name else rel ^ "/" ^ name in
    let kind = kind (Filename.concat root rel) in
    match visit ~rel ~name ~kind with
    | `Enter when kind = Dir && depth < max_depth -> go (depth + 1) rel
    | `Enter | `Skip -> ()
  in
  go 1 ""
