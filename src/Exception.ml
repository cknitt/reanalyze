let posToString = Common.posToString

module LocSet = Common.LocSet

module Values = struct
  let valueBindingsTable =
    (Hashtbl.create 15 : (string, (string, Exceptions.t) Hashtbl.t) Hashtbl.t)

  let currentFileTable = ref (Hashtbl.create 1)

  let add ~name exceptions =
    let path = (name |> Name.create) :: (ModulePath.getCurrent ()).path in
    Hashtbl.replace !currentFileTable (path |> Common.Path.toString) exceptions

  let getFromModule ~moduleName ~modulePath (path_ : Common.Path.t) =
    let name = path_ @ modulePath |> Common.Path.toString in
    match
      Hashtbl.find_opt valueBindingsTable (String.capitalize_ascii moduleName)
    with
    | Some tbl -> Hashtbl.find_opt tbl name
    | None -> (
      match
        Hashtbl.find_opt valueBindingsTable
          (String.uncapitalize_ascii moduleName)
      with
      | Some tbl -> Hashtbl.find_opt tbl name
      | None -> None)

  let rec findLocal ~moduleName ~modulePath path =
    match path |> getFromModule ~moduleName ~modulePath with
    | Some exceptions -> Some exceptions
    | None -> (
      match modulePath with
      | [] -> None
      | _ :: restModulePath ->
        path |> findLocal ~moduleName ~modulePath:restModulePath)

  let findPath ~moduleName ~modulePath path =
    let findExternal ~externalModuleName ~pathRev =
      pathRev |> List.rev
      |> getFromModule
           ~moduleName:(externalModuleName |> Name.toString)
           ~modulePath:[]
    in
    match path |> findLocal ~moduleName ~modulePath with
    | None -> (
      (* Search in another file *)
      match path |> List.rev with
      | externalModuleName :: pathRev -> (
        match (findExternal ~externalModuleName ~pathRev, pathRev) with
        | (Some _ as found), _ -> found
        | None, externalModuleName2 :: pathRev2
          when !Common.Cli.cmtCommand && pathRev2 <> [] ->
          (* Simplistic namespace resolution for dune namespace: skip the root of the path *)
          findExternal ~externalModuleName:externalModuleName2 ~pathRev:pathRev2
        | None, _ -> None)
      | [] -> None)
    | Some exceptions -> Some exceptions

  let newCmt () =
    currentFileTable := Hashtbl.create 15;
    Hashtbl.replace valueBindingsTable !Common.currentModule !currentFileTable
end

module Event = struct
  type kind =
    | Catches of t list (* with | E => ... *)
    | Call of {callee : Common.Path.t; modulePath : Common.Path.t} (* foo() *)
    | DoesNotRaise of t list (* DoesNotRaise(events) where events come from an expression *)
    | Raises  (** raise E *)

  and t = {exceptions : Exceptions.t; kind : kind; loc : CL.Location.t}

  let rec print ppf event =
    match event with
    | {kind = Call {callee; modulePath}; exceptions; loc} ->
      Format.fprintf ppf "%s Call(%s, modulePath:%s) %a@."
        (loc.loc_start |> posToString)
        (callee |> Common.Path.toString)
        (modulePath |> Common.Path.toString)
        (Exceptions.pp ~exnTable:None)
        exceptions
    | {kind = DoesNotRaise nestedEvents; loc} ->
      Format.fprintf ppf "%s DoesNotRaise(%a)@."
        (loc.loc_start |> posToString)
        (fun ppf () ->
          nestedEvents |> List.iter (fun e -> Format.fprintf ppf "%a " print e))
        ()
    | {kind = Raises; exceptions; loc} ->
      Format.fprintf ppf "%s raises %a@."
        (loc.loc_start |> posToString)
        (Exceptions.pp ~exnTable:None)
        exceptions
    | {kind = Catches nestedEvents; exceptions; loc} ->
      Format.fprintf ppf "%s Catches exceptions:%a nestedEvents:%a@."
        (loc.loc_start |> posToString)
        (Exceptions.pp ~exnTable:None)
        exceptions
        (fun ppf () ->
          nestedEvents |> List.iter (fun e -> Format.fprintf ppf "%a " print e))
        ()

  let combine ~moduleName events =
    if !Common.Cli.debug then (
      Log_.item "@.";
      Log_.item "Events combine: #events %d@." (events |> List.length));
    let exnTable = Hashtbl.create 1 in
    let extendExnTable exn loc =
      match Hashtbl.find_opt exnTable exn with
      | Some locSet -> Hashtbl.replace exnTable exn (LocSet.add loc locSet)
      | None -> Hashtbl.replace exnTable exn (LocSet.add loc LocSet.empty)
    in
    let shrinkExnTable exn loc =
      match Hashtbl.find_opt exnTable exn with
      | Some locSet -> Hashtbl.replace exnTable exn (LocSet.remove loc locSet)
      | None -> ()
    in
    let rec loop exnSet events =
      match events with
      | ({kind = Raises; exceptions; loc} as ev) :: rest ->
        if !Common.Cli.debug then Log_.item "%a@." print ev;
        exceptions |> Exceptions.iter (fun exn -> extendExnTable exn loc);
        loop (Exceptions.union exnSet exceptions) rest
      | ({kind = Call {callee; modulePath}; loc} as ev) :: rest ->
        if !Common.Cli.debug then Log_.item "%a@." print ev;
        let exceptions =
          match callee |> Values.findPath ~moduleName ~modulePath with
          | Some exceptions -> exceptions
          | _ -> (
            match ExnLib.find callee with
            | Some exceptions -> exceptions
            | None -> Exceptions.empty)
        in
        exceptions |> Exceptions.iter (fun exn -> extendExnTable exn loc);
        loop (Exceptions.union exnSet exceptions) rest
      | ({kind = DoesNotRaise nestedEvents; loc} as ev) :: rest ->
        if !Common.Cli.debug then Log_.item "%a@." print ev;
        let nestedExceptions = loop Exceptions.empty nestedEvents in
        (if Exceptions.isEmpty nestedExceptions (* catch-all *) then
         let name =
           match nestedEvents with
           | {kind = Call {callee}} :: _ -> callee |> Common.Path.toString
           | _ -> "expression"
         in
         Log_.warning ~loc ~name:"Exception Analysis" (fun ppf () ->
             Format.fprintf ppf
               "@{<info>%s@} does not raise and is annotated with redundant \
                @doesNotRaise"
               name));
        loop exnSet rest
      | ({kind = Catches nestedEvents; exceptions} as ev) :: rest ->
        if !Common.Cli.debug then Log_.item "%a@." print ev;
        if Exceptions.isEmpty exceptions then loop exnSet rest
        else
          let nestedExceptions = loop Exceptions.empty nestedEvents in
          let newRaises = Exceptions.diff nestedExceptions exceptions in
          exceptions
          |> Exceptions.iter (fun exn ->
                 nestedEvents
                 |> List.iter (fun event -> shrinkExnTable exn event.loc));
          loop (Exceptions.union exnSet newRaises) rest
      | [] -> exnSet
    in
    let exnSet = loop Exceptions.empty events in
    (exnSet, exnTable)
end

module Checks = struct
  type check = {
    events : Event.t list;
    loc : CL.Location.t;
    locFull : CL.Location.t;
    moduleName : string;
    name : string;
    exceptions : Exceptions.t;
  }

  type t = check list

  let checks = (ref [] : t ref)

  let add ~events ~exceptions ~loc ?(locFull = loc) ~moduleName name =
    checks := {events; exceptions; loc; locFull; moduleName; name} :: !checks

  let doCheck {events; exceptions; loc; locFull; moduleName; name} =
    let raiseSet, exnTable = events |> Event.combine ~moduleName in
    let missingAnnotations = Exceptions.diff raiseSet exceptions in
    let redundantAnnotations = Exceptions.diff exceptions raiseSet in
    if not (Exceptions.isEmpty missingAnnotations) then (
      let raisesTxt =
        Format.asprintf "%a" (Exceptions.pp ~exnTable:(Some exnTable)) raiseSet
      in
      let missingTxt =
        Format.asprintf "%a" (Exceptions.pp ~exnTable:None) missingAnnotations
      in
      Log_.warning ~loc ~name:"Exception Analysis" ~notClosed:true
        (fun ppf () ->
          Format.fprintf ppf
            "@{<info>%s@} might raise %s and is not annotated with @raises(%s)"
            name raisesTxt missingTxt);
      if !Common.Cli.json then (
        EmitJson.emitAnnotate ~action:"Add @raises annotation"
          ~pos:(EmitJson.locToPos locFull)
          ~text:(Format.asprintf "@raises(%s)\\n" missingTxt);
        EmitJson.emitClose ()));
    if not (Exceptions.isEmpty redundantAnnotations) then
      Log_.warning ~loc ~name:"Exception Analysis" (fun ppf () ->
          let raisesDescription ppf () =
            if raiseSet |> Exceptions.isEmpty then
              Format.fprintf ppf "raises nothing"
            else
              Format.fprintf ppf "might raise %a"
                (Exceptions.pp ~exnTable:(Some exnTable))
                raiseSet
          in
          Format.fprintf ppf
            "@{<info>%s@} %a and is annotated with redundant @raises(%a)" name
            raisesDescription ()
            (Exceptions.pp ~exnTable:None)
            redundantAnnotations)

  let doChecks () = !checks |> List.rev |> List.iter doCheck
end

let traverseAst () =
  ModulePath.init ();
  let super = CL.Tast_mapper.default in
  let currentId = ref "" in
  let currentEvents = ref [] in
  let exceptionsOfPatterns patterns =
    patterns
    |> List.fold_left
         (fun acc desc ->
           match desc with
           | CL.Typedtree.Tpat_construct _ ->
             Exceptions.add (Exn.fromLid (Compat.unboxPatCstrTxt desc)) acc
           | _ -> acc)
         Exceptions.empty
  in
  let iterExpr self e = self.CL.Tast_mapper.expr self e |> ignore in
  let iterExprOpt self eo =
    match eo with None -> () | Some e -> e |> iterExpr self
  in
  let iterPat self p = self.CL.Tast_mapper.pat self p |> ignore in
  let iterCases self cases =
    cases
    |> List.iter (fun case ->
           case.CL.Typedtree.c_lhs |> iterPat self;
           case.c_guard |> iterExprOpt self;
           case.c_rhs |> iterExpr self)
  in
  let isRaise s =
    s = "Pervasives.raise"
    || s = "Pervasives.raise_notracee"
    || s = "Stdlib.raise"
    || s = "Stdlib.raise_notracee"
  in
  let raiseArgs args =
    match args with
    | [(_, Some {CL.Typedtree.exp_desc = Texp_construct ({txt}, _, _)})] ->
      [Exn.fromLid txt] |> Exceptions.fromList
    | [(_, Some {CL.Typedtree.exp_desc = Texp_ident _})] ->
      [Exn.fromString "genericException"] |> Exceptions.fromList
    | _ -> [Exn.fromString "TODO_from_raise1"] |> Exceptions.fromList
  in
  let doesNotRaise attributes =
    attributes
    |> Annotation.getAttributePayload (fun s ->
           s = "doesNotRaise" || s = "doesnotraise" || s = "DoesNoRaise"
           || s = "doesNotraise" || s = "doNotRaise" || s = "donotraise"
           || s = "DoNoRaise" || s = "doNotraise")
    <> None
  in
  let expr (self : CL.Tast_mapper.mapper) (expr : CL.Typedtree.expression) =
    let loc = expr.exp_loc in
    let isDoesNoRaise = expr.exp_attributes |> doesNotRaise in
    let oldEvents = !currentEvents in
    if isDoesNoRaise then currentEvents := [];
    (match expr.exp_desc with
    | Texp_ident (callee_, _, _) ->
      let callee =
        callee_ |> Common.Path.fromPathT |> ModulePath.resolveAlias
      in
      let calleeName = callee |> Common.Path.toString in
      if calleeName |> isRaise then
        Log_.warning ~loc ~name:"Exception Analysis" (fun ppf () ->
            Format.fprintf ppf
              "@{<info>%s@} can be analyzed only if called direclty" calleeName);
      currentEvents :=
        {
          Event.exceptions = Exceptions.empty;
          loc;
          kind = Call {callee; modulePath = (ModulePath.getCurrent ()).path};
        }
        :: !currentEvents
    | Texp_apply
        ( {exp_desc = Texp_ident (atat, _, _)},
          [(_lbl1, Some {exp_desc = Texp_ident (callee, _, _)}); arg] )
      when (* raise @@ Exn(...) *)
           atat |> CL.Path.name = "Pervasives.@@"
           && callee |> CL.Path.name |> isRaise ->
      let exceptions = [arg] |> raiseArgs in
      currentEvents := {Event.exceptions; loc; kind = Raises} :: !currentEvents;
      arg |> snd |> iterExprOpt self
    | Texp_apply
        ( {exp_desc = Texp_ident (atat, _, _)},
          [arg; (_lbl1, Some {exp_desc = Texp_ident (callee, _, _)})] )
      when (*  Exn(...) |> raise *)
           atat |> CL.Path.name = "Pervasives.|>"
           && callee |> CL.Path.name |> isRaise ->
      let exceptions = [arg] |> raiseArgs in
      currentEvents := {Event.exceptions; loc; kind = Raises} :: !currentEvents;
      arg |> snd |> iterExprOpt self
    | Texp_apply (({exp_desc = Texp_ident (callee, _, _)} as e), args) ->
      let calleeName = CL.Path.name callee in
      if calleeName |> isRaise then
        let exceptions = args |> raiseArgs in
        currentEvents :=
          {Event.exceptions; loc; kind = Raises} :: !currentEvents
      else e |> iterExpr self;
      args |> List.iter (fun (_, eOpt) -> eOpt |> iterExprOpt self)
    | Texp_match _ ->
      let e, cases, partial = Compat.getTexpMatch expr.exp_desc in
      let exceptionPatterns = expr.exp_desc |> Compat.texpMatchGetExceptions in
      let exceptions = exceptionPatterns |> exceptionsOfPatterns in
      if exceptionPatterns <> [] then (
        let oldEvents = !currentEvents in
        currentEvents := [];
        e |> iterExpr self;
        currentEvents :=
          {Event.exceptions; loc; kind = Catches !currentEvents} :: oldEvents)
      else e |> iterExpr self;
      cases |> iterCases self;
      if partial = Partial then
        currentEvents :=
          {
            Event.exceptions = [Exn.matchFailure] |> Exceptions.fromList;
            loc;
            kind = Raises;
          }
          :: !currentEvents
    | Texp_try (e, cases) ->
      let exceptions =
        cases
        |> List.map (fun case -> case.CL.Typedtree.c_lhs.pat_desc)
        |> exceptionsOfPatterns
      in
      let oldEvents = !currentEvents in
      currentEvents := [];
      e |> iterExpr self;
      currentEvents :=
        {Event.exceptions; loc; kind = Catches !currentEvents} :: oldEvents;
      cases |> iterCases self
    | _ -> super.expr self expr |> ignore);
    (if isDoesNoRaise then
     let nestedEvents = !currentEvents in
     currentEvents :=
       {
         Event.exceptions = Exceptions.empty;
         loc;
         kind = DoesNotRaise nestedEvents;
       }
       :: oldEvents);
    expr
  in
  let getExceptionsFromAnnotations attributes =
    let raisesAnnotationPayload =
      attributes
      |> Annotation.getAttributePayload (fun s -> s = "raises" || s = "raise")
    in
    let rec getExceptions payload =
      match payload with
      | Annotation.StringPayload s -> [Exn.fromString s] |> Exceptions.fromList
      | Annotation.ConstructPayload s when s <> "::" ->
        [Exn.fromString s] |> Exceptions.fromList
      | Annotation.IdentPayload s ->
        [Exn.fromString (s |> CL.Longident.flatten |> String.concat ".")]
        |> Exceptions.fromList
      | Annotation.TuplePayload tuple ->
        tuple
        |> List.map (fun payload ->
               payload |> getExceptions |> Exceptions.toList)
        |> List.concat |> Exceptions.fromList
      | _ -> Exceptions.empty
    in
    match raisesAnnotationPayload with
    | None -> Exceptions.empty
    | Some payload -> payload |> getExceptions
  in
  let toplevelEval (self : CL.Tast_mapper.mapper)
      (expr : CL.Typedtree.expression) attributes =
    let oldId = !currentId in
    let oldEvents = !currentEvents in
    let name = "Toplevel expression" in
    currentId := name;
    currentEvents := [];
    let moduleName = !Common.currentModule in
    self.expr self expr |> ignore;
    Checks.add ~events:!currentEvents
      ~exceptions:(getExceptionsFromAnnotations attributes)
      ~loc:expr.exp_loc ~moduleName name;
    currentId := oldId;
    currentEvents := oldEvents
  in
  let structure_item (self : CL.Tast_mapper.mapper)
      (structureItem : CL.Typedtree.structure_item) =
    let oldModulePath = ModulePath.getCurrent () in
    (match structureItem.str_desc with
    | Tstr_eval (expr, attributes) -> toplevelEval self expr attributes
    | Tstr_module {mb_id; mb_loc} ->
      ModulePath.setCurrent
        {
          oldModulePath with
          loc = mb_loc;
          path =
            (mb_id |> Compat.moduleIdName |> Name.create) :: oldModulePath.path;
        }
    | _ -> ());
    let result = super.structure_item self structureItem in
    ModulePath.setCurrent oldModulePath;
    (match structureItem.str_desc with
    | Tstr_module {mb_id; mb_expr = {mod_desc = Tmod_ident (path_, _lid)}} ->
      ModulePath.addAlias
        ~name:(mb_id |> Compat.moduleIdName |> Name.create)
        ~path:(path_ |> Common.Path.fromPathT)
    | _ -> ());
    result
  in
  let value_binding (self : CL.Tast_mapper.mapper)
      (vb : CL.Typedtree.value_binding) =
    let oldId = !currentId in
    let oldEvents = !currentEvents in
    let isFunction =
      match vb.vb_expr.exp_desc with Texp_function _ -> true | _ -> false
    in
    let isToplevel = !currentId = "" in
    let processBinding name =
      currentId := name;
      currentEvents := [];
      let exceptionsFromAnnotations =
        getExceptionsFromAnnotations vb.vb_attributes
      in
      exceptionsFromAnnotations |> Values.add ~name;
      let res = super.value_binding self vb in
      let moduleName = !Common.currentModule in
      let path = [name |> Name.create] in
      let exceptions =
        match
          path
          |> Values.findPath ~moduleName
               ~modulePath:(ModulePath.getCurrent ()).path
        with
        | Some exceptions -> exceptions
        | _ -> Exceptions.empty
      in
      Checks.add ~events:!currentEvents ~exceptions ~loc:vb.vb_pat.pat_loc
        ~locFull:vb.vb_loc ~moduleName name;
      currentId := oldId;
      currentEvents := oldEvents;
      res
    in
    match vb.vb_pat.pat_desc with
    | Tpat_any when isToplevel && not vb.vb_loc.loc_ghost -> processBinding "_"
    | Tpat_construct _
      when isToplevel && (not vb.vb_loc.loc_ghost)
           && Compat.unboxPatCstrTxt vb.vb_pat.pat_desc
              = CL.Longident.Lident "()" ->
      processBinding "()"
    | Tpat_var (id, {loc = {loc_ghost}})
      when (isFunction || isToplevel) && (not loc_ghost)
           && not vb.vb_loc.loc_ghost ->
      processBinding (id |> CL.Ident.name)
    | _ -> super.value_binding self vb
  in
  let open CL.Tast_mapper in
  {super with expr; value_binding; structure_item}

let processStructure (structure : CL.Typedtree.structure) =
  let traverseAst = traverseAst () in
  structure |> traverseAst.structure traverseAst |> ignore

let processCmt (cmt_infos : CL.Cmt_format.cmt_infos) =
  match cmt_infos.cmt_annots with
  | Interface _ -> ()
  | Implementation structure ->
    Values.newCmt ();
    structure |> processStructure
  | _ -> ()

let reportResults ~ppf:_ = Checks.doChecks ()
