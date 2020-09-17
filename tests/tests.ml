(** The protocol for communicating between the hello client and server.
    There's a single RPC call exposed, which lets you send and receive a
    string.

    The [bin_query] and [bin_response] arguments are values that contain logic
    for binary serialization of the query and response types, in this case,
    both strings.

    The version number is used when you want to mint new versions of an RPC
    without disturbing older versions. *)

open Alcotest_lwt
open Lwt
open Lwt_rpc_async

let hello_rpc =
  Protocol.create
    ~name:"hello-world"
    ~version:0
    ~bin_query:Bin_prot.Type_class.bin_string
    ~bin_response:Bin_prot.Type_class.bin_string
;;

let say_hello =
  Client.with_rpc_conn (fun conn ->
      Client.dispatch hello_rpc conn "Hello from LWT,"
      >|= fun response -> Printf.printf "%s\n%!" response)
;;

let callback _input _output = return ()

let spawn_server ~port ~host () =
  let inet_addr = Unix.inet_addr_of_string host in
  let sockaddr = Unix.ADDR_INET (inet_addr, port) in
  Server.init ~sockaddr ~timeout:(Some 30000) callback
;;

let test_hello _switch () =
  (* Alcotest.(check int) "events" 1348 123 *)
  say_hello ~port:8124 ~host:"127.0.0.1"
;;

let () =
  Logs.set_reporter (Logs.format_reporter ());
  Logs.set_level (Some Logs.Debug);
  Lwt_main.run
  @@ run
       "Lwt RPC Async"
       [ "client-server", [ test_case "hello" `Quick test_hello ] ]
;;
