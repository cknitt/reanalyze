type language = Ml | Re | Res

let posLanguage (pos : Lexing.position) =
  if
    Filename.check_suffix pos.pos_fname ".re"
    || Filename.check_suffix pos.pos_fname ".rei"
  then Re
  else if
    Filename.check_suffix pos.pos_fname ".ml"
    || Filename.check_suffix pos.pos_fname ".mli"
  then Ml
  else Res

module Color = struct
  let color_enabled = lazy (Unix.isatty Unix.stdout)

  let forceColor = ref false

  let get_color_enabled () = !forceColor || Lazy.force color_enabled

  type color = Red | Yellow | Magenta | Cyan

  type style = FG of color | Bold | Dim

  let code_of_style = function
    | FG Red -> "31"
    | FG Yellow -> "33"
    | FG Magenta -> "35"
    | FG Cyan -> "36"
    | Bold -> "1"
    | Dim -> "2"

  let style_of_tag s =
    match s |> Compat.getStringTag with
    | "error" -> [Bold; FG Red]
    | "warning" -> [Bold; FG Magenta]
    | "info" -> [Bold; FG Yellow]
    | "dim" -> [Dim]
    | "filename" -> [FG Cyan]
    | _ -> []

  let ansi_of_tag s =
    let l = style_of_tag s in
    let s = String.concat ";" (List.map code_of_style l) in
    "\027[" ^ s ^ "m"

  let reset_lit = "\027[0m"

  let color_functions =
    Compat.setOpenCloseTag
      (fun s -> if get_color_enabled () then ansi_of_tag s else "")
      (fun _ -> if get_color_enabled () then reset_lit else "")

  let setup () =
    Format.pp_set_mark_tags Format.std_formatter true;
    Compat.pp_set_formatter_tag_functions Format.std_formatter color_functions;
    if not (get_color_enabled ()) then CL.Misc.Color.setup (Some Never);
    (* Print a dummy thing once in the beginning, as otherwise flushing does not work. *)
    CL.Location.print_loc Format.str_formatter CL.Location.none

  let error ppf s = Format.fprintf ppf "@{<error>%s@}" s

  let info ppf s = Format.fprintf ppf "@{<info>%s@}" s
end

module Loc = struct
  let print_loc ppf (loc : CL.Location.t) =
    (* Change the range so it's on a single line.
       In this way, the line number is clickable in vscode. *)
    let startChar = loc.loc_start.pos_cnum - loc.loc_start.pos_bol in
    let endChar = startChar + loc.loc_end.pos_cnum - loc.loc_start.pos_cnum in
    let line = loc.loc_start.pos_lnum in
    let processPos char (pos : Lexing.position) : Lexing.position =
      {
        pos_lnum = line;
        pos_bol = 0;
        pos_cnum = char;
        pos_fname =
          (let open Filename in
          match is_implicit pos.pos_fname with
          | _ when !Common.Cli.ci -> basename pos.pos_fname
          | true -> concat (Sys.getcwd ()) pos.pos_fname
          | false -> pos.pos_fname);
      }
    in
    CL.Location.print_loc ppf
      {
        loc with
        loc_start = loc.loc_start |> processPos startChar;
        loc_end = loc.loc_end |> processPos endChar;
      }

  let print ppf (loc : CL.Location.t) =
    Format.fprintf ppf "@[%a@]" print_loc loc
end

let log x = Format.fprintf Format.std_formatter x

let item x =
  Format.fprintf Format.std_formatter "  ";
  Format.fprintf Format.std_formatter x

module Stats = struct
  let counters = Hashtbl.create 1

  let active = ref true

  let count name =
    if !active then
      match Hashtbl.find_opt counters (name : string) with
      | None -> Hashtbl.add counters name (ref 1)
      | Some cnt -> incr cnt

  let clear () = Hashtbl.clear counters

  let report () =
    if !active then
      let issues, nIssues =
        Hashtbl.fold
          (fun name cnt (issues, nIssues) ->
            ((name, cnt) :: issues, nIssues + !cnt))
          counters ([], 0)
      in
      let sortedIssues =
        issues |> List.sort (fun (n1, _) (n2, _) -> String.compare n1 n2)
      in

      if not !Common.Cli.json then (
        if sortedIssues <> [] then item "@.";
        item "Analysis reported %d issues%s@." nIssues
          (match sortedIssues with
          | [] -> ""
          | _ :: _ ->
            " ("
            ^ (sortedIssues
              |> List.map (fun (name, cnt) -> name ^ ":" ^ string_of_int !cnt)
              |> String.concat ", ")
            ^ ")"))
end

type kind = Warning | Error

let first = ref true

let logKind ~count ~kind ~(loc : CL.Location.t) ~name ~notClosed body =
  if Suppress.filter loc.loc_start then (
    let open Format in
    first := false;
    if count then Stats.count name;
    if !Common.Cli.json then (
      let file = Json.escape loc.loc_start.pos_fname in
      let startLine = loc.loc_start.pos_lnum - 1 in
      let startCharacter = loc.loc_start.pos_cnum - loc.loc_start.pos_bol in
      let endLine = loc.loc_end.pos_lnum - 1 in
      let endCharacter = loc.loc_end.pos_cnum - loc.loc_start.pos_bol in
      let message = Json.escape (asprintf "%a" body ()) in
      EmitJson.emitItem ~name
        ~kind:(match kind with Warning -> "warning" | Error -> "error")
        ~file
        ~range:(startLine, startCharacter, endLine, endCharacter)
        ~message;
      if notClosed = false then EmitJson.emitClose ())
    else
      let color =
        match kind with Warning -> Color.info | Error -> Color.error
      in
      fprintf std_formatter "@[<v 2>@,%a@,%a@,%a@]@." color name Loc.print loc
        body ())

let warning ?(count = true) ?(notClosed = false) ~loc ~name body =
  body |> logKind ~kind:Warning ~count ~loc ~name ~notClosed

let error ~loc ~name body =
  body |> logKind ~kind:Error ~count:true ~loc ~name ~notClosed:false
