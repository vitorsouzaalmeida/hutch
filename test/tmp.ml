open Hutch

let counter = ref 0

let with_dir f =
  incr counter;
  let name = Printf.sprintf "hutch-test.%d.%d" (Unix.getpid ()) !counter in
  let dir = Filename.concat (Unix.realpath (Filename.get_temp_dir_name ())) name in
  Fs.remove_tree dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> Fs.remove_tree dir) (fun () -> f dir)

let env pairs name = List.assoc_opt name pairs

let config ?(path = "/usr/bin") dir =
  let sub name = Filename.concat dir name in
  Config.make ~settings:Config.no_settings
    ~getenv:
      (env
         [
           ("HOME", sub "home");
           ("HUTCH_PROJECTS", sub "projects");
           ("HUTCH_SB_ROOT", sub "sb");
           ("HUTCH_STATE", sub "state");
           ("HUTCH_CONFIG", sub "config");
           ("PATH", path);
         ])

let touch ?(perm = 0o644) path =
  Fs.mkdir_p (Filename.dirname path);
  Fs.write ~perm path ""

let raises_error name f =
  match f () with
  | _ -> Alcotest.failf "%s: expected a Msg.Error" name
  | exception Msg.Error _ -> ()
