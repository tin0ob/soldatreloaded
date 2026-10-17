package rope

// The rope: a soldier of the rope gear throws it on the jet key, and the key let go of
// retracts a rope that never held; a soldier of the jets throws nothing; and rope_cut
// clears the rope and tells the sparks. The mechanics that need the map — the throw
// holding a polygon, the climb, the swing, the wrap — are played by hand in
// tests/compare against the C game. This is the state machine, on ctf_Ash, whatever its
// walls.
//
//   odin run tests/rope

import sa "core:container/small_array"
import "core:fmt"
import "core:os"

import "../../core/game"
import res "../../core/resources"

MAP :: "ctf_Ash"

main :: proc() {
	if os.change_directory("assets") != nil {
		fmt.eprintln("run from the repository's root, where assets/ is")
		os.exit(2)
	}
	g := new(game.Game)
	defer {
		game.game_destroy(g)
		free(g)
	}
	settings := game.DEFAULT_GAME_SETTINGS
	settings.rope = true
	if !game.game_init(g, settings, authority = true) || !game.game_start_round(g, MAP, seed = 1) {
		fmt.eprintln("cannot load", MAP)
		os.exit(2)
	}
	world := &g.world
	rng := game.Rng{7}
	spawn := game.spawn_point(&g.polymap, .Alpha, &rng)

	failed := false
	check :: proc(ok: bool, what: string, failed: ^bool) {
		fmt.printfln("    %-56s %s", what, "ok" if ok else "FAIL")
		if !ok do failed^ = true
	}

	aim := [2]f32{spawn.x + 100, spawn.y - 100}
	commands: [game.MAX_PLAYERS]game.Command

	// a rope soldier's jet press throws the rope
	game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, gear = .Rope, pos = spawn})
	commands[0] = {sequence = 1, buttons = {.Jet}, aim = aim}
	game.game_tick(g, &commands)
	check(world.soldiers[0].rope.phase == .Throwing, "a rope soldier's jet press throws the rope", &failed)

	// let go of the key: a rope that never held retracts
	commands[0] = {sequence = 2, aim = aim}
	game.game_tick(g, &commands)
	check(world.soldiers[0].rope.phase == .None, "letting the key go retracts a rope that hasn't held", &failed)

	// a jets soldier throws nothing
	game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, gear = .Jets, pos = spawn})
	commands[0] = {sequence = 3, buttons = {.Jet}, aim = aim}
	game.game_tick(g, &commands)
	check(world.soldiers[0].rope.phase == .None, "a jets soldier's jet press throws nothing", &failed)

	// rope_cut clears the rope and emits the spark
	game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, gear = .Rope, pos = spawn})
	soldier := &world.soldiers[0]
	soldier.rope = {phase = .Attached, tip = spawn + {40, 0}, length = 40, grab = 40}
	game.clear_output(&g.output)
	game.rope_cut(world, 0, spawn, &g.output)
	cut := false
	for event in sa.slice(&g.output.events) {
		if _, is_cut := event.(game.Rope_Cut); is_cut do cut = true
	}
	check(soldier.rope.phase == .None && cut, "rope_cut clears the rope and tells the sparks", &failed)

	// standing still to throw: the feet on the ground do not break the rope
	game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, gear = .Rope, pos = spawn})
	for tick in 0 ..< 120 {
		commands[0] = {sequence = u32(tick + 1), aim = aim}
		game.game_tick(g, &commands)
	}
	commands[0] = {sequence = 121, buttons = {.Jet}, aim = aim}
	game.game_tick(g, &commands)
	check(world.soldiers[0].rope.phase == .Throwing, "standing to throw still throws", &failed)

	// but a rope out breaks the moment the body meets a polygon it wasn't standing on
	s := &world.soldiers[0]
	s.rope = {phase = .Attached, tip = s.body.pos + {0, -10}, length = 10, grab = 10}
	s.body.on_ground_last = false
	commands[0] = {sequence = 122, aim = aim}
	game.game_tick(g, &commands)
	check(s.rope.phase == .None, "the body meeting a polygon breaks the rope", &failed)

	// a game without the rope throws nothing, whatever the gear
	g.settings.rope = false
	game.game_start_round(g, MAP, seed = 1)
	world = &g.world
	game.apply_ruling(world, &g.resources, game.Respawn{target = 0, team = .Alpha, primary = .AK74, secondary = .USSOCOM, gear = .Rope, pos = spawn})
	commands[0] = {sequence = 1, buttons = {.Jet}, aim = aim}
	game.game_tick(g, &commands)
	check(world.soldiers[0].rope.phase == .None, "with the rope off a rope soldier throws nothing", &failed)

	if failed {
		fmt.println("\nFAIL")
		os.exit(1)
	}
	fmt.println("\nthe rope throws and retracts, never for a jets soldier or a game without it, and cuts cleanly")
}
