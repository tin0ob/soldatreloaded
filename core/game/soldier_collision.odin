package game

import res "../resources"
import "../utils"

// The soldier against the map, in the original's order: the head's two points, the
// feet's two (the second only if the first missed), the swept circle, the corners. What
// a special polygon does to the soldier is a Hit on itself or a Polygon_Effect, never a
// wound given here. And the background polygons, which the things meet the same way.

SURFACE_COEFFICIENT :: utils.Vec2{0.970, 0.970}
CROUCH_RUN_SURFACE_COEFFICIENT :: utils.Vec2{0.850, 0.970}
STAND_SURFACE_COEFFICIENT :: utils.Vec2{0.000, 0.000}

SOLDIER_COLLISION_RADIUS :: f32(3)
SLIDE_LIMIT :: f32(0.2)

// The part the original reports a polygon's wound on; not a real point of the skeleton.
POLYGON_HIT_PART :: 12

// The soldier's two collision areas: the head's points, and the feet's, which stand.
@(private = "file")
Collision_Area :: enum {
	Feet,
	Head,
}

// The whole check against the map, at the end of the soldier's step once it has moved.
soldier_collide :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, authority: ^Authority, out: ^Tick_Output) {
	soldier := &world.soldiers[id]
	body := &soldier.body
	was_grounded := body.on_ground_last // it stood on the ground the tick before: a rope out but still grounded is a throw, not a crash
	body.on_ground = false
	background_test_prepare(&body.background)

	touched :=
		check_map_collision(world, resources, id, body.pos + {-3.5, -12}, .Head, authority, out)
	touched ||= check_map_collision(world, resources, id, body.pos + {3.5, -12}, .Head, authority, out)

	// the trailing leg lifted a little, so walking doesn't catch on slopes
	body_y, arm_s: f32
	left, right := .Left in soldier.controls.buttons, .Right in soldier.controls.buttons
	if left != right {
		if left != (body.direction == 1) {
			arm_s = 0.25
		} else {
			body_y = 0.25
		}
	}
	if body_y == 0 {
		p := body.pos + {2, 1.9}
		if _, blocked := res.ray_cast(world.polymap, p, p, 10); blocked do body_y = 0.25
	}
	if arm_s == 0 {
		p := body.pos + {-2, 1.9}
		if _, blocked := res.ray_cast(world.polymap, p, p, 10); blocked do arm_s = 0.25
	}

	// the feet: the second side only if the first didn't touch
	feet :=
		check_map_collision(world, resources, id, body.pos + {2, 2 - body_y}, .Feet, authority, out) ||
		check_map_collision(world, resources, id, body.pos + {-2, 2 - arm_s}, .Feet, authority, out)
	body.on_ground = feet
	touched ||= feet

	body.on_ground_for_law = check_radius_map_collision(world, resources, id, body.pos + {0, -1}, body.on_ground, authority, out)
	touched ||= body.on_ground_for_law
	corners := check_map_vertices_collision(world, resources, id, body.pos, 3, body.on_ground || body.on_ground_for_law, authority, out)
	touched ||= corners
	body.on_ground = corners || body.on_ground

	// the ground as it has stood two ticks running
	if body.on_ground == body.on_ground_last do body.on_ground_permanent = body.on_ground
	body.on_ground_last = body.on_ground

	background_test_reset(&body.background)

	// A rope breaks the moment its owner's body meets a polygon it wasn't standing on:
	// a swing into a wall, the ground or the ceiling cuts it, and the soldier falls with
	// the momentum kept. Standing still to throw, the feet on the ground, does not.
	if soldier.rope.phase != .None && touched && !was_grounded do rope_cut(world, id, soldier.body.pos, out)

	body.velocity.x = clamp(body.velocity.x, -MAX_VELOCITY, MAX_VELOCITY)
	body.velocity.y = clamp(body.velocity.y, -MAX_VELOCITY, MAX_VELOCITY)
}

// Whether the soldier stands on, or is stopped by, a polygon of this type.
soldier_collides_with :: proc(soldier: ^Soldier, type: res.Polygon_Type) -> bool {
	if type == .Only_Flaggers do return soldier.carrying.held != nil
	if type == .Not_Flaggers do return soldier.carrying.held == nil
	return type != .Doesnt && type != .Only_Bullets && res.object_collides(type, soldier.team)
}

// A point of the soldier, where its velocity takes it, against the map. The feet are
// pushed out and stand; the head only when rising or moving sideways.
@(private = "file")
check_map_collision :: proc(
	world: ^World,
	resources: ^Resources,
	id: Soldier_Id,
	at: utils.Vec2,
	area: Collision_Area,
	authority: ^Authority,
	out: ^Tick_Output,
) -> bool {
	polymap := world.polymap
	soldier := &world.soldiers[id]
	body := &soldier.body
	pos := at + body.velocity

	polygons := res.polygons_near(polymap, pos)
	if len(polygons) == 0 do return false
	background_test_big_polygon(polymap, &body.background, pos)

	for index in polygons {
		polygon := &polymap.polygons[index]
		if !soldier_collides_with(soldier, polygon.type) || !res.point_in_polygon(pos, polygon) do continue
		if background_test(polymap, &body.background, int(index)) do continue

		soldier_touch_polygon(world, resources, id, polygon.type, pos, authority, out)

		normal, distance, _ := res.closest_edge(polygon, pos)
		push := normal * distance
		speed := utils.length(body.velocity)
		if utils.length(push) > speed do push = utils.normalize(push) * speed

		if area == .Feet || (area == .Head && (body.velocity.y < 0 || body.velocity.x > SLIDE_LIMIT || body.velocity.x < -SLIDE_LIMIT)) {
			body.old_pos = body.pos
			body.pos -= push
			if polygon.type == .Bouncy {
				push = utils.normalize(push) * (polygon.bounciness * speed)
				if utils.length(push) > 1 do emit(out, Polygon_Effect{id, .Bouncy, pos, false}) // the thud
			}
			body.velocity -= push
		}
		if area == .Feet do apply_ground_friction(world, soldier, polygon, normal)
		return true
	}
	return false
}

// The ground's grip on the feet: standing still on a slope it holds against gravity.
@(private = "file")
apply_ground_friction :: proc(world: ^World, soldier: ^Soldier, polygon: ^res.Polygon, normal: utils.Vec2) {
	body := &soldier.body
	legs := soldier.pose.legs

	#partial switch legs.id {
	case .Stand, .Crouch, .Prone, .Prone_Move, .Get_Up, .Fall, .Mercy, .Mercy2, .Own, .Yeah:
		if body.velocity.x < SLIDE_LIMIT && body.velocity.x > -SLIDE_LIMIT && normal.y > SLIDE_LIMIT {
			body.pos = body.old_pos
			body.forces.y -= world.gravity
		}
		if normal.y > SLIDE_LIMIT && polygon.type != .Ice && polygon.type != .Bouncy {
			#partial switch legs.id {
			case .Stand, .Fall, .Crouch:
				body.velocity *= STAND_SURFACE_COEFFICIENT
				body.forces.x -= body.velocity.x
			case .Prone:
				if legs.frame > 24 {
					buttons := soldier.controls.buttons
					moving := .Crouch in buttons && (.Left in buttons || .Right in buttons)
					if !moving {
						body.velocity *= STAND_SURFACE_COEFFICIENT
						body.forces.x -= body.velocity.x
					}
				} else {
					body.velocity *= SURFACE_COEFFICIENT
				}
			case .Get_Up:
				body.velocity *= SURFACE_COEFFICIENT
			case .Prone_Move:
				body.velocity *= STAND_SURFACE_COEFFICIENT
			}
		}
	case .Crouch_Run, .Crouch_Run_Back:
		body.velocity *= CROUCH_RUN_SURFACE_COEFFICIENT
	case:
		body.velocity *= SURFACE_COEFFICIENT
	}
}

// A circle swept along the velocity, which catches thin polygons at speed.
@(private = "file")
check_radius_map_collision :: proc(
	world: ^World,
	resources: ^Resources,
	id: Soldier_Id,
	at: utils.Vec2,
	has_collided: bool,
	authority: ^Authority,
	out: ^Tick_Output,
) -> bool {
	polymap := world.polymap
	soldier := &world.soldiers[id]
	body := &soldier.body
	pos := at + {0, -3}
	steps := int(utils.length(body.velocity))
	if steps == 0 do steps = 1
	step := body.velocity * (1.0 / f32(steps))

	for _ in 0 ..< steps {
		pos += step
		for index in res.polygons_near(polymap, pos) {
			polygon := &polymap.polygons[index]
			type := polygon.type

			collides := res.object_collides(type, soldier.team)
			held := soldier.carrying.held != nil
			if (!held && type == .Only_Flaggers) || (held && type == .Not_Flaggers) do collides = false
			if !collides || type == .Doesnt || type == .Only_Bullets do continue

			for k in 0 ..< 3 {
				probe := pos - polygon.normals[k] * SOLDIER_COLLISION_RADIUS
				if !res.point_in_polygon_edges(probe, polygon) do continue
				if background_test(polymap, &body.background, int(index)) do continue
				if !has_collided do soldier_touch_polygon(world, resources, id, type, probe, authority, out)

				normal, _, edge := res.closest_edge(polygon, pos)
				distance := utils.point_line_distance(polygon.vertices[edge], polygon.vertices[(edge + 1) % 3], probe)
				body.pos = body.old_pos
				body.velocity = body.forces - normal * distance
				return true
			}
		}
	}
	return false
}

// Pushes the soldier off the polygons' corners within `radius`.
@(private = "file")
check_map_vertices_collision :: proc(
	world: ^World,
	resources: ^Resources,
	id: Soldier_Id,
	pos: utils.Vec2,
	radius: f32,
	has_collided: bool,
	authority: ^Authority,
	out: ^Tick_Output,
) -> bool {
	polymap := world.polymap
	soldier := &world.soldiers[id]

	for index in res.polygons_near(polymap, pos) {
		polygon := &polymap.polygons[index]
		if !soldier_collides_with(soldier, polygon.type) do continue

		for vertex in polygon.vertices {
			if utils.length(vertex - pos) >= radius do continue
			if background_test(polymap, &soldier.body.background, int(index)) do continue
			if !has_collided do soldier_touch_polygon(world, resources, id, polygon.type, pos, authority, out)
			soldier.body.pos += utils.normalize(pos - vertex)
			return true
		}
	}
	return false
}

// What a special polygon does to a soldier touching it (HandleSpecialPolyTypes). The
// soldier tells of its own wound as a Hit on itself; the map's own bullets are the
// referee's to ask for.
@(private = "file")
soldier_touch_polygon :: proc(
	world: ^World,
	resources: ^Resources,
	id: Soldier_Id,
	type: res.Polygon_Type,
	pos: utils.Vec2,
	authority: ^Authority,
	out: ^Tick_Output,
) {
	soldier := &world.soldiers[id]
	self_hit :: proc(soldier: ^Soldier, id: Soldier_Id, amount: f32, out: ^Tick_Output) {
		emit(out, Hit{shooter = id, target = id, weapon = .Punch, amount = amount, part = POLYGON_HIT_PART, pos = soldier.body.pos, impact = soldier.body.velocity})
	}

	#partial switch type {
	case .Deadly:
		self_hit(soldier, id, 50.0 + soldier.vitals.health, out) // lands it on exactly -50
	case .Bloody_Deadly:
		self_hit(soldier, id, 450.0 + soldier.vitals.health, out) // past a brutal death's health: it gibs
	case .Hurts, .Lava:
		if !soldier.vitals.dead {
			if rng_below(&world.rng, 10) == 0 {
				self_hit(soldier, id, 5.0, out)
				emit(out, Polygon_Effect{id, type, pos, false})
			}
			if soldier.vitals.health < 1 do self_hit(soldier, id, 10.0, out)
		}
		// lava throws up a spark now and then
		if type == .Lava && rng_below(&world.rng, 3) == 0 {
			emit(out, Polygon_Effect{id, .Lava, pos - {0, 3}, true})
			// the C game rolls once more here, with authority, for a flame the lava shoots at
			// the soldier (soldier_shoot with the flamer): the flame went with the flamer,
			// but the roll and the shot it counts stay, so the dice and the shot keys fall
			// as they do there
			if authority != nil && rng_below(&world.rng, 3) == 0 do soldier.arsenal.shot_count += 1
		}
	case .Regenerates:
		if soldier.vitals.health < DEFAULT_HEALTH && world.tick % 12 == 0 {
			self_hit(soldier, id, -2.0, out) // a negative wound heals
			emit(out, Polygon_Effect{id, type, pos, false})
		}
	case .Explodes:
		if !soldier.vitals.dead {
			origin := pos - {0, 3}
			emit(out, Polygon_Effect{id, type, origin, false})
			// the map's own grenade, the server's to fire
			if authority != nil do soldier_shoot(world, resources, id, .M79, origin, {}, resources.weapons[.M79].stats.damage, out)
			self_hit(soldier, id, 4000.0, out)
		}
	case .Hurts_Flaggers:
		if held, holding := soldier.carrying.held.?; !soldier.vitals.dead && holding && thing_is_flag(world.things[held].kind) && rng_below(&world.rng, 10) == 0 {
			self_hit(soldier, id, 10.0, out)
			emit(out, Polygon_Effect{id, type, pos, false})
		}
		if soldier.vitals.health < 1 do self_hit(soldier, id, 10.0, out)
	}
}

// ---------------------------------------------------------------------------------
// The background polygons: walked into from outside they block; once inside, a soldier
// or a thing passes them until it is out of them all again.

// Is the polygon to be passed, as a background polygon?
background_test :: proc(polymap: ^res.Poly_Map, background: ^Background_State, polygon: int) -> bool {
	#partial switch polymap.polygons[polygon].type {
	case .Background:
		if background.in_transition {
			background.test_result = true
			background.polygon = polygon
			return true
		}
	case .Background_Transition:
		background.test_result = true
		background.in_transition = true
		return true
	}
	return false
}

// In transition, whether `pos` is in the background polygon the body is in, the first
// time looking for which.
background_test_big_polygon :: proc(polymap: ^res.Poly_Map, background: ^Background_State, pos: utils.Vec2) {
	if !background.in_transition do return

	switch polygon in background.polygon {
	case nil:
		background.polygon = No_Background{}
		for index in polymap.background_polygons {
			if res.point_in_polygon(pos, &polymap.polygons[index]) {
				background.polygon = int(index)
				background.test_result = true
				break
			}
		}
	case No_Background:
	case int:
		if res.point_in_polygon(pos, &polymap.polygons[polygon]) do background.test_result = true
	}
}

// Around a round of collision checks: none met yet; and if none was met, out of them all.
background_test_prepare :: proc(background: ^Background_State) {
	background.test_result = false
}

background_test_reset :: proc(background: ^Background_State) {
	if background.test_result do return
	background.in_transition = false
	background.polygon = No_Background{}
}
