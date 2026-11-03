# INPUT:  isolated headless Godot 4.5.1 RC runtime
# OUTPUT: parsed-text and character-count results across repeated lifetimes
# POS:    exercise real RichTextLabel RID chunk growth and reuse without game data
extends SceneTree

func _initialize() -> void:
	call_deferred("run_test")

func run_test() -> void:
	for cycle in range(3):
		var label = RichTextLabel.new()
		label.bbcode_enabled = true
		label.size = Vector2(640, 400)
		root.add_child(label)
		for count in [300, 4500, 9000, 300]:
			var markup := "[color=#aabbcc]X[/color]".repeat(count)
			label.text = markup
			if label.get_parsed_text() != "X".repeat(count) or label.get_total_character_count() != count:
				printerr("FAIL cycle=", cycle, " count=", count, " chars=", label.get_total_character_count())
				quit(1)
				return
			if label.get_content_height() <= 0:
				printerr("FAIL shaping cycle=", cycle, " count=", count)
				quit(1)
				return
			print("PASS cycle=", cycle, " tags=", count, " chars=", label.get_total_character_count(), " minimum_items=", count * 2)
			label.clear()
			if label.get_parsed_text() != "" or label.get_total_character_count() != 0:
				printerr("FAIL clear")
				quit(1)
				return
		label.queue_free()
		await process_frame
		if is_instance_valid(label):
			printerr("FAIL queue_free cycle=", cycle)
			quit(1)
			return
	await process_frame
	print("RICH_TEXT_FIXTURE_OK")
	quit(0)
