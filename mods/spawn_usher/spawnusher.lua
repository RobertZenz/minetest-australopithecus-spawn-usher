--[[
Copyright (c) 2015, Robert 'Bobby' Zenz
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--]]


--- Spawn usher is a system that allows to correct the spawn position of players
-- without knowing anything about the mapgen.
--
-- The system will register callbacks for newplayer and respawnplayer and will
-- try to find an air bubble, either upwards or downwards, which the player can
-- fit into. If an air bubble is found, the player will be moved there. If
-- the block is not loaded, it will be tried again after a certain amount of
-- time.
--
-- The only function that should be called from clients is activate.
spawnusher = {
	players = List:new(),
	required_bubble_size = 2,
	retry_time = 0.5,
	scheduled = false
}


--- Activates the spawn usher system.
--
-- @param require_air_bubble_size Optional. The size/height of the bubble of air
--                                that is required for the player to spawn.
--                                Defaults to 2.
-- @param retry_time Optional. This is the time that passes between tries to
--                   place to the player.
function spawnusher.activate(require_air_bubble_size, retry_time)
	minetest.register_on_newplayer(spawnusher.move_player)
	minetest.register_on_respawnplayer(spawnusher.move_player)
end

--- Tests if the given position is an air bubble big enough.
--
-- @param start_pos The position at which to check.
-- @return true if at the given position is an air bubble big enough.
function spawnusher.is_air_bubble(start_pos)
	local pos = {
		x = start_pos.x,
		y = start_pos.y,
		z = start_pos.z
	}
	
	for counter = 1, spawnusher.required_bubble_size, 1 do
		pos.y = pos.y + 1
		
		if minetest.get_node(pos).name ~= "air" then
			return false
		end
	end
	
	return true
end

--- Schedules the player to be moved later. Also moves the player to the given
-- position.
--
-- @param player The player object.
-- @param current_pos The current position to which the player will be moved.
function spawnusher.move_later(player, current_pos)
	player:setpos(current_pos)
	
	spawnusher.players:add(player)
	
	-- Override the physics of the player to make sure that the player does
	-- not fall while we wait.
	player:set_physics_override({
		speed = 0,
		jump = 0,
		gravity = 0,
		sneak = false,
		sneak_glitch = false
	})
	
	if not spawnusher.scheduled then
		spawnusher.scheduled = true
		
		minetest.after(spawnusher.retry_time, spawnusher.move_players)
	end
end

--- Moves the player to a safe location.
--
-- @param player The player object.
function spawnusher.move_player(player)
	local pos = player:getpos()
	
	-- Could be while true, but at least this is halfway sane.
	while mathutil.in_range(pos.y, -31000, 31000) do
		local current = minetest.get_node(pos).name
		
		if current ~= "air" and current ~= "ignore" then
			-- The current node is neither air nor ignore, that means it
			-- is "solid", so we walk upwards looking for air.
			pos.y = pos.y + 1
		elseif current == "air" then
			-- The current node is air, now we will check if the node below it
			-- is also air, if yes we will move downwards, if not we will check
			-- if here is an air bubble.
			local beneath_pos = {
				x = pos.x,
				y = pos.y - 1,
				z = pos.z
			}
			
			local beneath_node = minetest.get_node(beneath_pos).name
			
			if beneath_node == "air" then
				-- The node below is air, move two downwards looking for
				-- a "solid" node.
				pos.y = pos.y - 2
			elseif beneath_node == "ignore" then
				-- The node below is ignore, means we will have to try again
				-- later.
				spawnusher.move_later(player, pos)
				return
			elseif spawnusher.is_air_bubble(pos) then
				-- Awesome! Place the user here.
				player:setpos(pos)
				
				-- Reset the physics override.
				player:set_physics_override({
					speed = 1,
					jump = 1,
					gravity = 1,
					sneak = true,
					sneak_glitch = true
				})
				
				return
			else
				-- The node beneath is neither air nor ignore and there is no
				-- air bubble big enough, lets go upwards and see if that
				-- helps.
				pos.y = pos.y + 2
			end
		elseif current == "ignore" then
			-- The current node is ignore, which means we need to retry later.
			spawnusher.move_later(player, pos)
			return
		end
	end
end

--- Move all players that could not be placed so far.
function spawnusher.move_players()
	-- Copy the list to make sure that no one adds a player while we iterate
	-- over it. Though, I'm not sure if that is actually possible, but the Java
	-- programmer does not stop to scream "race condition" without this.
	local to_move_players = spawnusher.players
	spawnusher.players = List:new()
	
	to_move_players:foreach(function(player, index)
		spawnusher.move_player(player)
	end)
	
	-- If there are still players that could not be placed, schedule it again.
	if spawnusher.players:size() > 0 then
		minetest.after(spawnusher.retry_time, spawnusher.move_players)
	else
		spawnusher.scheduled = false
	end
end

