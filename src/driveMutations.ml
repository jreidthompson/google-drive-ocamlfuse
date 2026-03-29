open GapiMonad
open GapiMonad.SessionM.Infix
open GapiDriveV3Model

exception Directory_not_empty
exception Existing_attribute
exception File_not_found
exception IO_error
exception Invalid_operation
exception No_attribute
exception Permission_denied

type runtime = {
  cache : CacheData.t;
  config : Config.t;
  mountpoint_path : string;
  skip_trash : bool;
}

module type PORTS = sig
  val max_link_target_length : int
  val json_length : string -> int
  val is_lost_and_found : string -> bool -> Config.t -> bool
  val get_path_in_cache : string -> Config.t -> string * bool
  val is_filesystem_read_only : unit -> bool
  val create_resource : string -> CacheData.Resource.t

  val update_resource_from_file :
    ?state:CacheData.Resource.State.t ->
    ?link_target:string ->
    CacheData.Resource.t ->
    File.t ->
    CacheData.Resource.t

  val get_resource : string -> bool -> CacheData.Resource.t SessionM.m

  val build_resource_keys_header_from_resource :
    CacheData.Resource.t -> GapiCore.Header.t list

  val insert_resource_into_cache :
    ?state:CacheData.Resource.State.t ->
    ?link_target:string ->
    CacheData.t ->
    CacheData.Resource.t ->
    File.t ->
    CacheData.Resource.t

  val update_cached_resource : CacheData.t -> CacheData.Resource.t -> unit
  val delete_cached_resource : CacheData.Resource.t -> unit
  val delete_all_with_parent_path : CacheData.t -> string -> bool -> unit
  val trash_all_with_parent_path : CacheData.t -> string -> unit
  val invalidate_trash_bin : CacheData.t -> unit
  val delete_not_found_resource_with_path : CacheData.t -> string -> unit
  val remote_create : File.t -> File.t SessionM.m

  val remote_update :
    custom_headers:GapiCore.Header.t list ->
    fileId:string ->
    File.t ->
    File.t SessionM.m

  val remote_delete :
    custom_headers:GapiCore.Header.t list -> fileId:string -> unit SessionM.m

  val check_if_empty_remote : string -> bool -> bool -> unit SessionM.m
end

module Make (P : PORTS) = struct
  let folder_mime_type = "application/vnd.google-apps.folder"
  let shortcut_mime_type = "application/vnd.google-apps.shortcut"

  let default_save_resource_to_db cache resource file =
    let updated_resource = P.update_resource_from_file resource file in
    P.update_cached_resource cache updated_resource

  let update_remote_resource runtime path
      ?(save_to_db = default_save_resource_to_db)
      ?(purge_cache = fun _cache _resource -> ()) do_remote_update =
    let path_in_cache, trashed = P.get_path_in_cache path runtime.config in
    let update_file =
      P.get_resource path_in_cache trashed >>= fun resource ->
      do_remote_update resource >>= fun file_option ->
      (match file_option with
      | None -> purge_cache runtime.cache resource
      | Some file -> save_to_db runtime.cache resource file);
      SessionM.return ()
    in
    if P.is_filesystem_read_only () then raise Permission_denied else update_file

  let normalized_mountpoint_path runtime =
    if ExtString.String.ends_with runtime.mountpoint_path Filename.dir_sep then
      Filename.chop_suffix runtime.mountpoint_path Filename.dir_sep
    else runtime.mountpoint_path

  let resolve_shortcut_target_id runtime path target_path =
    let target_path =
      if Filename.is_relative target_path then
        let target_dirname = Filename.dirname path in
        if target_dirname = Filename.dir_sep then target_dirname ^ target_path
        else target_dirname ^ Filename.dir_sep ^ target_path
      else target_path
    in
    let target_path =
      let mountpoint_path = normalized_mountpoint_path runtime in
      if ExtString.String.starts_with target_path mountpoint_path then
        let mountpoint_path_length = String.length mountpoint_path in
        String.sub target_path mountpoint_path_length
          (String.length target_path - mountpoint_path_length)
      else target_path
    in
    let target_path =
      if ExtString.String.ends_with target_path Filename.dir_sep then
        Filename.chop_suffix target_path Filename.dir_sep
      else target_path
    in
    let normalized_target_path =
      try Utils.normalize_absolute_path target_path with _ -> ""
    in
    let target_path_in_cache, target_trashed =
      P.get_path_in_cache normalized_target_path runtime.config
    in
    P.get_resource target_path_in_cache target_trashed >>= fun resource ->
    if CacheData.Resource.is_shortcut resource then
      Utils.raise_m Permission_denied
    else SessionM.return (Option.get resource.CacheData.Resource.remote_id)

  let create_remote_resource runtime ?link_target is_folder path mode =
    let path_in_cache, trashed = P.get_path_in_cache path runtime.config in
    if trashed then raise Permission_denied;
    if P.is_lost_and_found path trashed runtime.config then
      raise Permission_denied;
    if P.is_filesystem_read_only () then raise Permission_denied;
    let create_file =
      let parent_path = Filename.dirname path_in_cache in
      P.get_resource parent_path trashed >>= fun parent_resource ->
      let parent_id = Option.get parent_resource.CacheData.Resource.remote_id in
      let name = Filename.basename path_in_cache in
      let mountpoint_path = normalized_mountpoint_path runtime in
      let is_shortcut =
        match link_target with
        | None -> false
        | Some target ->
            if Filename.is_relative target then true
            else ExtString.String.starts_with target mountpoint_path
      in
      let mime_type =
        if is_shortcut then shortcut_mime_type
        else if is_folder then folder_mime_type
        else if runtime.config.Config.autodetect_mime then ""
        else Mime.map_filename_to_mime_type name
      in
      let app_properties =
        match link_target with
        | Some link when not is_shortcut ->
            if P.json_length link > P.max_link_target_length then
              raise Invalid_operation
            else
              [
                CacheData.Resource.link_target_to_app_property link;
                CacheData.Resource.mode_to_app_property 0o120777;
              ]
        | _ -> [ CacheData.Resource.mode_to_app_property mode ]
      in
      (match link_target with
      | Some target_path when is_shortcut ->
          resolve_shortcut_target_id runtime path target_path
      | _ -> SessionM.return "")
      >>= fun target_id ->
      let file =
        {
          File.empty with
          File.name;
          parents = [ parent_id ];
          mimeType = mime_type;
          appProperties = app_properties;
          shortcutDetails =
            { File.ShortcutDetails.empty with targetId = target_id };
        }
      in
      Utils.log_with_header
        "BEGIN: Creating %s%s (path=%s, trashed=%b%s) on server\n%!"
        (match link_target with
        | None -> ""
        | Some _ when is_shortcut -> "shortcut to "
        | Some _ -> "symlink to ")
        (if is_folder then "folder" else "file")
        path_in_cache trashed
        (match link_target with None -> "" | Some target -> ", target=" ^ target);
      P.remote_create file >>= fun created_file ->
      Utils.log_with_header
        "END: Creating file/folder (path=%s, trashed=%b) on server\n%!"
        path_in_cache trashed;
      let new_resource = P.create_resource path_in_cache in
      Utils.log_with_header
        "BEGIN: Deleting 'NotFound' resources (path=%s) from cache\n%!"
        path_in_cache;
      P.delete_not_found_resource_with_path runtime.cache path_in_cache;
      Utils.log_with_header
        "END: Deleting 'NotFound' resources (path=%s) from cache\n%!"
        path_in_cache;
      ignore
        (P.insert_resource_into_cache
           ~state:CacheData.Resource.State.Synchronized ?link_target
           runtime.cache new_resource created_file);
      SessionM.return ()
    in
    create_file

  let mknod runtime path mode = create_remote_resource runtime false path mode
  let mkdir runtime path mode = create_remote_resource runtime true path mode
  let symlink runtime target linkpath =
    create_remote_resource runtime ~link_target:target false linkpath 0o777

  let trash_resource runtime is_folder trashed path =
    if trashed then raise Permission_denied;
    if P.is_lost_and_found path trashed runtime.config then
      raise Permission_denied;
    let trash resource =
      let remote_id = Option.get resource.CacheData.Resource.remote_id in
      P.check_if_empty_remote remote_id is_folder trashed >>= fun () ->
      Utils.log_with_header "BEGIN: Trashing file (remote id=%s)\n%!" remote_id;
      let file_patch = { File.empty with File.trashed = true } in
      let custom_headers = P.build_resource_keys_header_from_resource resource in
      P.remote_update ~custom_headers ~fileId:remote_id file_patch
      >>= fun trashed_file ->
      Utils.log_with_header "END: Trashing file (remote id=%s)\n%!" remote_id;
      SessionM.return (Some trashed_file)
    in
    update_remote_resource runtime
      ~save_to_db:(fun cache resource _file ->
        let updated_resource =
          { resource with CacheData.Resource.trashed = Some true }
        in
        P.update_cached_resource cache updated_resource;
        P.invalidate_trash_bin cache;
        if is_folder then (
          let path_in_cache, _ = P.get_path_in_cache path runtime.config in
          Utils.log_with_header
            "BEGIN: Trashing folder old content (path=%s)\n%!" path_in_cache;
          P.trash_all_with_parent_path cache path_in_cache;
          Utils.log_with_header
            "END: Trashing folder old content (path=%s)\n%!" path_in_cache))
      path trash

  let delete_resource runtime is_folder path =
    let path_in_cache, trashed = P.get_path_in_cache path runtime.config in
    let delete resource =
      let remote_id = Option.get resource.CacheData.Resource.remote_id in
      P.check_if_empty_remote remote_id is_folder trashed >>= fun () ->
      Utils.log_with_header
        "BEGIN: Permanently deleting file (remote id=%s)\n%!" remote_id;
      let custom_headers = P.build_resource_keys_header_from_resource resource in
      P.remote_delete ~custom_headers ~fileId:remote_id >>= fun () ->
      Utils.log_with_header
        "END: Permanently deleting file (remote id=%s)\n%!" remote_id;
      SessionM.return None
    in
    update_remote_resource runtime
      ~purge_cache:(fun cache resource ->
        P.delete_cached_resource resource;
        if is_folder then (
          Utils.log_with_header
            "BEGIN: Deleting folder old content (path=%s, trashed=%b) from \
             cache\n\
             %!"
            path_in_cache trashed;
          P.delete_all_with_parent_path cache path_in_cache trashed;
          Utils.log_with_header
            "END: Deleting folder old content (path=%s, trashed=%b) from \
             cache\n\
             %!"
            path_in_cache trashed))
      path delete

  let delete_remote_resource runtime is_folder path =
    let _, trashed = P.get_path_in_cache path runtime.config in
    if runtime.skip_trash || (trashed && runtime.config.delete_forever_in_trash_folder)
    then delete_resource runtime is_folder path
    else trash_resource runtime is_folder trashed path

  let unlink runtime path = delete_remote_resource runtime false path
  let rmdir runtime path = delete_remote_resource runtime true path
end
