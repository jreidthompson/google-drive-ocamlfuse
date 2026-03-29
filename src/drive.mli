exception Directory_not_empty
exception Existing_attribute
exception File_not_found
exception IO_error
exception Invalid_operation
exception No_attribute
exception Permission_denied

val folder_mime_type : string
val shortcut_mime_type : string
val device_scope : string
val max_link_target_length : int
val apostrophe_regexp : Str.regexp
val json_length : string -> int
val is_lost_and_found : string -> bool -> Config.t -> bool
val get_path_in_cache : string -> Config.t -> string * bool
val create_resource : string -> CacheData.Resource.t

val update_resource_from_file :
  ?state:CacheData.Resource.State.t ->
  ?link_target:string ->
  CacheData.Resource.t ->
  GapiDriveV3Model.File.t ->
  CacheData.Resource.t

val build_resource_keys_header_from_resource :
  CacheData.Resource.t -> GapiCore.Header.t list

val statfs : unit -> Fuse.Unix_util.statvfs
val get_attr : string -> Unix.LargeFile.stats
val read_dir : string -> string list
val fopen : string -> Unix.open_flag list -> 'a option
val opendir : string -> 'a -> 'b option
val utime : string -> float -> float -> unit

val read :
  string ->
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t ->
  int64 ->
  'a ->
  int

val write :
  string ->
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t ->
  int64 ->
  'a ->
  int

val init_filesystem : unit -> unit
val flush : string -> 'a -> unit
val fsync : string -> 'a -> 'b -> unit
val release : string -> 'a -> 'b -> unit
val mknod : string -> int -> unit
val mkdir : string -> int -> unit
val unlink : string -> unit
val rmdir : string -> unit
val rename : string -> string -> unit
val truncate : string -> int64 -> unit
val chmod : string -> int -> unit
val chown : string -> int -> int -> unit
val get_xattr : string -> string -> string
val set_xattr : string -> string -> string -> Fuse.xattr_flags -> unit
val list_xattr : string -> string list
val remove_xattr : string -> string -> unit
val read_link : string -> string
val symlink : string -> string -> unit
