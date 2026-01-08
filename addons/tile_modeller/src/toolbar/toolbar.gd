@tool
extends HBoxContainer

signal tool_mode_selected(mode:TileModeller.TOOL_MODE)
signal vertex_color_changed(color)
signal vertex_snap_changed(amount)
signal rotate_tile
signal export_mesh
func _ready() -> void:
	visible = false

func _on_tile_paint_pressed() -> void:
	tool_mode_selected.emit(TileModeller.TOOL_MODE.TILE)
	%TileOrientation.visible = true
	%VertexSnap.visible = true
	%VertexColor.visible = false

func _on_vertex_mode_pressed() -> void:
	tool_mode_selected.emit(TileModeller.TOOL_MODE.MOVE_VERTEX)
	%TileOrientation.visible = false
	%VertexSnap.visible = true
	%VertexColor.visible = false
func _on_paint_vertex_pressed() -> void:
	tool_mode_selected.emit(TileModeller.TOOL_MODE.PAINT_VERTEX)
	%TileOrientation.visible = false
	%VertexSnap.visible = false
	%VertexColor.visible = true

func _on_color_picker_button_color_changed(color: Color) -> void:
	vertex_color_changed.emit(color)

func _on_spin_box_value_changed(value: float) -> void:
	vertex_snap_changed.emit(value)

func set_brush_values(brush:TileModeller):
	%VertexSnapSpinBox.value = brush.vertex_snap
	%VertexColorButton.color = brush.vertex_color


func _on_rotate_tile_pressed() -> void:
	rotate_tile.emit()


func _on_export_mesh_pressed() -> void:
	export_mesh.emit()
