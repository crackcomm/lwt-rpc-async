(* open Bin_prot.Size *)
open Lwt
open Bin_prot.Std

module Lwt_bytes = struct
  include Lwt_bytes

  let bin_shape_t = Bin_prot.Shape.bin_shape_bigstring
  let bin_size_t = Bin_prot.Size.bin_size_bigstring
  let bin_write_t = Bin_prot.Write.bin_write_bigstring
  let bin_read_t = Bin_prot.Read.bin_read_bigstring
end

type ('q, 'r) rpc =
  { name : string
  ; version : int
  ; bin_query : 'q Bin_prot.Type_class.t
  ; bin_response : 'r Bin_prot.Type_class.t
  }

module Result = struct
  type ('ok, 'error) t =
    | Ok of 'ok
    | Error of 'error
  [@@deriving bin_io]
end

module Sexp = struct
  type t =
    | Atom of string
    | List of t list
  [@@deriving bin_io]
end

module Rpc_error = struct
  type t =
    | Bin_io_exn of Sexp.t
    | Connection_closed
    | Write_error of Sexp.t
    | Uncaught_exn of Sexp.t
    | Unimplemented_rpc of string * [ `Version of int ]
    | Unknown_query_id of int64
  [@@deriving bin_io]
end

module Rpc_result = struct
  type 'a t = ('a, Rpc_error.t) Result.t [@@deriving bin_io]
end

module Query = struct
  type t =
    { tag : string
    ; version : int
    ; id : int64
    ; data : Lwt_bytes.t
    }
  [@@deriving bin_io]
end

module Response = struct
  type t =
    { id : int64
    ; data : Lwt_bytes.t Rpc_result.t
    }
  [@@deriving bin_io]
end

module Message = struct
  type t =
    | Heartbeat
    | Query of Query.t
    | Response of Response.t
  [@@deriving bin_io]
end

(*open Bin_prot.Type_class*)
(*open Lwt*)

module Protocol = struct
  open Bin_prot.Type_class

  let len_len = 8
  let last_id = ref Int64.zero

  let gen_id () =
    (last_id := Int64.(add !last_id one));
    !last_id
  ;;

  let write_bin_prot writer v =
    let len = writer.size v in
    Printf.eprintf "v len: %d\n%!" len;
    let tot_len = len + len_len in
    let buf = Lwt_bytes.create tot_len in
    Printf.eprintf "buf length: %d\n%!" (Lwt_bytes.length buf);
    let pos_len = Bin_prot.Write.bin_write_int_64bit buf ~pos:0 len in
    Printf.eprintf "pos_len: %d\n%!" pos_len;
    let pos = writer.write buf ~pos:pos_len v in
    if pos <> tot_len
    then Lwt.fail (Failure "write_bin_prot")
    else Lwt.return buf
  ;;

  let create ~name ~version ~bin_query ~bin_response =
    { name; version; bin_query; bin_response }
  ;;
end

module Client = struct
  open Bin_prot.Type_class

  let dispatch rpc socket_fd mesg =
    Lwt.(
      let data = Bin_prot.Utils.bin_dump rpc.bin_query.writer mesg in
      let query =
        { Query.tag = rpc.name
        ; version = rpc.version
        ; id = Protocol.gen_id ()
        ; data
        }
      in
      Protocol.write_bin_prot Message.bin_writer_t (Message.Query query)
      >>= fun buf ->
      Lwt_bytes.send socket_fd buf 0 (Lwt_bytes.length buf) []
      >>= fun _ ->
      let bufsz = 1024 in
      Lwt_bytes.recv socket_fd buf 0 bufsz []
      >>= fun _ -> return (rpc.bin_response.reader.read buf ~pos_ref:(ref 0)))
  ;;

  let with_rpc_conn f ~port ~host =
    Lwt.(
      let inet_addr = Unix.inet_addr_of_string host in
      let sockaddr = Unix.ADDR_INET (inet_addr, port) in
      let socket_fd = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
      Lwt_unix.connect socket_fd sockaddr
      >>= fun () ->
      f socket_fd
      >>= fun () -> return Lwt_unix.(shutdown socket_fd SHUTDOWN_SEND))
  ;;
end

module Server = struct
  let close (ic, oc) =
    Lwt.(
      catch (fun () -> Lwt_io.close oc) (fun _ -> return ())
      >>= fun () -> catch (fun () -> Lwt_io.close ic) (fun _ -> return ()))
  ;;

  let backlog = 10

  let init_socket sockaddr =
    let open Lwt_unix in
    let sock = socket PF_INET SOCK_STREAM 0 in
    setsockopt sock Unix.SO_REUSEADDR true;
    bind sock sockaddr
    >|= fun () ->
    listen sock backlog;
    sock
  ;;

  let process_accept ~timeout callback (client, _) =
    let input = Lwt_io.of_fd ~mode:Lwt_io.input client in
    let output = Lwt_io.of_fd ~mode:Lwt_io.output client in
    let deferred = callback input output in
    let events =
      match timeout with
      | None -> [ deferred ]
      | Some time -> [ deferred; Lwt_unix.sleep (float_of_int time) ]
    in
    Lwt.on_failure
      (pick events >>= fun () -> close (input, output))
      (fun e -> Logs.err (fun m -> m "%s" (Printexc.to_string e)));
    Logs_lwt.info (fun m -> m "New connection") >>= return
  ;;

  let init ~sockaddr ~timeout callback =
    init_socket sockaddr
    >>= fun socket ->
    let rec loop () =
      Lwt_unix.accept socket >>= process_accept ~timeout callback >>= loop
    in
    loop ()
  ;;
end
