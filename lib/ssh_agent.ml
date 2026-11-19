(* Each project has its own ssh-agent on the host, holding only the keys given to it with
   `hutch ssh-add`. Its socket is the one thing of the host's /run that a sandbox gets. Keys are
   added with confirmation, so every use from inside asks on the host first. *)

let env_with pairs =
  let names = List.map fst pairs in
  let kept entry =
    not (List.exists (fun name -> String.starts_with ~prefix:(name ^ "=") entry) names)
  in
  Array.of_list
    (List.map (fun (k, v) -> k ^ "=" ^ v) pairs
    @ List.filter kept (Array.to_list (Unix.environment ())))

let tools c =
  Option.bind (Tool.find_opt c "ssh-agent") (fun agent ->
      Option.map (fun add -> (agent, add)) (Tool.find_opt c "ssh-add"))

let ensure (c : Config.t) (p : Project.t) =
  match tools c with
  | None -> false
  | Some (agent, add) ->
      let env = env_with [ ("SSH_AUTH_SOCK", p.agent) ] in
      (* ssh-add exits with 2 when no agent listens on the socket. *)
      if Proc.run ~env ~output:Null add [ "-l" ] = 2 then begin
        Fs.remove p.agent;
        let askpass = match c.askpass with Some a -> [ ("SSH_ASKPASS", a) ] | None -> [] in
        ignore (Proc.run ~env:(env_with askpass) ~output:Null agent [ "-a"; p.agent ])
      end;
      Fs.kind p.agent = Fs.Other

let add (c : Config.t) (p : Project.t) keys =
  if not (ensure c p) then Msg.fail "hutch needs ssh-agent and ssh-add on the host for this";
  if c.askpass = None then
    Msg.info
      "no askpass program is set (ssh.askpass in config.toml, or SSH_ASKPASS): uses of this key \
       can't be confirmed and will be refused";
  Proc.run ~env:(env_with [ ("SSH_AUTH_SOCK", p.agent) ]) (Tool.find c "ssh-add") ("-c" :: keys)

let stop (p : Project.t) =
  let ours pid = Proc.mine pid && Proc.cmdline pid = Some [ "ssh-agent"; "-a"; p.agent ] in
  List.iter (fun pid -> Proc.kill pid Sys.sigterm) (List.filter ours (Proc.pids ()));
  Fs.remove p.agent
