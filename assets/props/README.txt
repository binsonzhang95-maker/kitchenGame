Restaurant props v1
Built-in image_gen tool, style reference japanese-animal-diner-style-v2.png.
Generation request: four isolated chunky pixel-art props on transparent background: completely bare pale maple square dining table with straight legs, front-facing mint-seat straight-back wooden chair, cream ceramic curry-rice dish, empty dark brown serving tray. Match reference RPG 3/4 perspective and warm dark outlines. No floor, shadow, room, labels, or extra decoration.
Post-processing: crop generated alpha bounds, nearest-neighbor resize, binary alpha threshold 128 and clear invisible RGB. No prop artwork was hand-drawn.
See anchors.json for sizes and origins. table_top and table_front retain full 140x90 canvas and perfectly reconstruct table.png. Horizontal split is y=44, at front top surface highlight.
contact.png is a 2x nearest-neighbor inspection image on cream background. source.png is original generated source. Final isolated sprites use only alpha 0 and 255.
