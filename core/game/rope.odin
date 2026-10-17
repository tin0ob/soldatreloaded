package game

import res "../resources"
import "../utils"

// The rope that replaces the jets: a Worms/Liero line flung at the aim until it holds
// a polygon the player can stand on. The throw is a rocket's flight: fast at first, the
// LAW's pace, losing its speed each tick until gravity has its way and it drops; past
// its reach or off the map, the rope gives up. Held, the rope cannot pass through the
// polygons between its anchor and its owner: it catches on the first corner its line
// crosses, the part wound around it held there while the rest hangs. From the last
// corner it hangs the soldier from a rod with the rope's give: taut, nothing moves
// along it, but pulled past its length it stretches — up to a part of itself — and the
// stretch pulls back; the up key climbs it to the anchor, where the rope lets go; left
// and right swing on it, the soldier rolled up in the classic cannonball, the momentum
// gathered; and the rope key pressed again cuts it, the swing kept. The same key as the
// jets, played the same way: held to throw, pressed to cut.
//
// The rope's state lives in the soldier's owned half (phase, tip, length, the corners
// it is wound around, the key's press edge), so it travels with the rest of what its
// client decides and every machine sees the same rope. The cut needs no authority:
// bullets fly identically on every machine, and every machine's bullets pass computes
// the cut itself (rope_cut); the Rope_Cut it emits is for the sparks alone and never
// leaves the machine that made it. Ported from graple_soldat's game/systems/rope.c.

// What a rope is doing, for its owner to play and for every machine to draw and cut.
Rope_Phase :: enum u8 {
	None,      // none out, or the last one retracted
	Throwing,  // in the air, on its way to an anchor
	Attached,  // holding a polygon, its owner hanging on it
}

// The corners a rope can be caught around at once.
ROPE_WRAPS :: 6

// A soldier's rope, all owned by its client.
Rope :: struct {
	phase:        Rope_Phase,
	tip:          utils.Vec2, // the flying end, or the anchor
	tip_velocity: utils.Vec2, // how fast the flying end flies
	length:       f32,        // the length it holds its owner at
	grab:         f32,        // the length it had when it grabbed: the down key feeds back out only this far
	climb:        f32,        // the climb's pace (a slow pull that builds while up is held)
	wraps_count:  u8,
	wraps:        [ROPE_WRAPS]utils.Vec2, // the corners it is caught around, anchor out to its owner
}

ROPE_MAX :: f32(800.0) // a throw flies this far at most; past it, the rope drops
ROPE_DRAG :: f32(0.97) // the throw's loss of speed a tick: fast at first, falling at last
ROPE_SWING :: f32(0.088) // the push a tick of holding left or right gives the swing
ROPE_ROLL_SLOW :: 2      // the swing's roll plays this many times slower than its pace
ROPE_CATCH :: f32(1.0)   // a pull along the rope faster than this stretches it
ROPE_SPRING :: f32(0.05) // the stretch's pull back a tick, ROPE_SPRING of itself
ROPE_DAMP :: f32(0.9)    // the part of the bounce kept a tick: how the stretch settles
// The climb's pace, as parts of the rope's speed: a tenth at first, gaining a hundredth
// a tick of holding up, a fifth at most.
ROPE_CLIMB_START :: f32(0.10)
ROPE_CLIMB_GAIN :: f32(0.01)
ROPE_CLIMB_MAX :: f32(0.20)
ROPE_REACH :: f32(8.0) // how near the anchor the climb comes before it snaps it

ROPE_SPEED :: f32(23.0)
ROPE_GIVE :: f32(0.1875) // the part of its length a rope stretches at most, pulled past it
ROPE_SWING_MAX :: MAX_VELOCITY // the swing's momentum is cut at the safety clamp

// The dot product the rope's physics uses; utils has none, and a step may not import
// anything that widens to f64.
@(private = "file")
dot :: proc(a, b: utils.Vec2) -> f32 {
	return a.x * b.x + a.y * b.y
}

// Where two segments cross, if they do (graple_soldat's segments_cross): the point the
// lines they lie on meet at, when it lies within both. Not for collinear or parallel
// segments.
@(private = "file")
segments_cross :: proc(a1, a2, b1, b2: utils.Vec2) -> (hit: utils.Vec2, ok: bool) {
	r := a2 - a1
	s := b2 - b1
	denom := r.x * s.y - r.y * s.x
	if denom == 0 do return {}, false
	qp := b1 - a1
	t := (qp.x * s.y - qp.y * s.x) / denom
	u := (qp.x * r.y - qp.y * r.x) / denom
	if t < 0 || t > 1 || u < 0 || u > 1 do return {}, false
	return a1 + r * t, true
}

// The throw's flying end: flung at the aim at the rope's pace, losing its speed each
// tick as the LAW's rocket does, and falling under gravity at last. It holds on the
// first polygon the player can stand on that its flight crosses; past the rope's reach,
// or off the map, the rope drops.
@(private = "file")
rope_throw :: proc(world: ^World, soldier: ^Soldier) {
	rope := &soldier.rope
	prev := rope.tip
	rope.tip_velocity.y += world.gravity * BULLET_GRAVITY
	rope.tip_velocity *= ROPE_DRAG
	rope.tip += rope.tip_velocity
	hit, blocked := res.ray_cast(world.polymap, prev, rope.tip, utils.length(rope.tip - prev) + 1.0, res.Ray_Filter{player = true, team = soldier.team})
	if blocked {
		rope.tip = prev + utils.normalize(rope.tip - prev) * hit.distance
		rope.length = rope_total_length(soldier) // the corners caught on the way out count too
		rope.grab = rope.length // the down key feeds it back out only this far
		rope.phase = .Attached
		return
	}
	rope.length = utils.length(rope.tip - soldier.body.pos)
	bound := f32(world.polymap.sector_reach * world.polymap.sector_size - 10)
	if rope.length > ROPE_MAX || abs(rope.tip.x) > bound || abs(rope.tip.y) > bound do rope.phase = .None
}

// The rope's running end: where the physics holds it — the last corner it is caught
// around, or the anchor itself.
@(private = "file")
rope_end :: proc(soldier: ^Soldier) -> utils.Vec2 {
	rope := &soldier.rope
	if rope.wraps_count > 0 do return rope.wraps[rope.wraps_count - 1]
	return rope.tip
}

// The part of the rope wound around the corners it is caught on.
@(private = "file")
rope_wrapped :: proc(soldier: ^Soldier) -> f32 {
	rope := &soldier.rope
	wrapped: f32
	prev := rope.tip
	for i in 0 ..< int(rope.wraps_count) {
		wrapped += utils.length(rope.wraps[i] - prev)
		prev = rope.wraps[i]
	}
	return wrapped
}

// The rope's whole length, the wound corners and the free stretch to its owner.
@(private = "file")
rope_total_length :: proc(soldier: ^Soldier) -> f32 {
	return rope_wrapped(soldier) + utils.length(soldier.body.pos - rope_end(soldier))
}

// The rope and the map: held to a polygon, the rope cannot pass through the polygons
// between its anchor and its owner — it catches on the one its line crosses, pinned on
// the edge it meets and the edge it leaves by, the wound part held around the solid
// while the rest hangs. The pins sit a hair on the rope's own side of each edge, so
// every free stretch stays clear of the map; swung back, the corner lets go when the
// straight line from the point before it is clear again and the rope reaches.
@(private = "file")
rope_wrap :: proc(world: ^World, soldier: ^Soldier) {
	rope := &soldier.rope
	count := int(rope.wraps_count)
	end := rope_end(soldier)
	d := soldier.body.pos - end
	len := utils.length(d)
	if len < 0.001 do return

	if count < ROPE_WRAPS {
		hit, blocked := res.ray_cast(world.polymap, end, soldier.body.pos, len, res.Ray_Filter{player = true, team = soldier.team})
		if blocked && hit.polygon >= 0 {
			polygon := &world.polymap.polygons[hit.polygon]
			dir := d / len
			// the crossings of the rope's line with the polygon's edges: where it meets
			// the solid, and where it leaves it again
			in_p, out_p := end, end
			n := 0
			for e in 0 ..< 3 {
				p, crosses := segments_cross(end, soldier.body.pos, polygon.vertices[e], polygon.vertices[(e + 1) % 3])
				if !crosses do continue
				if n > 0 && utils.length(p - in_p) < 0.01 do continue // the same vertex, grazing it
				if n == 0 do in_p = p
				else do out_p = p
				n += 1
			}
			if n == 2 && utils.length(in_p - end) > utils.length(out_p - end) {
				in_p, out_p = out_p, in_p
			}
			in_d := utils.length(in_p - end)
			out_d := utils.length(out_p - end)
			room := ROPE_WRAPS - count
			if n >= 1 && (in_d > 6.0 || count == 0) {
				// in_d <= 6 with wraps already on: the running end is a pin on this very
				// polygon — the rope is already wound around it. The bare anchor may sit
				// as close: the throw lands the tip on the surface of the polygon it
				// holds, and that polygon catches the rope all the same.
				if n == 2 && out_d < len - 6.0 && room >= 2 {
					rope.wraps[count] = in_p - dir * 0.5
					rope.wraps[count + 1] = out_p + dir * 0.5
					rope.wraps_count = u8(count + 2)
					return
				}
				if room >= 1 && (n == 1 ? in_d : out_d) < len - 6.0 {
					rope.wraps[count] = (n == 1 ? in_p : out_p) + dir * 0.5
					rope.wraps_count = u8(count + 1)
					return
				}
			}
		}
	}
	if count > 0 {
		before := rope.wraps[count - 2] if count > 1 else rope.tip
		rest := rope.length - (rope_wrapped(soldier) - utils.length(rope.wraps[count - 1] - before))
		_, blocked := res.ray_cast(world.polymap, before, soldier.body.pos, len, res.Ray_Filter{player = true, team = soldier.team})
		if !blocked && utils.length(soldier.body.pos - before) <= rest + 0.01 {
			rope.wraps_count = u8(count - 1)
		}
	}
}

// The rope on the way out: its flying end is still being paid out, so the corners it
// catches are the line's crossings near the tip, not near its owner. The pins go at the
// front of the wound part — nearest the tip — as rope_wrap's go at the back. True when it
// caught a corner this tick, so the tip's flight can be redirected around it.
@(private = "file")
rope_wrap_throw :: proc(world: ^World, soldier: ^Soldier) -> bool {
	rope := &soldier.rope
	count := int(rope.wraps_count)
	end := rope.wraps[0] if count > 0 else soldier.body.pos // the running end near the tip
	other := rope.tip
	d := other - end
	len := utils.length(d)
	if len < 0.001 do return false

	if count < ROPE_WRAPS {
		hit, blocked := res.ray_cast(world.polymap, end, other, len, res.Ray_Filter{player = true, team = soldier.team})
		if blocked && hit.polygon >= 0 {
			polygon := &world.polymap.polygons[hit.polygon]
			dir := d / len
			in_p, out_p := end, end
			n := 0
			for e in 0 ..< 3 {
				p, crosses := segments_cross(end, other, polygon.vertices[e], polygon.vertices[(e + 1) % 3])
				if !crosses do continue
				if n > 0 && utils.length(p - in_p) < 0.01 do continue
				if n == 0 do in_p = p
				else do out_p = p
				n += 1
			}
			if n == 2 && utils.length(in_p - end) > utils.length(out_p - end) {
				in_p, out_p = out_p, in_p
			}
			in_d := utils.length(in_p - end)
			out_d := utils.length(out_p - end)
			room := ROPE_WRAPS - count
			if n >= 1 && (in_d > 6.0 || count == 0) {
				if n == 2 && out_d < len - 6.0 && room >= 2 {
					for i := count - 1; i >= 0; i -= 1 do rope.wraps[i + 2] = rope.wraps[i]
					rope.wraps[0] = out_p + dir * 0.5 // nearest the tip
					rope.wraps[1] = in_p - dir * 0.5
					rope.wraps_count = u8(count + 2)
					return true
				}
				if room >= 1 && (n == 1 ? in_d : out_d) < len - 6.0 {
					for i := count - 1; i >= 0; i -= 1 do rope.wraps[i + 1] = rope.wraps[i]
					rope.wraps[0] = (n == 1 ? in_p : out_p) + dir * 0.5
					rope.wraps_count = u8(count + 1)
					return true
				}
			}
		}
	}
	return false
}

// The hang: a rod with the rope's give, held from the rope's running end. At its length
// — and anywhere nearer the end — the rod holds: nothing moves along it, so gravity
// swings the soldier without stretching the rope. Pulled past its length, the rope
// gives: the stretch pulls back — ROPE_SPRING of itself a tick, the bounce damping a
// part of it — and never past ROPE_GIVE of the length, so a hard pull bounces instead
// of snapping.
@(private = "file")
rope_hold :: proc(soldier: ^Soldier) {
	rope := &soldier.rope
	end := rope_end(soldier)
	hold_len := rope.length - rope_wrapped(soldier) // what's left past the wound part
	if hold_len < 0 do hold_len = 0 // wound up to its owner: held at the last corner
	d := soldier.body.pos - end
	len := utils.length(d)
	if len < 0.001 { // right at the anchor: hang straight down
		soldier.body.pos = end + utils.Vec2{0, hold_len}
		d = utils.Vec2{0, hold_len}
		len = hold_len
	}
	n := d / len
	radial := dot(soldier.body.velocity, n) // along the rope: + away from the anchor
	if len > hold_len && (radial > ROPE_CATCH || len > hold_len + ROPE_CATCH) {
		// the give: the stretch pulls back, harder the farther it goes, and the bounce
		// damps as it settles, never past ROPE_GIVE of the length
		stretch := len - hold_len
		soldier.body.velocity -= n * (stretch * ROPE_SPRING + radial * (1.0 - ROPE_DAMP))
		max_len := hold_len * (1.0 + ROPE_GIVE)
		if len > max_len do soldier.body.pos = end + n * max_len
	} else {
		// taut: the rod holds the length, nothing moves along it
		soldier.body.pos = end + n * hold_len
		soldier.body.velocity -= n * radial
	}
}

// The climb: the up key reels the soldier to the anchor, the rope shortening as it goes
// — the wound part slips around its corners as the owner rises past them. The pace is
// the rope's law of climbing: a tenth of the rope's speed at first, gaining a hundredth
// of it every tick the key is held, a fifth of it at most — a slow pull that builds. The
// pull is the pace itself, travelled by the body, the sideways momentum carried, so the
// climb's momentum is the soldier's own. The rope snaps when the body is within the
// climb's reach of its end, or when the rope is reeled down to it, and lets its owner
// go, stood where it held.
@(private = "file")
rope_climb :: proc(soldier: ^Soldier) {
	rope := &soldier.rope
	rope.climb = min(rope.climb + ROPE_SPEED * ROPE_CLIMB_GAIN, ROPE_SPEED * ROPE_CLIMB_MAX)
	end := rope_end(soldier)
	d := end - soldier.body.pos
	len := utils.length(d)
	n := d / len if len > 0.001 else utils.Vec2{0, 1}
	// the pace along the rope; what crosses it — the swing's push, gathered — stays
	radial := dot(soldier.body.velocity, n)
	soldier.body.velocity = n * (rope.climb - radial) + soldier.body.velocity
	if len <= rope.climb + ROPE_REACH || rope.length <= ROPE_REACH {
		soldier.body.pos = end
		rope.phase = .None
		rope.wraps_count = 0
		return
	}
	rope.length -= rope.climb
}

// The payout: the down key feeds the rope out, the pace the climb reels it in — the one
// ramp serves both, so holding down runs out exactly as fast as holding up hauls back —
// and only as far as the rope was when it grabbed: the climb's slack back out, never
// more rope than the throw made.
@(private = "file")
rope_payout :: proc(soldier: ^Soldier) {
	rope := &soldier.rope
	rope.climb = min(rope.climb + ROPE_SPEED * ROPE_CLIMB_GAIN, ROPE_SPEED * ROPE_CLIMB_MAX)
	if rope.length < rope.grab do rope.length = min(rope.length + rope.climb, rope.grab)
	rope_hold(soldier)
}

// The swing: holding left or right pushes the hang along its arc, at right angles to the
// rope, and rolls the soldier up — the classic cannonball, its spin slowed so the roll
// reads, the momentum gathered for the cut. The gathered momentum is cut at
// ROPE_SWING_MAX: past it the push in that direction adds nothing, while the push
// against the momentum always works.
@(private = "file")
rope_swing :: proc(resources: ^Resources, soldier: ^Soldier, left, right: bool) {
	rope := &soldier.rope
	d := soldier.body.pos - rope_end(soldier)
	len := utils.length(d)
	if len < 0.001 do return
	n := d / len
	tang := utils.Vec2{n.y, -n.x}
	tang_vel := dot(soldier.body.velocity, tang) // the momentum already gathered along the arc
	if right && tang_vel < ROPE_SWING_MAX do soldier.body.velocity += tang * ROPE_SWING
	if left && tang_vel > -ROPE_SWING_MAX do soldier.body.velocity -= tang * ROPE_SWING
	res.animation_switch(resources.animations, &soldier.pose.body, .Roll)
	soldier_legs_switch(resources.animations, soldier, .Roll)
	soldier.pose.body.speed = resources.animations[.Roll].speed * ROPE_ROLL_SLOW
	soldier.pose.legs.speed = resources.animations[.Roll].speed * ROPE_ROLL_SLOW
}

// The rope's control step, in place of the jets' for a soldier of the rope gear: the key
// held flings the rope at the aim, a rocket's flight that slows and falls, until it
// holds a polygon; released, it retracts; the up key climbs the hold to its anchor,
// where the rope lets go, the down key feeds it back out, left and right swing on it,
// and the key pressed again cuts it, the swing kept.
rope_control :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, soldier: ^Soldier, out: ^Tick_Output) {
	rope := &soldier.rope
	controls := &soldier.controls
	jet := .Jet in controls.buttons
	press := jet && !controls.was_jet
	up := .Jump in controls.buttons
	down := .Crouch in controls.buttons
	left := .Left in controls.buttons
	right := .Right in controls.buttons
	switch rope.phase {
	case .None:
		if press && world.rules.rope { // a game without the rope (sv_rope 0) throws nothing
			if soldier.controls.stance == .Prone { // up off the ground first
				res.animation_start(resources.animations, &soldier.pose.legs, .Stand)
				soldier.controls.stance = .Stand
			}
			rope.tip = soldier_pose(resources.animations, soldier, soldier.body.pos)[14] // the rope leaves the hand
			if _, inside := res.inside_solid(world.polymap, rope.tip, false); inside do rope.tip = soldier.body.pos // a hand in a wall throws from the body
			dir := utils.normalize(soldier.controls.aim - soldier.body.pos)
			if dir == (utils.Vec2{}) do dir = {f32(soldier.body.direction), 0} // aiming at oneself
			rope.tip_velocity = dir * ROPE_SPEED
			rope.climb = ROPE_SPEED * ROPE_CLIMB_START // the fresh rope climbs from its first pace
			rope.wraps_count = 0
			rope.phase = .Throwing
		}
	case .Throwing:
		if jet {
			rope_throw(world, soldier)
			if rope.phase == .Throwing {
				if rope_wrap_throw(world, soldier) {
					// the corner it caught redirects the tip's flight around it: the
					// pull along the rope is gone, the swing across it stays
					d := rope.tip - rope.wraps[0]
					if utils.length(d) > 0.001 {
						n := utils.normalize(d)
						rope.tip_velocity -= n * dot(rope.tip_velocity, n)
					}
				}
				rope.length = rope_total_length(soldier)
			}
		} else do rope.phase = .None // let go of before it held: it retracts
	case .Attached:
		if press { // the rope key pressed again cuts it, the swing's momentum kept
			rope.phase = .None
			rope.wraps_count = 0
			emit(out, Rope_Cut{soldier = id, pos = soldier.body.pos})
		} else {
			rope_wrap(world, soldier) // the polygons between it and its owner catch it
			if up {
				rope_climb(soldier)
			} else if down {
				rope_payout(soldier) // and the down key feeds it out again, the same pace
			} else {
				rope.climb = ROPE_SPEED * ROPE_CLIMB_START // a new climb starts from the first pace again
				rope_hold(soldier)
			}
			// left and right with up or down: the diagonal — the climb or the payout
			// carries the swing's sideways push, the roll on
			if rope.phase == .Attached && (left || right) do rope_swing(resources, soldier, left, right)
		}
	}
	controls.was_jet = jet

	// A rope out takes the locomotion away, so the legs stay as the hang poses them — the
	// swing's roll excepted.
	if rope.phase != .None && soldier.pose.body.id != .Roll && soldier.pose.body.id != .Roll_Back {
		soldier_legs_switch(resources.animations, soldier, .Stand if soldier.body.on_ground else .Fall)
	}

	// The rope gone, the roll's slowed pace leaves with it: back on the fall before the
	// animation's slowdown could rob the momentum the cut kept.
	if rope.phase == .None && soldier.pose.legs.speed > 1 && (soldier.pose.legs.id == .Roll || soldier.pose.legs.id == .Roll_Back) {
		soldier_legs_switch(resources.animations, soldier, .Stand if soldier.body.on_ground else .Fall)
	}
}

// Does the segment a-b cross the rope — the hanging part or the part wound around its
// corners? Gives the crossing point. The rope's end is in the owner's hand, as drawn.
rope_crosses :: proc(resources: ^Resources, soldier: ^Soldier, a, b: utils.Vec2) -> (point: utils.Vec2, ok: bool) {
	rope := &soldier.rope
	prev := soldier_pose(resources.animations, soldier, soldier.body.pos)[14]
	for i := int(rope.wraps_count) - 1; i >= -1; i -= 1 {
		next := rope.tip if i < 0 else rope.wraps[i]
		if p, crosses := segments_cross(a, b, prev, next); crosses {
			return p, true
		}
		prev = next
	}
	return {}, false
}

// Cut a soldier's rope: by its own key press, a killing blow, or a bullet that crosses
// it. The Rope_Cut it emits is for the sparks alone.
rope_cut :: proc(world: ^World, id: Soldier_Id, at: utils.Vec2, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	if !soldier.active || soldier.rope.phase == .None do return
	soldier.rope.phase = .None
	soldier.rope.wraps_count = 0
	emit(out, Rope_Cut{soldier = id, pos = at})
}
