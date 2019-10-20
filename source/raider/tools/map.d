module raider.tools.map;

import std.conv;
import std.algorithm : cmp;
import std.exception;
import raider.tools.array;
import raider.tools.memory : move, swap;

/**
 * Associative array.
 */
struct Map(K, V, string pred = "")
{
	enum less = pred != "" ? pred : (is(K == string) ? "cmp(a, b) == -1" : "a < b");

	struct Pair { K key; V value; }
	Array!Pair pairs;

	void opAssign(Map!(K, V, pred) that)
	{
		swap(this.pairs, that.pairs);
	}

	void opIndexAssign(V value, K key)
	{
		size_t index;

		if(pairs.find!("i.key", less)(key, index))
			pairs[index].value = value; //Overwrite existing value
		else
		{
			//Add new value
			Pair pair = void;
			move!"xm"(pair.key, key);
			move!"xm"(pair.value, value); 
			pairs.add(pair, index);

			//pairs.add!"cmp(a, b) == -1"(pair);
		}
	}

	ref V opIndex(const K key)
	{
		auto result = key in this;
		if(result) return *result;
		else throw new MapException("'" ~ to!string(key) ~ "' not in map");

		/*
		size_t index;
		if(pairs.find!("i.key", less)(key, index)) 
			return pairs[index].value;
		else
			throw new MapException("'" ~ to!string(key) ~ "' not in map");
		*/
	}

	//Returns a pointer to a value, or null if it wasn't found.
	V* opBinaryRight(string op)(const K key) if(op == "in")
	{
		size_t index;
		return pairs.find!("i.key", less)(key, index) ? &(pairs[index].value) : null;
	}

	bool remove(const K key)
	{
		size_t index;
		if(pairs.find!("i.key", less)(key, index))
		{
			pairs.remove(index);
			return true;
		}
		else return false;
	}
}

final class MapException : Exception
{ import raider.tools.exception; mixin SimpleThis; }

unittest
{

	Map!(string, int) m1;
	m1["i1"] = 3;
	m1["i2"] = 4;
	assert(m1["i1"] == 3);
	assert(m1["i2"] == 4);
	m1["i1"] = 2;
	assert(m1["i1"] == 2);
	assert(("i1" in m1) != null);
	assert(("rubbish" in m1) == null);
	assert(m1.remove("i1"));

	assertThrown!MapException(m1["rubbish"]);

}


/*
		//Allow to find a pair by its key
		bool opEquals(const Pair that) const
		{
			return key == that.key;
		}

		//Allow to sort by key (allows binary search)
		int opCmp(const Pair that) const
		{
			//Use lexicographical case-aware comparison for strings
			static if(is(K == string)) return cmp(key, that.key); 
			else return key.opCmp(that.key); 
		}
		*/

/*
	 * Map!(string, int) must use cmp unless overridden
	 * key doesn't have to implement an opCmp, remember
	 * the 'intended' way is to use the operators
	 * thus we must allow to override sorting
	 * and fields (or even binaryFunc equality checks)
	 */

