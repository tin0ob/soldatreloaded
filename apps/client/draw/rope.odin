package draw

import "core:math"

import rlgl "vendor:raylib/rlgl"

import sim "../../../core/game"
import "../../../core/utils"

// The ropes, drawn behind the soldiers: a line in the owner's jet colour, from the hand
// through the corners it is caught around to the anchor, each stretch dipping under its
// own weight — a rope that curves the way a rope hangs, and never a straight cut through
// the map. The thrown rope hangs toward its heavy hook, the sag deepening as the throw
// loses momentum. From the C client's render/render.c.

BONE_THICKNESS :: f32(1.2) // world units, as the original's debug bones

// The ropes of every soldier, behind the sprites that cover the hand that holds them.
@(private = "package")
draw_ropes :: proc(art: ^Art, game: ^sim.Game, frame: ^Frame) {
	for &soldier, id in game.world.soldiers {
		if !soldier.active || soldier.vitals.dead || soldier.rope.phase == .None do continue
		color := soldier.player.look.jet
		hand := frame.figures[id].points[14]
		rope := &soldier.rope
		if rope.phase == .Throwing && rope.wraps_count == 0 { // flying free: it hangs toward its heavy hook
			draw_rope_throw(hand, rope.tip, rope.tip_velocity, color)
			draw_hook(art, rope.tip, hand)
			continue
		}
		a := hand
		for w := int(rope.wraps_count) - 1; w >= -1; w -= 1 {
			b := rope.tip if w < 0 else rope.wraps[w]
			draw_rope_stretch(a, b, color)
			a = b
		}
		// the grapple at the anchor, its claw pointing back along the rope's last stretch
		base := rope.wraps[0] if rope.wraps_count > 0 else hand
		draw_hook(art, rope.tip, base)
	}
}

// The grapple at the rope's end, its claw pointing from `base` toward `tip`.
@(private = "file")
draw_hook :: proc(art: ^Art, tip, base: utils.Vec2) {
	d := tip - base
	if utils.length(d) < 0.001 do return
	angle := math.atan2(d.x, -d.y)
	draw_sprite(art.hook, tip, {art.hook.size.x / 2, art.hook.size.y}, {1, 1}, angle, WHITE)
}

// One stretch of a rope, dipped under its own weight: the curve's middle hangs a part of
// the stretch's length below the line, so the rope curves the way a rope hangs instead of
// cutting straight.
@(private = "file")
draw_rope_stretch :: proc(a, b: utils.Vec2, color: utils.Rgba) {
	d := b - a
	len := utils.length(d)
	if len < 0.001 do return
	c := (a + b) * 0.5 + utils.Vec2{0, min(len * 0.05, 6.0)} // down is +y
	prev := a
	for i in 1 ..= 6 {
		t := f32(i) / 6.0
		p := a * ((1 - t) * (1 - t)) + c * (2 * t * (1 - t)) + b * (t * t)
		draw_line(prev, p, color)
		prev = p
	}
}

// The rope in flight: a grapple is heavier than the rope, so the line hangs down toward
// the hook — the more as the throw slows and drops — instead of staying taut. The sag is
// biased toward the tip by weighting the midpoint toward it.
@(private = "file")
draw_rope_throw :: proc(hand, tip, tip_velocity: utils.Vec2, color: utils.Rgba) {
	d := tip - hand
	len := utils.length(d)
	if len < 0.001 do return
	slow := 1.0 - min(utils.length(tip_velocity) / sim.ROPE_SPEED, 1.0)
	sag := min(len * 0.05, 6.0) * (0.25 + 0.75 * slow)
	c := (hand + tip) * 0.5 + utils.Vec2{0, sag}
	prev := hand
	for i in 1 ..= 6 {
		t := f32(i) / 6.0
		p := hand * ((1 - t) * (1 - t)) + c * (2 * t * (1 - t)) + tip * (t * t)
		draw_line(prev, p, color)
		prev = p
	}
}

// A solid colour line from a to b, as the C's gfx_draw_line draws one: a quad BONE_THICKNESS
// wide, turned along the line. Drawn on raylib's default white texture, as the map's
// polygons are, so the colour comes through.
@(private = "file")
draw_line :: proc(a, b: utils.Vec2, color: utils.Rgba) {
	d := b - a
	len := utils.length(d)
	if len < 0.001 do return
	n := utils.Vec2{-d.y, d.x} / len * (BONE_THICKNESS / 2)
	rlgl.SetTexture(rlgl.GetTextureIdDefault())
	rlgl.Begin(rlgl.QUADS)
	for p in ([4]utils.Vec2{a - n, a + n, b + n, b - n}) {
		vertex(p, {}, color)
	}
	rlgl.End()
	rlgl.SetTexture(0)
}
