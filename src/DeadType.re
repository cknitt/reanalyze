/* Adapted from https://github.com/LexiFi/dead_code_analyzer */

open DeadCommon;

let typeDependencies = ref([]);

let addTypeReference = (~posFrom, ~posTo) => {
  if (verbose) {
    Log_.item(
      "addTypeReference %s --> %s@.",
      posFrom |> posToString,
      posTo |> posToString,
    );
  };
  PosHash.addSet(typeReferences, posTo, posFrom);
};

let pathModuleToImplementation = path =>
  switch (path |> List.rev) {
  | [moduleName, ...rest] =>
    [moduleName |> Name.toImplementation, ...rest] |> List.rev
  | [] => path
  };

let pathModuleToInterface = path =>
  switch (path |> List.rev) {
  | [moduleName, ...rest] =>
    [moduleName |> Name.toInterface, ...rest] |> List.rev
  | [] => path
  };

let pathTypeToInterface = path =>
  switch (path) {
  | [typeName, ...rest] => [typeName |> Name.toInterface, ...rest]
  | [] => path
  };

let pathTypeToImplementation = path =>
  switch (path) {
  | [typeName, ...rest] => [typeName |> Name.toImplementation, ...rest]
  | [] => path
  };

let extendTypeDependencies = (loc1: Location.t, loc2: Location.t) =>
  if (loc1.loc_start != loc2.loc_start) {
    if (verbose) {
      Log_.item(
        "extendTypeDependencies %s --> %s@.",
        loc1.loc_start |> posToString,
        loc2.loc_start |> posToString,
      );
    };
    typeDependencies := [(loc1, loc2), ...typeDependencies^];
  };

// Type dependencies between Foo.re and Foo.rei
let addTypeDependenciesAcrossFiles = (~loc, ~typeItemName, path_) => {
  let isInterface = Filename.check_suffix(currentSrc^, "i");
  if (!isInterface) {
    let path_1 = path_ |> pathModuleToInterface;
    let path_2 = path_1 |> pathTypeToInterface;
    let path1 = [typeItemName, ...path_1] |> pathToString;
    let path2 = [typeItemName, ...path_2] |> pathToString;

    switch (Hashtbl.find_opt(fields, path1)) {
    | None =>
      switch (Hashtbl.find_opt(fields, path2)) {
      | None => ()
      | Some(loc2) =>
        extendTypeDependencies(loc, loc2);
        if (!reportTypesDeadOnlyInInterface) {
          extendTypeDependencies(loc2, loc);
        };
      }
    | Some(loc1) =>
      extendTypeDependencies(loc, loc1);
      if (!reportTypesDeadOnlyInInterface) {
        extendTypeDependencies(loc1, loc);
      };
    };
  } else {
    let path_1 = path_ |> pathModuleToImplementation;
    let path_2 = path_1 |> pathTypeToImplementation;
    let path1 = [typeItemName, ...path_1] |> pathToString;
    let path2 = [typeItemName, ...path_2] |> pathToString;
    switch (Hashtbl.find_opt(fields, path1)) {
    | None =>
      switch (Hashtbl.find_opt(fields, path2)) {
      | None => ()
      | Some(loc2) =>
        extendTypeDependencies(loc2, loc);
        if (!reportTypesDeadOnlyInInterface) {
          extendTypeDependencies(loc, loc2);
        };
      }
    | Some(loc1) =>
      extendTypeDependencies(loc1, loc);
      if (!reportTypesDeadOnlyInInterface) {
        extendTypeDependencies(loc, loc1);
      };
    };
  };
};

let addDeclaration =
    (~isInterface, ~typeId: Ident.t, ~typeKind: Types.type_kind) => {
  let path = [
    typeId |> Ident.name |> Name.create(~isInterface),
    ...currentModulePath^ @ [currentModuleName^],
  ];

  // Add type dependencies between implementation and interface in inner module
  let addTypeDependenciesInnerModule = (~loc, ~typeItemName) => {
    let typeNameInterface = typeId |> Ident.name |> Name.create;
    let pathOfName =
      [
        currentModuleName^,
        ...List.rev([typeItemName, typeNameInterface, ...currentModulePath^]),
      ]
      |> List.map(Name.toString)
      |> String.concat(".");
    switch (Hashtbl.find_opt(fields, pathOfName)) {
    | Some(loc2) =>
      extendTypeDependencies(loc, loc2);
      if (!reportTypesDeadOnlyInInterface) {
        extendTypeDependencies(loc2, loc);
      };
    | None => Hashtbl.add(fields, pathOfName, loc)
    };
  };

  let save = (~declKind, ~loc: Location.t, ~typeItemName) => {
    addTypeDeclaration(~declKind, ~path, ~loc, typeItemName);

    path |> addTypeDependenciesAcrossFiles(~loc, ~typeItemName);
    addTypeDependenciesInnerModule(~loc, ~typeItemName);

    Hashtbl.replace(fields, [typeItemName, ...path] |> pathToString, loc);
  };

  switch (typeKind) {
  | Type_record(l, _) =>
    List.iter(
      ({Types.ld_id, ld_loc}) => {
        let typeItemName = Ident.name(ld_id) |> Name.create;
        save(~declKind=RecordLabel, ~loc=ld_loc, ~typeItemName);
      },
      l,
    )
  | Type_variant(l) =>
    List.iter(
      ({Types.cd_id, cd_loc}) => {
        let typeItemName = Ident.name(cd_id) |> Name.create;
        save(~declKind=VariantCase, ~loc=cd_loc, ~typeItemName);
      },
      l,
    )
  | _ => ()
  };
};