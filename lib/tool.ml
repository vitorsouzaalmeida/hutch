type t = string

let sandbox_writable (c : Config.t) path =
  Fs.is_under ~root:c.projects path || Fs.is_under ~root:c.sb_root path

let executable_file path =
  match Unix.stat path with
  | { st_kind = S_REG; _ } -> (
      try
        Unix.access path [ X_OK ];
        true
      with Unix.Unix_error _ -> false)
  | _ -> false
  | exception Unix.Unix_error _ -> false

let check c path =
  if Filename.is_relative path then Error (path ^ " is not an absolute path")
  else if not (executable_file path) then Error (path ^ " is not an executable file")
  else if sandbox_writable c path || sandbox_writable c (Unix.realpath path) then
    Error (path ^ " is inside a folder that sandboxes can write to")
  else Ok path

let find_opt (c : Config.t) name =
  let candidate dir =
    if Filename.is_relative dir then None else Result.to_option (check c (Filename.concat dir name))
  in
  List.find_map candidate c.path

let find c name =
  match find_opt c name with
  | Some t -> t
  | None -> Msg.fail "hutch needs '%s' on the host, and it isn't on your PATH" name

let real = Unix.realpath
