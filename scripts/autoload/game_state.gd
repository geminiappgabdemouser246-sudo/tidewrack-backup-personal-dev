extends Node
## GameState – global save/load, story flags, and journal persistence.
##
## Autoloaded as `GameState`. Holds narrative flags set by dialogue choices and
## coordinates `Journal` entry persistence in `user://save.json` so "Continue"
## restores both story flags and discovered logs.

signal state_changed

const SAVE_PATH := "user://save.json"
const SAVE_VERSION := 2
const DEFAULT_SCENE := "res://scenes/game.tscn"

## Story flags set during play, e.g. {"trusted_edith": true}.
var flags: Dictionary = {}
## Path of the scene the player should resume into.
var current_scene: String = DEFAULT_SCENE

## Cached journal entries so save/load preserves journal state even if `Journal`
## initializes after `GameState` or is absent in an isolated test.
var _journal_entries: Array[String] = []
var _has_synced_state: bool = false
var _journal_override: Node = null


func set_journal_node(node: Node) -> void:
	_journal_override = node
	if node != null:
		_sync_journal_node(node)


func set_flag(flag_name: String, value: Variant) -> void:
	var clean_name := flag_name.strip_edges()
	if clean_name.is_empty():
		push_warning("GameState: ignored empty flag name in set_flag().")
		return
	flags[clean_name] = value
	state_changed.emit()


func get_flag(flag_name: String, default: Variant = false) -> Variant:
	return flags.get(flag_name.strip_edges(), default)


func new_game() -> void:
	flags.clear()
	current_scene = DEFAULT_SCENE
	_journal_entries.clear()
	_has_synced_state = true
	var journal := _get_journal()
	if journal != null and journal.has_method("clear"):
		journal.call("clear")
	state_changed.emit()


## Alias used by `scripts/main_menu.gd` when starting a fresh run.
func reset() -> void:
	new_game()


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func save_game() -> bool:
	var entries_to_save := _collect_journal_entries()
	var payload := {
		"version": SAVE_VERSION,
		"scene": _sanitize_scene_path(current_scene),
		"flags": _sanitize_flags(flags),
		"journal": entries_to_save,
	}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("GameState: could not open save file for writing.")
		return false
	file.store_string(JSON.stringify(payload, "\t") + "\n")
	file.flush()
	var write_err := file.get_error()
	file.close()
	if write_err != OK:
		push_error("GameState: failed while writing save file (%s)." % error_string(write_err))
		return false
	_journal_entries = entries_to_save.duplicate()
	return true


func load_game() -> bool:
	if not has_save():
		return false
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_error("GameState: could not open save file for reading.")
		return false
	var text := file.get_as_text()
	file.close()
	if text.strip_edges().is_empty():
		push_error("GameState: save file is empty.")
		return false

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("GameState: save file is corrupt.")
		return false

	var migrated := _migrate_save_data(parsed as Dictionary)
	var next_scene := _sanitize_scene_path(migrated.get("scene", DEFAULT_SCENE))
	var next_flags := _sanitize_flags(migrated.get("flags", {}))
	var next_journal := _sanitize_journal_entries(migrated.get("journal", []))

	current_scene = next_scene
	flags = next_flags
	_journal_entries = next_journal.duplicate()
	_has_synced_state = true

	var journal := _get_journal()
	if journal != null and journal.has_method("from_save_data"):
		journal.call("from_save_data", next_journal)

	state_changed.emit()
	return true


func delete_save() -> void:
	if not has_save():
		return
	var dir := DirAccess.open(SAVE_PATH.get_base_dir())
	if dir != null:
		var _err := dir.remove(SAVE_PATH.get_file())


func _sync_journal_node(journal: Node) -> void:
	if (_has_synced_state or not _journal_entries.is_empty()) and journal.has_method("from_save_data"):
		journal.call("from_save_data", _journal_entries)


func _get_journal() -> Node:
	if _journal_override != null and is_instance_valid(_journal_override):
		return _journal_override
	return get_node_or_null("/root/Journal")


func _collect_journal_entries() -> Array[String]:
	var journal := _get_journal()
	if journal != null and journal.has_method("to_save_data"):
		return _sanitize_journal_entries(journal.call("to_save_data"))
	return _journal_entries.duplicate()


## Migrates older saves without deriving journal entries from story flags:
## v1 (or unversioned) saves with no `journal` field keep an empty journal.
func _migrate_save_data(data: Dictionary) -> Dictionary:
	var migrated := data.duplicate(true)
	var raw_version: Variant = migrated.get("version", 1)
	var version := 1
	if typeof(raw_version) == TYPE_INT:
		version = raw_version as int
	elif typeof(raw_version) == TYPE_FLOAT:
		version = int(raw_version as float)
	else:
		push_warning("GameState: invalid save version type; treating as v1.")

	if version < 1:
		version = 1

	if version < 2:
		if not migrated.has("journal"):
			migrated["journal"] = []
		version = 2

	if version > SAVE_VERSION:
		push_warning(
			"GameState: save file version %d is newer than supported version %d; loading known fields."
			% [version, SAVE_VERSION]
		)

	migrated["version"] = SAVE_VERSION
	return migrated


func _sanitize_scene_path(raw_scene: Variant) -> String:
	if typeof(raw_scene) != TYPE_STRING:
		if raw_scene != null:
			push_warning("GameState: non-string scene in save; falling back to default scene.")
		return DEFAULT_SCENE
	var candidate := (raw_scene as String).strip_edges()
	if candidate.is_empty() or not candidate.begins_with("res://"):
		push_warning("GameState: invalid scene path '%s'; falling back to default scene." % candidate)
		return DEFAULT_SCENE
	return candidate


func _sanitize_flags(raw_flags: Variant) -> Dictionary:
	if typeof(raw_flags) != TYPE_DICTIONARY:
		if raw_flags != null:
			push_warning("GameState: malformed 'flags' in save; resetting flags to empty Dictionary.")
		return {}
	var source: Dictionary = raw_flags
	var clean: Dictionary = {}
	for key: Variant in source.keys():
		if typeof(key) != TYPE_STRING:
			continue
		var clean_key := (key as String).strip_edges()
		if clean_key.is_empty():
			continue
		var val: Variant = source[key]
		if typeof(val) == TYPE_DICTIONARY:
			clean[clean_key] = (val as Dictionary).duplicate(true)
		elif typeof(val) == TYPE_ARRAY:
			clean[clean_key] = (val as Array).duplicate(true)
		else:
			clean[clean_key] = val
	return clean


func _sanitize_journal_entries(raw_journal: Variant) -> Array[String]:
	var clean_entries: Array[String] = []
	var source: Variant = raw_journal
	if typeof(raw_journal) == TYPE_DICTIONARY:
		source = (raw_journal as Dictionary).get("entries", [])

	if typeof(source) == TYPE_ARRAY:
		var raw_list: Array = source
		for item: Variant in raw_list:
			if typeof(item) != TYPE_STRING:
				continue
			var clean_id := (item as String).strip_edges()
			if not clean_id.is_empty() and not (clean_id in clean_entries):
				clean_entries.append(clean_id)
	elif source != null:
		push_warning("GameState: malformed 'journal' field in save; resetting journal to empty.")
	return clean_entries
