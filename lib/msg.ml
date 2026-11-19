exception Error of string

let fail fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

let info fmt =
  let prefix = if Unix.isatty Unix.stderr then "\027[1;33mhutch:\027[0m" else "hutch:" in
  Printf.ksprintf (fun s -> Printf.eprintf "%s %s\n%!" prefix s) fmt
