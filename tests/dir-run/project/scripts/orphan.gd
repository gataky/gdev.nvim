extends Node

## Attached to nothing. 'scenes/Shaded.tscn' references
## `res://scripts/orphan.gdshader`, whose name has this one as a prefix, so a
## substring search that ignores the quotes around a `res://` name reports this
## script as used.

func _ready() -> void:
	print("orphan ready")
