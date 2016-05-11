module raider.tools.bag;

import raider.tools.array;
import raider.tools.parallel;
import raider.tools.reference;
import std.algorithm : swap;
import core.atomic;
import core.stdc.string : memcpy;

/**
 * Low-level concurrent bag.
 * 
 * Bag accepts items in parallel and makes them available 
 * later in parallel. Use with tools.parallel. Using Bag from threads
 * created elsewhere results in an exception.
 * 
 * This implementation uses 'pockets', that is, many 
 * small bags that share the same backing store.
 * 
 * Usage:
 * 1. add() in parallel
 * 2. finish() in one thread
 * 3. read pockets (in parallel if desired)
 * 4. bag.clear() in one thread
 * 5. pocket.clear() for all pockets (in parallel if desired)
 * 
 * finish() merges worker-local lists and updates pockets
 * so they point into the merged list. clear() destroys
 * all items and invalidates pockets.
 * 
 * Warning: Magic is dangerous.
 * Bag is low-level and not at all safe.
 * Pockets are dangerous little things.
 * Only access them when you know they are valid.
 * There is no way to check if a pocket is valid.
 */
class Bag(T)
{private:
	Array!T data;
	Array!(Array!(Tag!T)) workerData;

public:

	this()
	{
		workerData.size = tidMax;
		data.cached = true;
		foreach(tags; workerData) tags.cached = true;
	}

	/**
	 * Add an item to the bag in a specified pocket.
	 */
	void add()(auto ref T item, ref Pocket!T pocket)
	{
		assert(pocket.data == null);

		atomicOp!"+="(pocket.size, 1);
		Tag!T tag; tag.pocket = &pocket; swap(tag.item, item);
		workerData[tid].add(tag);
	}

	void finish()
	{
		//Preallocate merged array
		size_t x = 0;
		foreach(ref tags; workerData) x += tags.size;
		data.createRaw(0, x); 

		//Move items
		x = 0;
		foreach(ref tags; workerData)
		{
			foreach(ref tag; tags)
			{
				auto pocket = tag.pocket;
				assert(pocket.merged < pocket.size);

				//Allocate data
				if(pocket.data is null)
				{
					pocket.data = data.ptr + x;
					x += pocket.size;
				}

				//Move item to merged array
				memcpy(pocket.data + pocket.merged, &tag.item, T.sizeof);
				pocket.merged++;
			}
		}

		//Clean up worker arrays
		foreach(ref tags; workerData) tags.destroyRaw(0, tags.size);
	}

	void clear()
	{
		data.clear();
	}
}

private struct Tag(T)
{
	Pocket!T* pocket;
	T item;
}

struct Pocket(T)
{private:
	shared uint size; //Number of items in this pocket
	uint merged; //Counts items as they are moved from worker storage to the merged array
	T* data; //Pointer into the merged array

public:
	void clear()
	{
		size = 0;
		merged = 0;
		data = null;
	}

	T[] opSlice() { return data[0..size]; }
	const(T)[] opSlice() const { return data[0..size]; }
}

unittest
{
	auto bag = New!(Bag!uint);
	Pocket!uint a, b, c;

	foreach(foo; 0..10)
	{
		bag.add(5, a);
		bag.add(4, a);
		bag.add(1, b);
		bag.add(9, c);
		bag.add(9, c);

		bag.finish;

		assert(a[].length == 2);
		assert(b[].length == 1);
		assert(c[].length == 2);
		assert(bag.data.length == 5);

		uint x;
		foreach(i; a) x += i;
		assert(x == 9);

		foreach(i; b) x += i;
		assert(x == 10);

		foreach(i; c) x += i;
		assert(x == 28);

		bag.clear;
		a.clear;
		b.clear;
		c.clear;
	}
}
