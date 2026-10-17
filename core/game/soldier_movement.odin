package game

import res "../resources"
import "../utils"

// The control state machines: the input, to the animations, to the forces.
//
// Two coupled machines drive a soldier, each on an animation: the legs (stand, run,
// jump, crouch, prone, roll, fall...) and the body (stand, aim, recoil, reload, change,
// throw, roll...). Lying down blocks the legs' moves until the get-up runs; rolls force
// the two into step; a body animation done with falls back to the stance's pose; and the
// stance itself follows the legs.
//
// The moves are made in a fixed order each tick, the original's ControlSoldier's, and
// the feel depends on it:
//
//   left and right -> the jets -> the weapon -> prone -> the Barrett's
//   bolt -> the slowdown -> cover -> an antic cut short -> the locomotion -> the reload
//   -> the rolls -> the body's pose -> the sniper view

// The speeds are folded in double and narrowed once, as the C game's are.
RUN_SPEED :: f32(0.118)
RUN_SPEED_UP :: f32(0.118 / 6)
FLY_SPEED :: f32(0.03)
JUMP_SPEED :: f32(0.66)
CROUCH_RUN_SPEED :: f32(0.118 / 0.6)
PRONE_SPEED :: f32(0.118 * 4.0)
ROLL_SPEED :: f32(0.118 / 1.2)
JUMP_DIRECTION_SPEED :: f32(0.30)
JET_SPEED :: f32(0.10)
SOLDIER_RADIUS :: f32(16) // a crouched teammate counts as cover this near

MAX_VELOCITY :: f32(11) // the safety clamp on a soldier's speed, each way

// The sniper view (Control.pas AimDistCoef): how far the camera leads toward the aim.
SNIPER_AIM_DISTANCE :: f32(3.5) // scoped prone
CROUCH_AIM_DISTANCE :: f32(4.5) // scoped crouching
AIM_DISTANCE_STEP :: f32(0.05) // a tick, toward either

// One tick's input, left and right held together resolved to one. `prone` is a press,
// spent when it lays the soldier down.
@(private = "file")
Control_Input :: struct {
	left, right, up, down, jet, prone: bool,
	pressed_left_right:                bool, // both were held
}

// The controls step: this tick's input through the state machines, in the original's
// order. `armed` as soldier_update's.
soldier_control :: proc(world: ^World, resources: ^Resources, id: Soldier_Id, authority: ^Authority, out: ^Tick_Output, armed: bool) {
	soldier := &world.soldiers[id]
	if soldier.pose.legs.speed < 1 do soldier.pose.legs.speed = 1
	if soldier.pose.body.speed < 1 do soldier.pose.body.speed = 1
	soldier.arsenal.fired = false // set again by the weapon if a shot goes off this tick

	input := resolve_left_right(soldier)
	if soldier.gear == .Rope do rope_control(world, resources, id, soldier, out)
	else do jets_control(world, resources, soldier, input)
	if armed do combat_control(world, resources, id, out)
	// A rope out takes the locomotion away: hung, reeled, or throwing, the soldier
	// doesn't lie down, cover-check, walk or roll (the weapon still works). Each step
	// stays in its place in the original's order, so a soldier without a rope out moves
	// exactly as before.
	afoot := soldier.rope.phase == .None
	if afoot {
		prone_control(resources, soldier, &input)
		if armed do combat_after_prone(resources, soldier)
	}
	animation_slowdown(soldier)
	if afoot do cover_check(world, resources, id)
	antics_interrupt(resources.animations, soldier, input)
	if afoot do movement_control(world, resources, soldier, input)
	if armed do combat_reload_animation(resources, soldier)
	if afoot do roll_control(resources, soldier, input)
	body_pose_control(resources, soldier)
	sniper_view(soldier)
}

// A move of the legs, unless lying down: only the get-up leaves Prone.
soldier_legs_switch :: proc(animations: ^res.Animations, soldier: ^Soldier, id: res.Animation_Id, frame: i32 = 1) {
	legs := &soldier.pose.legs
	if legs.id == .Prone || legs.id == .Prone_Move do return
	res.animation_switch(animations, legs, id, frame)
}

// Left and right held together keep the way the soldier went while jumping, else turn
// it; the buttons are changed to say so, for everything after to agree.
@(private = "file")
resolve_left_right :: proc(soldier: ^Soldier) -> (input: Control_Input) {
	controls := &soldier.controls
	if .Left in controls.buttons && .Right in controls.buttons {
		input.pressed_left_right = true
		if controls.was_jumping == controls.was_running_left {
			controls.buttons -= {.Right}
		} else {
			controls.buttons -= {.Left}
		}
	} else {
		controls.was_running_left = .Left in controls.buttons
		controls.was_jumping = .Jump in controls.buttons
	}
	input.left = .Left in controls.buttons
	input.right = .Right in controls.buttons
	input.up = .Jump in controls.buttons
	input.down = .Crouch in controls.buttons
	input.jet = .Jet in controls.buttons
	input.prone = .Prone in controls.buttons
	return
}

// The jets: against a side jump's way, a backflip; else the thrust.
@(private = "file")
jets_control :: proc(world: ^World, resources: ^Resources, soldier: ^Soldier, input: Control_Input) {
	animations := resources.animations
	legs, body := &soldier.pose.legs, &soldier.pose.body
	direction := soldier.body.direction

	against_side_jump :=
		legs.id == .Jump_Side && ((direction == -1 && input.right) || (direction == 1 && input.left) || input.pressed_left_right)
	backflip := input.jet && (against_side_jump || (legs.id == .Roll_Back && input.up))

	if backflip {
		res.animation_switch(animations, body, .Roll_Back)
		soldier_legs_switch(animations, soldier, .Roll_Back)
	} else if input.jet && soldier.body.jet_fuel > 0 {
		jet_force := JET_SPEED if world.gravity > 0.05 else world.gravity * 2.0
		if soldier.body.on_ground {
			soldier.body.forces.y = -2.5 * jet_force
		} else if soldier.controls.stance != .Prone {
			soldier.body.forces.y -= jet_force
		} else {
			soldier.body.forces.x += f32(direction) * jet_force / 2.0
		}

		if legs.id != .Get_Up && body.id != .Roll && body.id != .Roll_Back {
			soldier_legs_switch(animations, soldier, .Fall)
		}
		soldier.body.jet_fuel -= 1
		if soldier.body.jet_fuel == 1 do soldier.body.jet_fuel = 0 // the last unit is spent outright while held
	}
}

@(private = "file")
body_busy_with_weapon :: proc(id: res.Animation_Id) -> bool {
	return id == .Reload || id == .Change || id == .Throw_Weapon
}

// Lying down and getting up; the get-up near its end is a jump's wind-up too.
@(private = "file")
prone_control :: proc(resources: ^Resources, soldier: ^Soldier, input: ^Control_Input) {
	animations := resources.animations
	legs, body := &soldier.pose.legs, &soldier.pose.body

	if input.prone && legs.id != .Get_Up && legs.id != .Prone && legs.id != .Prone_Move {
		soldier_legs_switch(animations, soldier, .Prone)
		if !body_busy_with_weapon(body.id) do res.animation_switch(animations, body, .Prone)
		soldier.body.old_direction = soldier.body.direction
		input.prone = false
	}

	// up again: prone pressed again, or turning round
	if soldier.controls.stance == .Prone &&
	   (input.prone || soldier.body.direction != soldier.body.old_direction) &&
	   ((legs.id == .Prone && legs.frame > 23) || legs.id == .Prone_Move) {
		if legs.id != .Get_Up do res.animation_start(animations, legs, .Get_Up, 9)
		if !body_busy_with_weapon(body.id) do res.animation_switch(animations, body, .Get_Up, 9)
	}

	unprone := false
	if legs.id == .Get_Up && legs.frame > 20 && soldier.body.on_ground && input.up {
		if input.left || input.right {
			soldier_legs_switch(animations, soldier, .Jump_Side, legs.frame - 20)
		} else {
			soldier_legs_switch(animations, soldier, .Jump, legs.frame - 15)
		}
		unprone = true
	} else if legs.id == .Get_Up && legs.frame > 23 {
		if input.left || input.right {
			soldier_legs_switch(animations, soldier, run_animation(soldier, !input.left))
		} else if !soldier.body.on_ground && input.up {
			soldier_legs_switch(animations, soldier, .Run)
		} else {
			soldier_legs_switch(animations, soldier, .Stand)
		}
		unprone = true
	}
	if unprone {
		soldier.controls.stance = .Stand
		if !body_busy_with_weapon(body.id) do res.animation_switch(animations, body, .Stand)
	}
}

// Running the way it faces, or backwards.
@(private = "file")
run_animation :: proc(soldier: ^Soldier, rightwards: bool) -> res.Animation_Id {
	return .Run if (soldier.body.direction == 1) == rightwards else .Run_Back
}

// Every 10 ticks, how near the muzzle is to cover (Control.pas): 8 along the arm from 5
// over the head, against the map's colliders and crouched teammates.
@(private = "file")
cover_check :: proc(world: ^World, resources: ^Resources, id: Soldier_Id) {
	if world.tick % 10 != 0 do return
	soldier := &world.soldiers[id]
	soldier.aim.collider_distance = 255

	joints := soldier_pose(resources.animations, soldier, soldier.body.pos)
	arm := utils.normalize(joints[14] - joints[15]) * 8.0
	probe := joints[11] - utils.Vec2{0, 5} + arm

	for collider in world.polymap.colliders {
		if !collider.active do continue
		distance := utils.length(probe - collider.pos)
		if distance < collider.radius {
			soldier.aim.collider_distance = u8(utils.round_half_even(min(distance, 253)))
			break
		}
	}

	if soldier.team == .None || soldier.team == .Spectator do return
	for &other, i in world.soldiers {
		if Soldier_Id(i) == id || !other.active || other.team != soldier.team || other.controls.stance != .Crouch do continue
		distance := utils.length(probe - other.body.pos)
		if distance < SOLDIER_RADIUS {
			soldier.aim.collider_distance = u8(utils.round_half_even(min(distance, 253)))
			break
		}
	}
}

// An animation played faster than its pace slows the movement down.
@(private = "file")
animation_slowdown :: proc(soldier: ^Soldier) {
	legs := &soldier.pose.legs
	// A rope out: the roll's slowed pace is a pose, not speeded-up play — it must not
	// rob the swing's or the climb's momentum.
	if soldier.rope.phase != .None || legs.speed <= 1 do return

	#partial switch legs.id {
	case .Jump, .Jump_Side, .Roll, .Roll_Back, .Prone, .Run, .Run_Back:
		soldier.body.velocity /= f32(legs.speed)
	}
	if legs.speed > 2 && (legs.id == .Prone_Move || legs.id == .Crouch_Run) {
		soldier.body.velocity /= f32(legs.speed)
	}
}

// A key pressed ends an idle antic at once (Control.pas): on its last frame, the body's
// pose takes the stance's back.
@(private = "file")
antics_interrupt :: proc(animations: ^res.Animations, soldier: ^Soldier, input: Control_Input) {
	body := &soldier.pose.body
	antic := body.id == .Cigar || body.id == .Match || body.id == .Smoke || body.id == .Wipe || body.id == .Groin
	keys :: Buttons{.Fire, .Throw, .Change, .Drop, .Reload}
	pressed := input.left || input.right || input.up || input.down || input.jet || input.prone || soldier.controls.buttons & keys != {}
	if antic && pressed do body.frame = animations[body.id].frame_count
}

// Locomotion: one move wins a tick, in this order: rolling, the crouch-run, the crawl,
// the side jump, the jump, the crouch, the run, standing. Some body poses freeze it.
@(private = "file")
movement_control :: proc(world: ^World, resources: ^Resources, soldier: ^Soldier, input: Control_Input) {
	animations := resources.animations
	legs, body := &soldier.pose.legs, &soldier.pose.body

	#partial switch body.id {
	case .Take_Off, .Piss, .Mercy, .Mercy2, .Victory, .Own, .Breakdown, .Dab, .Yeah:
		return
	}

	sideways := input.left || input.right
	lying := legs.id == .Prone || legs.id == .Prone_Move || (legs.id == .Get_Up && body.id != .Throw && body.id != .Punch)

	switch {
	case body.id == .Roll || body.id == .Roll_Back:
		move_rolling(soldier, input)
	case sideways && input.down:
		move_crouch_run(animations, soldier, input)
	case lying:
		move_prone(animations, soldier, input)
	case sideways && input.up:
		move_side_jump(animations, soldier, input)
	case input.up:
		move_jump(animations, soldier)
	case input.down:
		if soldier.body.on_ground do soldier_legs_switch(animations, soldier, .Crouch)
	case sideways:
		move_run(world, animations, soldier, input)
	case:
		soldier_legs_switch(animations, soldier, .Stand if soldier.body.on_ground else .Fall)
	}
}

// A roll pushes the way it faces; a backward roll can be jumped out of.
@(private = "file")
move_rolling :: proc(soldier: ^Soldier, input: Control_Input) {
	legs := &soldier.pose.legs
	body := &soldier.body
	dir := f32(body.direction)

	if legs.id == .Roll {
		body.forces.x = dir * ROLL_SPEED if body.on_ground else dir * 2.0 * FLY_SPEED
	} else if legs.id == .Roll_Back {
		body.forces.x = -dir * ROLL_SPEED if body.on_ground else -dir * 2.0 * FLY_SPEED
		if legs.frame > 1 && legs.frame < 8 && input.up {
			body.forces.y -= f32(0.30 * 1.5) // JUMP_DIRECTION_SPEED * 1.5
			body.forces.x *= 0.5
			body.velocity.x *= 0.8
		}
	}
}

// Crouching while running: a roll out of a run or a fall, else the crouch-run.
@(private = "file")
move_crouch_run :: proc(animations: ^res.Animations, soldier: ^Soldier, input: Control_Input) {
	legs, body := &soldier.pose.legs, &soldier.pose.body
	if !soldier.body.on_ground do return

	sign: f32 = 1 if input.right else -1
	facing_move := (soldier.body.direction == 1) == input.right
	can_roll :=
		legs.id == .Run || legs.id == .Run_Back || legs.id == .Fall || legs.id == .Prone_Move || (legs.id == .Prone && legs.frame >= 24)

	if can_roll {
		if legs.id == .Prone_Move || (legs.id == .Prone && legs.frame == animations[.Prone].frame_count) {
			soldier.controls.stance = .Stand
		}
		roll: res.Animation_Id = .Roll if facing_move else .Roll_Back
		res.animation_switch(animations, body, roll)
		res.animation_start(animations, legs, roll)
	} else {
		soldier_legs_switch(animations, soldier, .Crouch_Run if facing_move else .Crouch_Run_Back)
	}

	if legs.id == .Crouch_Run || legs.id == .Crouch_Run_Back {
		soldier.body.forces.x = sign * CROUCH_RUN_SPEED
	} else if legs.id == .Roll || legs.id == .Roll_Back {
		soldier.body.forces.x = sign * 2.0 * CROUCH_RUN_SPEED
	}
}

// Lying down: crawling, or holding still at the end of going prone.
@(private = "file")
move_prone :: proc(animations: ^res.Animations, soldier: ^Soldier, input: Control_Input) {
	legs, body := &soldier.pose.legs, &soldier.pose.body
	if !soldier.body.on_ground do return
	if !((legs.id == .Prone && legs.frame > 25) || legs.id == .Prone_Move) do return

	if input.left || input.right {
		if legs.frame < 4 || legs.frame > 14 do soldier.body.forces.x = -PRONE_SPEED if input.left else PRONE_SPEED
		soldier_legs_switch(animations, soldier, .Prone_Move)
		#partial switch body.id {
		case .Clip_In, .Clip_Out, .Slide_Back, .Reload, .Change, .Throw, .Throw_Weapon:
		case:
			res.animation_switch(animations, body, .Prone_Move)
		}
		if legs.id != .Prone_Move do res.animation_start(animations, legs, .Prone_Move)
	} else {
		if legs.id != .Prone do res.animation_start(animations, legs, .Prone)
		legs.frame = 26
	}
}

@(private = "file")
move_side_jump :: proc(animations: ^res.Animations, soldier: ^Soldier, input: Control_Input) {
	legs := &soldier.pose.legs
	sign: f32 = 1 if input.right else -1

	if soldier.body.on_ground {
		#partial switch legs.id {
		case .Run, .Run_Back, .Stand, .Crouch, .Crouch_Run, .Crouch_Run_Back:
			soldier_legs_switch(animations, soldier, .Jump_Side)
		}
		if legs.frame == animations[legs.id].frame_count do soldier_legs_switch(animations, soldier, .Run)
	} else if legs.id == .Roll || legs.id == .Roll_Back {
		soldier_legs_switch(animations, soldier, run_animation(soldier, input.right))
	}

	if legs.id == .Jump && legs.frame < 10 do soldier_legs_switch(animations, soldier, .Jump_Side)
	if legs.id == .Jump_Side && legs.frame > 3 && legs.frame < 11 {
		soldier.body.forces = {sign * JUMP_DIRECTION_SPEED, f32(-0.30 / 1.2)} // -JUMP_DIRECTION_SPEED / 1.2
	}
}

@(private = "file")
move_jump :: proc(animations: ^res.Animations, soldier: ^Soldier) {
	legs := &soldier.pose.legs
	if soldier.body.on_ground {
		soldier_legs_switch(animations, soldier, .Jump)
		if legs.frame == animations[legs.id].frame_count do soldier_legs_switch(animations, soldier, .Stand)
	}
	if legs.id == .Jump {
		if legs.frame > 8 && legs.frame < 15 do soldier.body.forces.y = -JUMP_SPEED
		if legs.frame == animations[.Jump].frame_count do soldier_legs_switch(animations, soldier, .Fall)
	}
}

// Under a parachute the legs don't run: the key steers the canopy, which is the things'
// to pull (the original writes the held thing's forces from here).
@(private = "file")
move_run :: proc(world: ^World, animations: ^res.Animations, soldier: ^Soldier, input: Control_Input) {
	sign: f32 = 1 if input.right else -1
	if !soldier.carrying.parachuting {
		soldier_legs_switch(animations, soldier, run_animation(soldier, input.right))
	} else if held, holding := soldier.carrying.held.?; holding {
		things_ask(world, Parachute_Steer{thing = held, way = 1 if input.right else -1})
	}
	if soldier.body.on_ground {
		soldier.body.forces = {sign * RUN_SPEED, -RUN_SPEED_UP}
	} else {
		soldier.body.forces.x = sign * FLY_SPEED
	}
}

// Rolls run on both machines in step: whichever started, the other follows.
@(private = "file")
roll_control :: proc(resources: ^Resources, soldier: ^Soldier, input: Control_Input) {
	animations := resources.animations
	legs, body := &soldier.pose.legs, &soldier.pose.body

	if legs.id == .Roll && body.id != .Roll do res.animation_switch(animations, body, .Roll)
	if body.id == .Roll && legs.id != .Roll do soldier_legs_switch(animations, soldier, .Roll)
	if legs.id == .Roll_Back && body.id != .Roll_Back do res.animation_switch(animations, body, .Roll_Back)
	if body.id == .Roll_Back && legs.id != .Roll_Back do soldier_legs_switch(animations, soldier, .Roll_Back)

	rolling := body.id == .Roll || body.id == .Roll_Back
	if rolling && legs.frame != body.frame {
		if legs.frame > body.frame {
			body.frame = legs.frame
		} else {
			legs.frame = body.frame
		}
	}

	if rolling && body.frame == animations[body.id].frame_count {
		backflip := !soldier.body.on_ground && body.id == .Roll_Back && input.up
		if backflip {
			if input.left || input.right {
				soldier_legs_switch(animations, soldier, run_animation(soldier, !input.left))
			} else {
				soldier_legs_switch(animations, soldier, .Fall)
			}
		} else if input.down {
			if input.left || input.right {
				soldier_legs_switch(animations, soldier, .Crouch_Run if body.id == .Roll else .Crouch_Run_Back)
			} else {
				soldier_legs_switch(animations, soldier, .Crouch, 15)
			}
		}
		res.animation_switch(animations, body, .Stand)
	}
}

// The body animations the stance's pose may replace at any frame.
@(private = "file")
body_idle_animation :: proc(id: res.Animation_Id) -> bool {
	#partial switch id {
	case .Recoil, .Small_Recoil, .Aim_Recoil, .Hands_Up_Recoil, .Shotgun, .Barret, .Change, .Throw_Weapon, .Weapon_None,
	     .Punch, .Roll, .Roll_Back, .Cigar, .Match, .Smoke, .Wipe, .Take_Off, .Groin, .Piss, .Mercy, .Mercy2,
	     .Victory, .Own, .Breakdown, .Dab, .Yeah, .Reload, .Prone, .Get_Up, .Prone_Move, .Melee:
		return false
	}
	return true
}

// A body animation done with falls back to the stance's pose (a replaceable one at
// once); and the stance follows the legs.
@(private = "file")
body_pose_control :: proc(resources: ^Resources, soldier: ^Soldier) {
	animations := resources.animations
	legs, body := &soldier.pose.legs, &soldier.pose.body
	weapon := &soldier.arsenal.primary

	returns_to_stance :=
		(.Throw not_in soldier.controls.buttons && body_idle_animation(body.id)) ||
		(body.frame == animations[body.id].frame_count && body.id != .Prone) ||
		(weapon.fire_count == 0 && body.id == .Barret)

	if weapon.ammo > 0 && returns_to_stance {
		switch soldier.controls.stance {
		case .Stand:
			res.animation_switch(animations, body, .Stand)
		case .Crouch:
			// near cover the gun comes up over it; out of a recoil it picks up partway
			if soldier.aim.collider_distance < 255 {
				res.animation_switch(animations, body, .Hands_Up_Aim, 11 if body.id == .Hands_Up_Recoil else 1)
			} else {
				res.animation_switch(animations, body, .Aim, 6 if body.id == .Aim_Recoil else 1)
			}
		case .Prone:
			res.animation_switch(animations, body, .Prone, 26)
		}
	}

	#partial switch legs.id {
	case .Crouch, .Crouch_Run, .Crouch_Run_Back:
		soldier.controls.stance = .Crouch
	case .Prone, .Prone_Move:
		soldier.controls.stance = .Prone
	case:
		soldier.controls.stance = .Stand
	}
}

// The sniper view (Control.pas): the Barrett ready, from a crouch or prone, aiming near
// the view's edge draws the camera out toward the aim a step a tick, further prone than
// crouching; aiming back near lets it return. Anything else snaps it back.
@(private = "file")
sniper_view :: proc(soldier: ^Soldier) {
	weapon := soldier.arsenal.primary
	body := soldier.pose.body
	aim := &soldier.aim
	scoping := weapon.weapon == .Barrett && weapon.fire_count == 0 && (body.id == .Prone || body.id == .Aim)
	if !scoping {
		aim.distance = DEFAULT_AIM_DISTANCE
		return
	}
	dx := abs(soldier.controls.aim.x - soldier.body.pos.x)
	dy := abs(soldier.controls.aim.y - soldier.body.pos.y)
	if dx >= f32(640) / f32(1.035) || dy >= f32(480) / f32(1.035) {
		if body.id == .Prone && aim.distance > SNIPER_AIM_DISTANCE do aim.distance -= AIM_DISTANCE_STEP
		if body.id == .Aim && aim.distance > CROUCH_AIM_DISTANCE do aim.distance -= 2 * AIM_DISTANCE_STEP
	}
	if dx < f32(640) / f32(1.5) && dy < f32(480) / f32(1.5) && aim.distance < DEFAULT_AIM_DISTANCE {
		aim.distance += AIM_DISTANCE_STEP
		if aim.distance > DEFAULT_AIM_DISTANCE - AIM_DISTANCE_STEP / 2 do aim.distance = DEFAULT_AIM_DISTANCE
	}
}
