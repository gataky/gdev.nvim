# 1 Goto Script issue

With a scene like

 Game [Node2D]
   Foreground [TileMapLayer]
   Background [TileMapLayer]
   Killzone [res://scenes/killzone.tscn]
     CollisionShape2D [CollisionShape2D]
   Player [res://scenes/player.tscn]
     Camera2D [Camera2D]

Where the player has a script.gd file.  Pressing "g" doesn't open the script but opens the players.tscn file.

Looking at the game.tscn file I see the following

```gd
[gd_scene format=4 uid="uid://558vaybmcnhb"]

[ext_resource type="PackedScene" uid="uid://bgl23lsy1issd" path="res://scenes/player.tscn" id="1_uwrxv"]

...

[node name="Player" parent="." unique_id=24510241 instance=ExtResource("1_uwrxv")]
```

I think the plugin is expecting that the node has reference to the script here but is getting tripped up with the `ExtResource`

It looks like `ExtResource("1_uwrxv")` references an ID and that ID links the node with the ext_resource. If you look at the script snippet I provided you can get the path by cross referencing the ID
