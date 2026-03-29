open OUnit
open GapiMonad

module File = GapiDriveV3Model.File

let session =
  {
    GapiConversation.Session.curl = GapiCurl.Initialized;
    config = GapiConfig.default;
    auth = GapiConversation.Session.NoAuth;
    cookies = [];
    etag = "";
  }

let run_session m = fst (m session)

let dummy_cache =
  {
    CacheData.cache_dir = "/tmp";
    db_path = "/tmp/test-cache.db";
    busy_timeout = 0;
    in_memory = true;
    autosaving_interval = 0;
  }

let default_runtime ?(config = Config.default) ?(mountpoint_path = "/mnt/gd")
    ?(skip_trash = false) () =
  {
    DriveMutations.cache = dummy_cache;
    config;
    mountpoint_path;
    skip_trash;
  }

module FakePorts = struct
  let trace = ref []
  let resources = Hashtbl.create 32
  let remote_create_calls = ref []
  let remote_update_calls = ref []
  let remote_delete_calls = ref []
  let children_present = ref false
  let next_id = ref 1L

  let reset () =
    trace := [];
    remote_create_calls := [];
    remote_update_calls := [];
    remote_delete_calls := [];
    children_present := false;
    next_id := 1L;
    Hashtbl.reset resources

  let record event = trace := !trace @ [ event ]
  let key path trashed = Printf.sprintf "%b:%s" trashed path

  let add_resource resource =
    let trashed = Option.default false resource.CacheData.Resource.trashed in
    Hashtbl.replace resources (key resource.CacheData.Resource.path trashed)
      resource

  let find_resource path trashed =
    try Some (Hashtbl.find resources (key path trashed)) with Not_found -> None

  let find_by_remote_id remote_id =
    Hashtbl.to_seq_values resources
    |> List.of_seq
    |> List.find_opt (fun resource ->
           resource.CacheData.Resource.remote_id = Some remote_id)

  let server_file_of_resource ?(trashed = false) resource =
    let now = GapiDate.now () in
    {
      File.empty with
      id = Option.get resource.CacheData.Resource.remote_id;
      name = Option.default "" resource.CacheData.Resource.name;
      mimeType = Option.default "" resource.CacheData.Resource.mime_type;
      createdTime = now;
      modifiedTime = now;
      viewedByMeTime = now;
      size = Option.default 0L resource.CacheData.Resource.size;
      trashed;
      explicitlyTrashed = trashed;
      version = Option.default 1L resource.CacheData.Resource.version;
      capabilities = { File.Capabilities.empty with canEdit = true };
      appProperties = [];
    }

  let max_link_target_length = Drive.max_link_target_length
  let json_length = Drive.json_length
  let is_lost_and_found = Drive.is_lost_and_found
  let get_path_in_cache = Drive.get_path_in_cache
  let is_filesystem_read_only () = false
  let create_resource = Drive.create_resource
  let update_resource_from_file = Drive.update_resource_from_file

  let get_resource path trashed =
    match find_resource path trashed with
    | Some resource ->
        record ("get_resource:" ^ path ^ ":" ^ string_of_bool trashed);
        SessionM.return resource
    | None -> Utils.raise_m DriveMutations.File_not_found

  let build_resource_keys_header_from_resource =
    Drive.build_resource_keys_header_from_resource

  let insert_resource_into_cache ?state ?link_target _cache resource file =
    let resource =
      update_resource_from_file ?state ?link_target resource file
    in
    let inserted = { resource with CacheData.Resource.id = !next_id } in
    next_id := Int64.succ !next_id;
    add_resource inserted;
    record ("insert:" ^ inserted.CacheData.Resource.path);
    inserted

  let update_cached_resource _cache resource =
    Hashtbl.remove resources (key resource.CacheData.Resource.path false);
    Hashtbl.remove resources (key resource.CacheData.Resource.path true);
    add_resource resource;
    record ("update:" ^ resource.CacheData.Resource.path)

  let delete_cached_resource resource =
    let path = resource.CacheData.Resource.path in
    Hashtbl.remove resources (key path false);
    Hashtbl.remove resources (key path true);
    record ("delete_cached:" ^ path)

  let delete_all_with_parent_path _cache parent_path trashed =
    record
      (Printf.sprintf "delete_children:%s:%b" parent_path trashed)

  let trash_all_with_parent_path _cache parent_path =
    record ("trash_children:" ^ parent_path)

  let invalidate_trash_bin _cache = record "invalidate_trash_bin"

  let delete_not_found_resource_with_path _cache path =
    record ("delete_not_found:" ^ path)

  let remote_create file =
    remote_create_calls := !remote_create_calls @ [ file ];
    record ("remote_create:" ^ file.File.name);
    let now = GapiDate.now () in
    let remote_id = "rid-" ^ string_of_int (List.length !remote_create_calls) in
    let created_file =
      {
        file with
        File.id = remote_id;
        createdTime = now;
        modifiedTime = now;
        viewedByMeTime = now;
        size = 0L;
        trashed = false;
        explicitlyTrashed = false;
        version = 1L;
        capabilities = { File.Capabilities.empty with canEdit = true };
      }
    in
    SessionM.return created_file

  let remote_update ~custom_headers:_ ~fileId file_patch =
    remote_update_calls := !remote_update_calls @ [ (fileId, file_patch) ];
    record ("remote_update:" ^ fileId);
    let file =
      match find_by_remote_id fileId with
      | Some resource ->
          server_file_of_resource ~trashed:file_patch.File.trashed resource
      | None ->
          {
            File.empty with
            id = fileId;
            trashed = file_patch.File.trashed;
            explicitlyTrashed = file_patch.File.trashed;
          }
    in
    SessionM.return file

  let remote_delete ~custom_headers:_ ~fileId =
    remote_delete_calls := !remote_delete_calls @ [ fileId ];
    record ("remote_delete:" ^ fileId);
    SessionM.return ()

  let check_if_empty_remote remote_id is_folder _trashed =
    record
      (Printf.sprintf "check_empty:%s:%b" remote_id is_folder);
    if is_folder && !children_present then raise DriveMutations.Directory_not_empty
    else SessionM.return ()
end

module Mutations = DriveMutations.Make (FakePorts)

let make_resource ?(trashed = false) ?(mime_type = Drive.folder_mime_type)
    ?(name = "node") path remote_id =
  let resource = Drive.create_resource path in
  {
    resource with
    CacheData.Resource.id = 1L;
    remote_id = Some remote_id;
    name = Some name;
    mime_type = Some mime_type;
    size = Some 0L;
    trashed = Some trashed;
    version = Some 1L;
    can_edit = Some true;
    modified_time = Some 0.;
    created_time = Some 0.;
    viewed_by_me_time = Some 0.;
    state = CacheData.Resource.State.Synchronized;
  }

let with_reset f =
  FakePorts.reset ();
  f ()

let test_create_regular_file_inserts_into_cache () =
  with_reset (fun () ->
      FakePorts.add_resource (make_resource "/" "root");
      let runtime = default_runtime () in
      run_session (Mutations.mknod runtime "/notes.txt" 0o644);
      assert_equal 1 (List.length !FakePorts.remote_create_calls);
      let created_file = List.hd !FakePorts.remote_create_calls in
      assert_equal "notes.txt" created_file.File.name;
      assert_equal
        (string_of_int 0o644)
        (List.assoc "mode" created_file.File.appProperties);
      assert_bool "expected inserted resource"
        (Option.is_some (FakePorts.find_resource "/notes.txt" false));
      assert_bool "expected not-found cleanup"
        (List.mem "delete_not_found:/notes.txt" !FakePorts.trace))

let test_create_shortcut_from_relative_target () =
  with_reset (fun () ->
      FakePorts.add_resource (make_resource "/" "root");
      FakePorts.add_resource
        (make_resource ~name:"links" "/links" "links-id");
      FakePorts.add_resource
        (make_resource ~mime_type:Drive.folder_mime_type ~name:"target" "/target"
           "target-id");
      let runtime = default_runtime () in
      run_session (Mutations.symlink runtime "../target" "/links/link");
      let created_file = List.hd !FakePorts.remote_create_calls in
      assert_equal Drive.shortcut_mime_type created_file.File.mimeType;
      assert_equal "target-id"
        created_file.File.shortcutDetails.File.ShortcutDetails.targetId)

let test_create_stored_symlink_for_external_target () =
  with_reset (fun () ->
      FakePorts.add_resource (make_resource "/" "root");
      FakePorts.add_resource
        (make_resource ~name:"links" "/links" "links-id");
      let runtime = default_runtime () in
      run_session (Mutations.symlink runtime "/tmp/external" "/links/link");
      let created_file = List.hd !FakePorts.remote_create_calls in
      assert_equal "" created_file.File.mimeType;
      assert_equal "/tmp/external" (List.assoc "l" created_file.File.appProperties);
      assert_equal
        (string_of_int 0o120777)
        (List.assoc "mode" created_file.File.appProperties))

let test_create_in_trash_is_denied () =
  with_reset (fun () ->
      let runtime = default_runtime () in
      assert_raises DriveMutations.Permission_denied (fun () ->
          run_session (Mutations.mknod runtime "/.Trash/file.txt" 0o644)))

let test_delete_uses_trash_by_default () =
  with_reset (fun () ->
      FakePorts.add_resource
        (make_resource ~mime_type:"text/plain" ~name:"file.txt" "/file.txt"
           "file-id");
      let runtime = default_runtime () in
      run_session (Mutations.unlink runtime "/file.txt");
      let resource = Option.get (FakePorts.find_resource "/file.txt" true) in
      assert_equal (Some true) resource.CacheData.Resource.trashed;
      assert_equal [ "file-id" ]
        (List.map fst !FakePorts.remote_update_calls);
      assert_bool "expected trash invalidation"
        (List.mem "invalidate_trash_bin" !FakePorts.trace))

let test_delete_can_skip_trash () =
  with_reset (fun () ->
      FakePorts.add_resource
        (make_resource ~mime_type:"text/plain" ~name:"file.txt" "/file.txt"
           "file-id");
      let runtime = default_runtime ~skip_trash:true () in
      run_session (Mutations.unlink runtime "/file.txt");
      assert_equal [ "file-id" ] !FakePorts.remote_delete_calls;
      assert_bool "expected cache deletion"
        (Option.is_none (FakePorts.find_resource "/file.txt" false)))

let test_delete_non_empty_folder_is_rejected () =
  with_reset (fun () ->
      FakePorts.children_present := true;
      FakePorts.add_resource
        (make_resource ~name:"docs" "/docs" "folder-id");
      let runtime = default_runtime () in
      assert_raises DriveMutations.Directory_not_empty (fun () ->
          run_session (Mutations.rmdir runtime "/docs")))

let suite =
  "DriveMutations test"
  >::: [
         "test_create_regular_file_inserts_into_cache"
         >:: test_create_regular_file_inserts_into_cache;
         "test_create_shortcut_from_relative_target"
         >:: test_create_shortcut_from_relative_target;
         "test_create_stored_symlink_for_external_target"
         >:: test_create_stored_symlink_for_external_target;
         "test_create_in_trash_is_denied" >:: test_create_in_trash_is_denied;
         "test_delete_uses_trash_by_default" >:: test_delete_uses_trash_by_default;
         "test_delete_can_skip_trash" >:: test_delete_can_skip_trash;
         "test_delete_non_empty_folder_is_rejected"
         >:: test_delete_non_empty_folder_is_rejected;
       ]
