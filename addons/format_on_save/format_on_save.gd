@tool
class_name FormatOnSave extends EditorPlugin

## gdformat exit code returned on a successful format.
const SUCCESS := 0

#region Lifecycle events


func _enter_tree():
	resource_saved.connect(on_resource_saved)


func _exit_tree():
	resource_saved.disconnect(on_resource_saved)


## Signal handler for [member resource_saved].
func on_resource_saved(resource: Resource) -> void:
	if not resource is Script:
		return
	format(resource as Script)


#endregion

#region Out-of-order formatting prevention

## Stores instances of [Token] by their [member Token.resource_path].
##
## Must be accessed after locking [member mutex].
var tokens_by_resource_path := {}

## Protects access to [member tokens_by_resource_path].
var mutex := Mutex.new()


## Tracks when a format on save operation started by its [member Token.value] property.
##
## A token is maintained for all scripts in [member tokens_by_resource_path]. After creating a copy
## of the token for a script, it's possible to check if further saves have been performed by
## comparing the [member Token.value]s of the copy and the one in [member tokens_by_resource_path].
## If they differ, then the codepath that has the token should not save the file since the version
## of the script it formatted has been superseded by a new one.
class Token:
	var value: int
	var resource_path: String

	func _init(value_: int, resource_path_: String) -> void:
		self.value = value_
		self.resource_path = resource_path_

	func copy() -> Token:
		return Token.new(value, resource_path)


## Acquires a token for [param script] and returns it.
func acquire_token(script: Script) -> Token:
	mutex.lock()

	var resource_path := script.resource_path
	var token := (
		tokens_by_resource_path[resource_path] as Token
		if tokens_by_resource_path.has(resource_path)
		else Token.new(0, resource_path)
	)
	token.value += 1
	tokens_by_resource_path[resource_path] = token

	mutex.unlock()
	# Return a copy of the token so that concurrent modifications to token do not propagate to the
	# token returned to and held by the caller.
	return token.copy()


## Executes [param body] if [param token] has the same value as the corresponding [class Token] in
## [member tokens_by_resource_path].
func if_token_valid(token: Token, body: Callable) -> bool:
	mutex.lock()
	var existing_token := tokens_by_resource_path[token.resource_path] as Token
	var is_token_valid := existing_token.value == token.value
	if is_token_valid:
		body.call()
	mutex.unlock()
	return is_token_valid


#endregion


## Formats [param script] using gdformat.
func format(script: Script) -> void:
	var token = acquire_token(script)

	# Create a temporary copy of the script. Take the token into account to avoid race conditions
	# between the editor saving the same script again and the formatter running.
	var source := script.resource_path
	var temp := "%s.%d.temp" % [source, token.value]
	DirAccess.copy_absolute(source, temp)

	# Run the formatter and check for its exit code.
	var exit_code := OS.execute("gdformat", [ProjectSettings.globalize_path(temp)])
	if exit_code == SUCCESS:
		var formatted_source := FileAccess.get_file_as_string(temp)
		var save_successful = if_token_valid(token, func(): reload_script(script, formatted_source))
		if not save_successful:
			push_warning(
				"format_on_save: found new revision of %s after formatting. Formatting aborted."
			)
	else:
		push_error("format_on_save: encountered error %d while formatting %s" % [exit_code, source])

	DirAccess.remove_absolute(temp)


# Workaround until this PR is merged:
# https://github.com/godotengine/godot/pull/83267
# Thanks, @KANAjetzt 💖
func reload_script(script: Script, source_code: String) -> void:
	var current_script := get_editor_interface().get_script_editor().get_current_script()
	if current_script.resource_path != script.resource_path:
		push_warning(
			(
				"format_on_save: current editor is on %s but formatted %s. Formatting aborted."
				% [current_script.resource_path, script.resource_path]
			)
		)
		return

	var code_edit := (
		get_editor_interface().get_script_editor().get_current_editor().get_base_editor()
		as CodeEdit
	)

	var column := code_edit.get_caret_column()
	var row := code_edit.get_caret_line()
	var scroll_position_h := code_edit.get_h_scroll_bar().value
	var scroll_position_v := code_edit.get_v_scroll_bar().value
	var folded_lines := code_edit.get_folded_lines()

	code_edit.text = source_code
	code_edit.set_caret_column(column)
	code_edit.set_caret_line(row)
	code_edit.scroll_horizontal = scroll_position_h
	code_edit.scroll_vertical = scroll_position_v
	for line in folded_lines:
		if code_edit.can_fold_line(line):
			code_edit.fold_line(line)

	code_edit.tag_saved_version()
