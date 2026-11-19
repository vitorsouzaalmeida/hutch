type output = Inherit | Null | Append of string

let rec wait pid =
  match Unix.waitpid [] pid with
  | _, WEXITED code -> code
  | _, WSIGNALED _ -> 128
  | _, WSTOPPED _ -> wait pid
  | exception Unix.Unix_error (EINTR, _, _) -> wait pid

let with_fd path flags f =
  let fd = Unix.openfile path (Unix.O_CLOEXEC :: flags) 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> f fd)

let spawn ?(env = Unix.environment ()) ~output (tool : Tool.t) args =
  let argv = Array.of_list (Filename.basename (tool :> string) :: args) in
  let start stdin out = Unix.create_process_env (tool :> string) argv env stdin out out in
  match output with
  | Inherit -> Unix.create_process_env (tool :> string) argv env Unix.stdin Unix.stdout Unix.stderr
  | Null -> with_fd "/dev/null" [ O_RDWR ] (fun null -> start null null)
  | Append file ->
      with_fd "/dev/null" [ O_RDONLY ] (fun null ->
          with_fd file [ O_WRONLY; O_CREAT; O_APPEND ] (fun log -> start null log))

let run ?env ?(output = Inherit) tool args = wait (spawn ?env ~output tool args)

let exited pid =
  match Unix.waitpid [ WNOHANG ] pid with
  | 0, _ -> false
  | _ -> true
  | exception Unix.Unix_error (ECHILD, _, _) -> true

let exec ~env (tool : Tool.t) args =
  Unix.execve (tool :> string) (Array.of_list (Filename.basename (tool :> string) :: args)) env

let pids () = List.filter_map int_of_string_opt (Array.to_list (Sys.readdir "/proc"))

let cmdline pid =
  match Fs.read_opt (Printf.sprintf "/proc/%d/cmdline" pid) with
  | None | Some "" -> None
  | Some text ->
      let text =
        if String.ends_with ~suffix:"\000" text then String.sub text 0 (String.length text - 1)
        else text
      in
      Some (String.split_on_char '\000' text)

let mine pid =
  match Unix.stat (Printf.sprintf "/proc/%d" pid) with
  | { st_uid; _ } -> st_uid = Unix.getuid ()
  | exception Unix.Unix_error _ -> false

let kill pid signal = try Unix.kill pid signal with Unix.Unix_error (ESRCH, _, _) -> ()

let rec wait_gone ?(interval = 0.1) ~seconds pids =
  match List.filter mine pids with
  | [] -> true
  | _ when seconds <= 0. -> false
  | alive ->
      Unix.sleepf interval;
      wait_gone ~interval ~seconds:(seconds -. interval) alive
