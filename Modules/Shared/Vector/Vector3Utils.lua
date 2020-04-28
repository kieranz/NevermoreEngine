---
-- @module Vector3Utils

local Vector3Utils = {}

function Vector3Utils.fromVector2XY(vector2)
	return Vector3.new(vector2.x, vector2.y, 0)
end

function Vector3Utils.fromVector2XZ(vector2)
	return Vector3.new(vector2.x, 0, vector2.y)
end

function Vector3Utils.getAngleRad(offset, lookVector)
	if offset.magnitude == 0 then
		return nil
	end

	return math.acos(offset.unit:Dot(lookVector))
end

return Vector3Utils