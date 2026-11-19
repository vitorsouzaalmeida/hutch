type mount =
  | Ro_bind of { src : string; dst : string }
  | Ro_bind_try of { src : string; dst : string }
  | Bind of { src : string; dst : string }
  | Tmpfs of string
  | Hidden_file of string
  | Dir of { path : string; perms : int option }
  | Symlink of { target : string; link : string }
  | Proc of string
  | Dev of string

type net = { lan : bool; host_ports : int list }

type t = {
  hostname : string;
  uid : int;
  gid : int;
  mounts : mount list;
  env : (string * string) list;
  unset_env : string list;
  chdir : string option;
  net : net;
}

let empty ~hostname ~uid ~gid =
  {
    hostname;
    uid;
    gid;
    mounts = [];
    env = [];
    unset_env = [];
    chdir = None;
    net = { lan = false; host_ports = [] };
  }

let destination = function
  | Ro_bind { dst; _ } | Ro_bind_try { dst; _ } | Bind { dst; _ } -> dst
  | Tmpfs path | Hidden_file path | Dir { path; _ } | Proc path | Dev path -> path
  | Symlink { link; _ } -> link

let parse_host_ports text =
  let uncomment line = List.hd (String.split_on_char '#' line) in
  let words line =
    String.split_on_char ' ' (String.map (function ',' | '\t' | '\r' -> ' ' | c -> c) line)
  in
  let port word =
    match int_of_string_opt word with
    | Some p when p >= 1 && p <= 65535 -> Ok p
    | Some _ | None -> Error (Printf.sprintf "'%s' is not a port number" word)
  in
  String.split_on_char '\n' text
  |> List.concat_map (fun line -> words (uncomment line))
  |> List.filter (fun word -> word <> "")
  |> List.fold_left
       (fun acc word -> Result.bind acc (fun ports -> Result.map (fun p -> p :: ports) (port word)))
       (Ok [])
  |> Result.map List.rev

(* Always on: a fresh namespace of every kind, except the network, which pasta has already set
   up and which bwrap must join rather than replace. *)
let base_args = [ "--unshare-all"; "--share-net"; "--die-with-parent" ]

let mount_args ~empty_file = function
  | Ro_bind { src; dst } -> [ "--ro-bind"; src; dst ]
  | Ro_bind_try { src; dst } -> [ "--ro-bind-try"; src; dst ]
  | Bind { src; dst } -> [ "--bind"; src; dst ]
  | Tmpfs path -> [ "--tmpfs"; path ]
  | Hidden_file path -> [ "--ro-bind"; empty_file; path ]
  | Dir { path; perms = None } -> [ "--dir"; path ]
  | Dir { path; perms = Some p } -> [ "--perms"; Printf.sprintf "%04o" p; "--dir"; path ]
  | Symlink { target; link } -> [ "--symlink"; target; link ]
  | Proc path -> [ "--proc"; path ]
  | Dev path -> [ "--dev"; path ]

let to_bwrap_args ~empty_file t =
  List.concat
    [
      base_args;
      [ "--uid"; string_of_int t.uid; "--gid"; string_of_int t.gid; "--hostname"; t.hostname ];
      List.concat_map (mount_args ~empty_file) t.mounts;
      List.concat_map (fun (k, v) -> [ "--setenv"; k; v ]) t.env;
      List.concat_map (fun k -> [ "--unsetenv"; k ]) t.unset_env;
      (match t.chdir with None -> [] | Some d -> [ "--chdir"; d ]);
    ]

(* -t           ports opened inside appear on the host, on 127.0.0.1 only unless [lan]
   --host-lo-to-ns-lo  deliver them to the sandbox's loopback, so servers bound to localhost
                work, not just ones bound to 0.0.0.0
   -T           sandbox to host: only the listed ports
   -u, -U, --no-map-gw  no other way from the sandbox back to the host's own services *)
let to_pasta_args net =
  let back =
    match net.host_ports with
    | [] -> "none"
    | ports -> String.concat "," (List.map string_of_int ports)
  in
  [ "--config-net"; "--quiet"; "--host-lo-to-ns-lo" ]
  @ [ "-t"; (if net.lan then "auto" else "127.0.0.1/auto"); "-u"; "none" ]
  @ [ "-T"; back; "-U"; "none"; "--no-map-gw" ]
