---
-- @module Rx
-- @author Quenty

local require = require(game:GetService("ReplicatedStorage"):WaitForChild("Nevermore"))

local Observable = require("Observable")
local Maid = require("Maid")
local Promise = require("Promise")
local Symbol = require("Symbol")

local UNSET_VALUE = Symbol.named("unsetValue")

local Rx = {
	EMPTY = Observable.new(function(fire, fail, complete)
		complete()
		return nil
	end);
	NEVER = Observable.new(function(fire, fail, complete)
		return nil
	end);
}

function Rx.pipe(transformers)
	assert(type(transformers) == "table")
	for index, transformer in pairs(transformers) do
		if type(transformer) ~= "function" then
			error(("[Rx.pipe] Bad pipe value of type %q at index %q, expected function")
				:format(type(transformer), tostring(index)))
		end
	end

	return function(source)
		assert(source)

		local current = source
		for key, transformer in pairs(transformers) do
			current = transformer(current)

			if not (type(current) == "table" and current.ClassName == "Observable") then
				error(("[Rx.pipe] - Failed to transform %q in pipe, made %q (%s)")
					:format(tostring(key), tostring(current), tostring(type(current) == "table" and current.ClassName or "")))
			end
		end

		return current
	end
end

-- http://reactivex.io/documentation/operators/just.html
function Rx.of(...)
	local args = table.pack(...)

	return Observable.new(function(fire, fail, complete)
		for i=1, args.n do
			fire(args[i])
		end

		complete()
	end)
end

-- http://reactivex.io/documentation/operators/from.html
function Rx.from(item)
	if Promise.isPromise(item) then
		return Rx.fromPromise(item)
	elseif type(item) == "table" then
		return Rx.of(unpack(item))
	else
		-- TODO: Iterator?
		error("[Rx.from] - cannot convert")
	end
end

function Rx.merge(observables)
	assert(type(observables) == "table")

	for _, item in pairs(observables) do
		assert(Observable.isObservable(item), "Not an observable")
	end

	return Observable.new(function(fire, fail, complete)
		local maid = Maid.new()

		for _, observable in pairs(observables) do
			maid:GiveTask(observable:Subscribe(fire, fail, complete))
		end

		return maid
	end)
end

function Rx.fromSignal(event)
	return Observable.new(function(fire, fail, complete)
		local maid = Maid.new()
		maid:GiveTask(event:Connect(fire))
		maid:GiveTask(complete)
		return maid
	end)
end

function Rx.fromPromise(promise)
	assert(Promise.isPromise(promise))

	return Observable.new(function(fire, fail, complete)
		if promise:IsFulfilled() then
			fire(promise:Wait())
			complete()
			return nil
		end

		local maid = Maid.new()

		local pending = true
		maid:GiveTask(function()
			pending = false
		end)

		promise:Then(
			function(...)
				if pending then
					fire(...)
					complete()
				end
			end,
			function(...)
				if not pending then
					fail(...)
					complete()
				end
			end)

		return maid
	end)
end

function Rx.tap(firingCallback)
	assert(type(firingCallback) == "function")

	return function(source)
		return Observable.new(function(fire, fail, complete)
			return source:Subscribe(function(...)
				firingCallback(...)
				fire(...)
			end, fail, complete)
		end)
	end
end

-- http://reactivex.io/documentation/operators/start.html
function Rx.start(callback)
	return function(source)
		return Observable.new(function(fire, fail, complete)
			fire(callback())

			return source:Subscribe(fire, fail, complete)
		end)
	end
end

-- Like start, but also from (list!)
function Rx.startFrom(callback)
	assert(type(callback) == "function")
	return function(source)
		return Observable.new(function(fire, fail, complete)
			for _, value in pairs(callback()) do
				fire(value)
			end

			return source:Subscribe(fire, fail, complete)
		end)
	end
end

function Rx.startWith(values)
	assert(type(values) == "table")

	return function(source)
		return Observable.new(function(fire, fail, complete)
			for _, item in pairs(values) do
				fire(item)
			end

			return source:Subscribe(fire, fail, complete)
		end)
	end
end

-- http://reactivex.io/documentation/operators/filter.html
function Rx.where(predicate)
	assert(type(predicate) == "function", "Bad predicate callback")

	return function(source)
		return Observable.new(function(fire, fail, complete)
			return source:Subscribe(
				function(...)
					local maid = Maid.new()

					if predicate(...) then
						fire(...)
					end

					return maid
				end,
				fail,
				complete
			)
		end)
	end
end

-- https://rxjs.dev/api/operators/mapTo
function Rx.mapTo(...)
	local args = table.pack(...)
	return function(source)
		return Observable.new(function(fire, fail, complete)
			return source:Subscribe(function()
				fire(table.unpack(args, 1, args.n))
			end, fail, complete)
		end)
	end
end

-- http://reactivex.io/documentation/operators/map.html
function Rx.map(project)
	assert(type(project) == "function", "Bad project callback")

	return function(source)
		return Observable.new(function(fire, fail, complete)
			return source:Subscribe(function(...)
				fire(project(...))
			end, fail, complete)
		end)
	end
end

-- Merges higher order observables together
function Rx.mergeAll()
	return function(source)
		return Observable.new(function(fire, fail, complete)
			local maid = Maid.new()

			local pendingCount = 0
			local topComplete = false

			maid:GiveTask(source:Subscribe(
				function(observable)
					assert(Observable.isObservable(observable))

					pendingCount = pendingCount + 1

					maid:GiveTask(observable:Subscribe(
						fire, -- Merge each inner observable
						fail, -- Emit failure automatically
						function()
							pendingCount = pendingCount - 1
							if pendingCount == 0 and topComplete then
								complete()
								maid:DoCleaning()
							end
						end))
				end,
				function(...)
					fail(...) -- Also reflect failures up to the top!
					maid:DoCleaning()
				end,
				function()
					topComplete = true
				end))

			return maid
		end)
	end
end

-- Merges higher order observables together
-- https://rxjs.dev/api/operators/switchAll
function Rx.switchAll()
	return function(source)
		return Observable.new(function(fire, fail, complete)
			local outerMaid = Maid.new()
			local topComplete = false
			local insideComplete = false
			local currentInside = nil

			outerMaid:GiveTask(source:Subscribe(
				function(observable)
					assert(Observable.isObservable(observable))

					insideComplete = false
					currentInside = observable
					outerMaid._current = nil

					local maid = Maid.new()
					maid:GiveTask(observable:Subscribe(
						fire, -- Merge each inner observable
						function(...)
							if currentInside == observable then
								fail(...)
							end
						end, -- Emit failure automatically
						function()
							if currentInside == observable then
								insideComplete = true
								if insideComplete and topComplete then
									complete()
									outerMaid:DoCleaning()
								end
							end
						end))

					outerMaid._current = maid
				end,
				function(...)
					fail(...) -- Also reflect failures up to the top!
					outerMaid:DoCleaning()
				end,
				function()
					topComplete = true
					if insideComplete and topComplete then
						complete()
						outerMaid:DoCleaning()
					end
				end))

			return outerMaid
		end)
	end
end

-- Sort of equivalent of promise.then()
function Rx.flatMap(project)
	return Rx.pipe({
		Rx.map(project);
		Rx.mergeAll();
	})
end

function Rx.switchMap(project)
	return Rx.pipe({
		Rx.map(project);
		Rx.switchAll();
	})
end

function Rx.takeUntil(notifier)
	assert(Observable.isObservable(notifier))

	return function(source)
		return Observable.new(function(fire, fail, complete)
			local maid = Maid.new()
			local cancelled = false

			local function cancel()
				maid:DoCleaning()
				cancelled = true
			end

			-- Any value emitted will cancel (complete without any values allows all values to pass)
			maid:GiveTask(notifier:Subscribe(cancel, cancel))

			-- Cancelled immediately? Oh boy.
			if cancelled then
				maid:DoCleaning()
				return nil
			end

			-- Subscribe!
			maid:GiveTask(source:Subscribe(fire, fail, complete))

			return maid
		end)
	end
end

function Rx.packed(...)
	local args = table.pack(...)

	return Observable.new(function(fire, fail, complete)
		fire(unpack(args, 1, args.n))
		complete()
	end)
end

function Rx.unpacked(observable)
	assert(Observable.isObservable(observable))

	return Observable.new(function(fire, fail, complete)
		return observable:Subscribe(function(value)
			if type(value) == "table" then
				fire(unpack(value))
			else
				warn(("[Rx.unpacked] - Observable didn't return a table got type %q")
					:format(type(value)))
			end
		end, fail, complete)
	end)
end

function Rx.combineLatest(observables)
	assert(observables)

	return Observable.new(function(fire, fail, complete)
		if not next(observables) then
			complete()
			return
		end

		local maid = Maid.new()
		local pending = 0

		local latest = {}
		for key, _ in pairs(observables) do
			pending = pending + 1
			latest[key] = UNSET_VALUE
		end

		local function fireIfAllSet()
			for _, item in pairs(latest) do
				if item == UNSET_VALUE then
					return
				end
			end

			fire(unpack(latest))
		end

		for key, observer in pairs(observables) do
			maid:GiveTask(observer:Subscribe(
				function(value)
					latest[key] = value
					fireIfAllSet()
				end,
				function(...)
					pending = pending - 1
					fail(...)
				end,
				function()
					pending = pending - 1
					if pending == 0 then
						complete()
					end
				end))
		end

		return maid
	end)
end

-- http://reactivex.io/documentation/operators/using.html
function Rx.using(resourceFactory, observableFactory)
	return Observable.new(function(fire, fail, complete)
		local maid = Maid.new()

		local resource = resourceFactory()
		maid:GiveTask(resource)

		local observable = observableFactory(resource)
		assert(Observable.isObservable(observable))

		maid:GiveTask(observable:Subscribe(fire, fail, complete))

		return maid
	end)
end

return Rx