open Cmdliner

let all_tags =
  Arg.(
    value
    @@ flag
    @@ info ~doc:"Download all tagged images in the repository"
         [ "a"; "all-tags" ])

let platform =
  Arg.(
    value
    @@ opt (some string) None
    @@ info ~doc:"Set platform if server is multi-platform capable"
         [ "platform" ])

let image =
  let open Container_image in
  let image = Arg.conv (Image.of_string, Image.pp) in
  Arg.(
    required
    @@ pos 0 (some image) None
    @@ info ~doc:"Download an image from a registry" ~docv:"NAME[:TAG|@DIGEST]"
         [])

let setup =
  let style_renderer = Fmt_cli.style_renderer () in
  Term.(
    const (fun style_renderer level ->
        Fmt_tty.setup_std_outputs ?style_renderer ();
        Logs.set_level level;
        Logs.set_reporter (Logs_fmt.reporter ()))
    $ style_renderer
    $ Logs_cli.level ())

let null_auth ?ip:_ ~host:_ _ =
  Ok None (* Warning: use a real authenticator in your code! *)

let https ~authenticator =
  let tls_config = Tls.Config.client ~authenticator () in
  fun uri raw ->
    let host =
      Uri.host uri
      |> Option.map (fun x -> Domain_name.(host_exn (of_string_exn x)))
    in
    Tls_eio.client_of_flow ?host tls_config raw

let cache env =
  let fs = Eio.Stdenv.fs env in
  let xdg = Xdg.create ~env:Sys.getenv_opt () in
  let root = Eio.Path.(fs / Xdg.cache_dir xdg / "container-image") in
  let cache = Container_image.Cache.v root in
  Container_image.Cache.init cache;
  cache

let fetch () all_tags platform image =
  ignore all_tags;
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  let client =
    Cohttp_eio.Client.make
      ~https:(Some (https ~authenticator:null_auth))
      (Eio.Stdenv.net env)
  in
  let cache = cache env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  Container_image.fetch ~client ~cache ~domain_mgr ?platform image

let list () =
  Fmt.pr "📖 images:\n";
  Eio_main.run @@ fun env ->
  let cache = cache env in
  let images = Container_image.list ~cache in
  List.iter (fun image -> Fmt.pr "%a\n%!" Container_image.Image.pp image) images

(*
    (fun (r, t, i, c, s) -> Fmt.pr "%-25s %-25s %-16s %-14s %s\n" r t i c s)
    [
      ("REPOSITORY", "TAG", "IMAGE ID", "CREATED", "SIZE");
      ( "ocaml/opam",
        "ubuntu-20.04-ocaml-4.14",
        "c583c0b61ae0",
        "6 weeks ago",
        "1.31GB" );
    ]
   *)
let version =
  match Build_info.V1.version () with
  | None -> "n/a"
  | Some v -> Build_info.V1.Version.to_string v

let fetch_cmd =
  Cmd.v
    (Cmd.info "fetch" ~version)
    Term.(const fetch $ setup $ all_tags $ platform $ image)

let list_term = Term.(const list $ setup)
let list_cmd = Cmd.v (Cmd.info "list" ~version) list_term

let cmd =
  Cmd.group ~default:list_term (Cmd.info "image") [ fetch_cmd; list_cmd ]

let () =
  let () = Printexc.record_backtrace true in
  match Cmd.eval ~catch:false cmd with
  | i -> exit i
  | (exception Failure s) | (exception Invalid_argument s) ->
      Fmt.epr "\n%a %s\n%!" Fmt.(styled `Red string) "[ERROR]" s;
      exit Cmd.Exit.cli_error
  | exception e ->
      (*      Printexc.print_backtrace stderr; *)
      Fmt.epr "\n%a\n%!" Fmt.exn e;
      exit Cmd.Exit.some_error
