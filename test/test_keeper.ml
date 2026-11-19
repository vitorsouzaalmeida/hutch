open Hutch

let config =
  Config.make ~settings:Config.no_settings
    ~getenv:(Tmp.env [ ("HOME", "/h"); ("HUTCH_STATE", "/s") ])

let project = Result.get_ok (Project.of_cwd config ~cwd:"/h/Projects/shop")

let claim =
  Alcotest.testable
    (fun ppf (c : Keeper.claim) ->
      Format.pp_print_string ppf
        (match c with Ours n -> "ours " ^ n | Foreign -> "foreign" | Unrelated -> "unrelated"))
    ( = )

let classify = Keeper.classify config project
let keeper rest = [ "bash"; "-c"; "script" ] @ rest

let test_classify () =
  Alcotest.check claim "the keeper hutch starts" (Ours "n1")
    (classify (keeper (Keeper.args config project ~nonce:"n1")));
  Alcotest.check claim "fewer arguments than a keeper of this instance has" Foreign
    (classify (keeper [ "hutch-keeper"; "shop" ]));
  Alcotest.check claim "another instance" Foreign
    (classify (keeper [ "hutch-keeper"; "shop"; "other-instance"; "n1" ]));
  Alcotest.check claim "another project" Unrelated
    (classify (keeper [ "hutch-keeper"; "other"; config.inst; "n1" ]));
  Alcotest.check claim "bwrap carries the same words, but isn't the keeper" Unrelated
    (classify ([ "bwrap"; "--"; "bash"; "-c"; "script" ] @ Keeper.args config project ~nonce:"n1"));
  Alcotest.check claim "anything else" Unrelated (classify [ "sleep"; "1" ])

let test_nonce () =
  let a = Keeper.nonce () and b = Keeper.nonce () in
  Alcotest.(check int) "128 bits in hex" 32 (String.length a);
  Alcotest.(check bool) "fresh" false (a = b)

let test_record () =
  Tmp.with_dir @@ fun dir ->
  let c = Tmp.config dir in
  let p = Result.get_ok (Project.of_cwd c ~cwd:(Filename.concat c.projects "shop")) in
  Fs.mkdir_p c.state;
  Alcotest.(check bool) "nothing recorded" true (Keeper.current c p = None);
  Keeper.record p { pid = Unix.getpid (); nonce = "n1" };
  Alcotest.(check bool)
    "a process that isn't the keeper is not trusted" true
    (Keeper.current c p = None);
  Fs.write p.state_file "garbage";
  Alcotest.(check bool) "an unreadable record" true (Keeper.current c p = None)

let suite =
  [
    ( "keeper",
      [
        Alcotest.test_case "classify" `Quick test_classify;
        Alcotest.test_case "nonce" `Quick test_nonce;
        Alcotest.test_case "record" `Quick test_record;
      ] );
  ]
