module raider.tools.array;

import raider.tools.reference;
import core.stdc.stdlib;
import core.memory;
import std.conv;
import core.stdc.string : memcpy, memmove;
import std.traits;
import std.algorithm : swap, initializeAll;
static import std.algorithm;
import std.functional : binaryFun;
import std.bitmanip;

/**
 * Array stores items in contiguous memory.
 * 
 * Items must tolerate being moved without consultation. How perfectly awful!
 * 
 * Items will be registered with the GC if they contain aliasing.
 * The Array struct itself contains no aliasing the GC needs to know about.
 * 
 * References into the array are valid until the next mutating method call.
 * Item order is maintained during mutations unless otherwise noted.
 */
struct Array(T)
{package:
	T* data = null;
	size_t _size = 0; //Number of items stored

	union 
	{
		uint _other = 0;
		mixin(bitfields!
		(
			bool, "_cached", 1, //capacity cannot decrease
			bool, "_moved", 1, 
			uint, "_log", 6, //log2 of capacity
			uint, "", 24, //free parking
		)); 
	}

public:

	//Construct from variadic item list
	//Recursive form allows the items to be implicitly coerced, e.g., int literals to uint.
	this()() { }
	this(L...)(T item, L list)
	{
		add(item); this(list);
	}

	//Construct a deep copy. Invokes item copy constructor
	this(this)
	{
		T* that_data = data;
		size_t that_size = size;

		data = null;
		_size = 0;
		_log = 0;

		createRaw(0, that_size);
		memcpy(data, that_data, T.sizeof * that_size);
		postblitRange(0, that_size);
	}
	
	~this()
	{
		clear;
	}
	
	void opAssign(Array!T that)
	{
		swap(data, that.data);
		swap(_size, that._size);
		swap(_other, that._other);
	}

	@property T* ptr() { return data; }
	@property size_t capacity() const { return _log ? 1 << _log : 0; }
	@property size_t size() const { return _size; }
	
	/**
	 * Set array size.
	 * 
	 * New items are initialised to T.init, lost items are destroyed.
	 */
	@property void size(size_t value)
	{
		if(value == _size) return;
		if(value > _size) create(_size, value - _size);
		else destroy(value, _size - value);
	}

	alias size length;

	@property bool cached() { return _cached; }
	@property void cached(bool value) { _cached = value; }

	/**
	 * If true, item locations were indirectly changed by method calls since the last reset to false.
	 * The movement of explicitly affected items is not included.
	 */
	@property bool moved() { return _moved; }
	@property void moved(bool value) { _moved = value; }

	bool opEquals(const T[] that)
	{
		return data[0.._size] == that;
	}

	bool opEquals(const Array!T that)
	{
		return data[0.._size] == that[];
	}

	ref T opIndex(in size_t i)
	{
		assert(i < _size, "Index [ " ~ to!string(i) ~ "] is out of bounds. Array size is " ~ to!string(length) ~ ".");
		return data[i];
	}

	T[] opSlice()
	{
		return data[0.._size];
	}

	const(T)[] opSlice() const
	{
		return data[0.._size];
	}
	
	auto opSlice(size_t x, size_t y)
	{
		assert(y <= _size, "Slice [" ~ to!string(x) ~ " .. " ~ to!string(y) ~ "] is out of bounds. Array size is " ~ to!string(length) ~ ".");
		assert(x <= y, "Slice [" ~ to!string(x) ~ " .. " ~ to!string(y) ~ "] is out of order. Don't do drugs, kids.");
		return data[x..y];
	}

	auto opDollar()
	{
		return _size;
	}

	void opSliceAssign(T[] t)
	{
		data[0.._size] = t[];
	}
	
	void opSliceAssign(T[] t, size_t x, size_t y)
	{
		assert(y <= _size && x <= y);
		data[x..y] = t[];
	}

	/**
	 * Insert a range of T.init items
	 * 
	 * Index must be <= size
	 */
	void create(size_t index, size_t amount)
	{
		createRaw(index, amount);
		initRange(index, amount);
	}

	/**
	 * Destroy a range of items
	 */
	void destroy(size_t index, size_t amount)
	{
		dtorRange(index, amount);
		destroyRaw(index, amount);
	}

	//Set a range to T.init
	private void initRange(size_t index, size_t amount)
	{
		assert(index + amount <= _size);
		if(amount == 0) return;

		initializeAll(data[index..index+amount]);
	}

	//Call dtor on a range
	private void dtorRange(size_t index, size_t amount)
	{
		assert(index + amount <= _size);
		if(amount == 0) return;

		static if(is(T == struct))
			foreach(ref item; data[index..index+amount])
				typeid(T).destroy(&item);
	}

	//Call postblit on a range
	private void postblitRange(size_t index, size_t amount)
	{
		assert(index + amount <= _size);
		if(amount == 0) return;

		static if(hasMember!(T, "__postblit"))
		{
			static if(is(T == struct))
				foreach(ref item; data[index..index+amount])
					item.__postblit();
		}
	}

	//Creates a raw range
	package void createRaw(size_t index, size_t amount)
	{
		assert(index <= _size);
		if(amount == 0) return;
		if(index < _size) _moved = true;

		//Fun mental exercise: Walk through this function with the assumption data == null.
		//The code fair dances on the precipice of disaster.

		uint log = 0;
		while((log ? 1 << log : 0) < (_size + amount)) log = log+1;

		if(log > _log || (log < _log && !_cached))
		{
			_log = log;
			T* newData = cast(T*)malloc(T.sizeof * capacity);

			memcpy(newData, data, T.sizeof * index);
			memcpy(newData+index+amount, data+index, T.sizeof * (_size - index));
			if(hasGarbage!T)
			{
				GC.addRange(cast(void*)newData, T.sizeof * capacity);
				GC.removeRange(cast(void*)data);
			}
			free(data);
			data = newData;
			_moved = true;
		}
		else memmove(data+index+amount, data+index, T.sizeof * (_size-index));

		_size += amount;
	}
	
	//Removes a raw range
	package void destroyRaw(size_t index, size_t amount)
	{
		assert(index + amount <= _size);
		if(amount == 0) return;
		if(index + amount < _size) _moved = true;

		uint log = 0;
		while((log ? 1 << log : 0) < (_size - amount)) log = log+1;

		if((log < _log && !_cached))
		{
			_log = log;
			T* newData = cast(T*)malloc(T.sizeof * capacity);
			memcpy(newData, data, T.sizeof * index);
			memcpy(newData+index, data+index+amount, T.sizeof * (_size-(index+amount)));
			if(hasGarbage!T)
			{
				GC.addRange(cast(void*)newData, T.sizeof * capacity);
				GC.removeRange(cast(void*)data);
			}
			free(data);
			data = newData;
			_moved = true;
		}
		else memmove(data+index, data+index+amount, T.sizeof * (_size-(index+amount)));
		
		_size -= amount;
	}

	/**
	 * Move items to another array.
	 */
	void move(size_t index, size_t amount, ref Array!T that, size_t that_index)
	{
		assert(index + amount <= _size);
		assert(that_index <= that._size);
		if(amount == 0) return;

		that.createRaw(that_index, amount);
		memcpy(that.data+that_index, data+index, T.sizeof * amount);
		destroyRaw(index, amount);
	}

	/**
	 * Move all items to the end of another array.
	 */
	void move(ref Array!T that)
	{
		move(0, _size, that, that._size);
	}
	
	/**
	 * Add an item to the array.
	 * 
	 * The item is swapped into the array and replaced with T.init.
	 * If an r-value is given, a copy is made.
	 * 
	 * Maintains item order. 
	 * If an insertion index is not specified, it defaults to _size (appending).
	 */
	void add()(auto ref T item, size_t index)
	{
		create(index, 1);
		swap(data[index], item);
	}

	void add()(auto ref T item)
	{
		create(_size, 1);
		swap(data[_size-1], item);
	}

	/**
	 * Remove the item at the specified index and return it.
	 */
	T remove(size_t index)
	{
		assert(index < _size);
		
		T item = void;
		memcpy(&item, data+index, T.sizeof);
		destroyRaw(index, 1);
		return item;
	}

	/**
	 * Remove a range of items and return them in a new array.
	 */
	Array!T remove(size_t index, size_t amount)
	{
		assert(index + amount <= _size);
		if(amount == 0) return Array!T();

		Array!T array;
		move(index, amount, array, 0);
		return array;
	}
	
	/**
	 * Remove the last item in the array and return it.
	 */
	T pop()
	{
		assert(_size);

		T item = void;
		memcpy(&item, data+_size-1, T.sizeof); 
		destroyRaw(_size-1, 1);
		return item;
	}
	
	/**
	 * Remove the item at the specified index and return it, potentially disrupting item order.
	 */
	T removeFast(size_t index)
	{
		assert(index < _size);
		
		T item = void;
		memcpy(&item, data+index, T.sizeof);
		if(index != _size-1)
		{
			swap(data[_size-1], data[index]);
			_moved = true;
		}
		destroyRaw(_size-1, 1);
		return item;
	}

	//Transform a field into an std.algorithm predicate
	private template less(alias field)
	{ enum less = field != "" ? "a."~field~"<b."~field : "a < b"; }

	//Transform a field into a mixin-ready string
	private template fm(alias field)
	{ enum fm = field != "" ? "."~field : ""; }

	/**
	 * Find the index of an item.
	 * 
	 * Returns true if found, and puts the index in foundIndex.
	 */
	bool find(alias field = "", F)(const F that, out size_t foundIndex)
	{
		foreach(x; 0.._size)
		{
			if(mixin("data[x]"~fm!field~" == that"))
			{
				foundIndex = x;
				return true;
			}
		}
		return false;
	}


	/**
	 * Find and remove an item.
	 * 
	 * Returns true on success, false if the item was not found.
	 */
	bool removeItem(alias field = "", F)(const F that)
	{
		size_t index;
		if(find!field(that, index))
		{
			remove(index);
			return true;
		}
		return false;
	}
	
	/**
	 * Check if the array contains an item.
	 */
	bool contains(alias field = "", F)(const F dat)
	{
		size_t index_tho;
		return find!field(dat, index_tho);
	}
	
	///Remove all items.
	void clear()
	{
		size = 0;
	}
	
	@property bool empty() { return _size == 0; }

	string toString()
	{
		string result = "[";
		
		foreach(uint index, ref T item; this)
		{
			result ~= to!string(item);
			if(index < _size-1) result ~= ", ";
		}
		result ~= "]";
		return result;
	}

	/**
	 * Sorts the array by T or a specified field of T.
	 * 
	 * Sorting algorithm is Introsort (std.algorithm.sort with SwapStrategy.unstable)
	 * It is unstable and does not allocate.
	 */
	void sort(alias field = "")()
	{
		std.algorithm.sort!(less!field, std.algorithm.SwapStrategy.unstable)(data[0.._size]);
	}

	///Returns true if the array is sorted.
	@property bool sorted(alias field = "")()
	{
		return std.algorithm.isSorted!(less!field)(data[0.._size]);
	}
	
	/**
	 * Insert item in sorted order.
	 * 
	 * This uses binary search to find the insert index.
	 * The array must be in a sorted state before this
	 * is called. 
	 * 
	 * In debug builds, this checks the array is sorted.
	 * Don't be surprised if your algorithm is slow as molasses.
	 * 
	 * This swaps the item into the array, replacing 
	 * the supplied item with T.init.
	 */
	void addSorted(alias field = "")(auto ref T item)
	{
		assert(sorted!field); //Be that guy

		if(_size)
		{
			import core.bitop : bsr; //bit scan reverse, finds number of leading 0's 
			
			//b = highest set bit of _size-1
			size_t b = (_size == 1) ? 0 : 1 << ((size_t.sizeof << 3 - 1) - bsr(_size-1));
			size_t i = 0;
			
			//Count down bits from highest to lowest
			for(; b; b >>= 1)
			{
				//Set bits in i (increasing it) while data[i] <= item.
				//Skip bits that push i beyond the array size.
				size_t j = i|b;
				if(_size <= j) continue; 
				if(mixin("data[j]"~fm!field~" <= item"~fm!field)) i = j;
				else
				{
					//If data[i] becomes greater than item, remove the bounds check, it's pointless now.
					//Set bits while data[i] <= item. 
					//Skip bits that make data[i] larger than item.
					b >>= 1;
					for(; b; b >>= 1) if(mixin("data[i|b]"~fm!field~" <= item"~fm!field)) i |= b;
					break;
				}
				b >>= 1;
			}
			//i now contains the index of the last item that is <= item.
			//(Or 0 if item is less than everything.)
			if(i) add(item, i+1); //insert the item after it.
			else
			{
				if(mixin("item"~fm!field~" < data[0]"~fm!field)) add(item, 0);
				else add(item, 1);
			}
		}
		else add(item);
	}

	/**
	 * Sort array using 32-bit radix sort.
	 * 
	 * Implementation based on http://stereopsis.com/radix.html
	 *
	 * Sorts on a uint or float field of T, specified by 'field'.
	 * See unittests for usage examples. If no field is given,
	 * it sorts on T, which must be uint or float.
	 * 
	 * This is not an in-place sort. It needs scratch space to
	 * work with; provide an array of the same type and it will
	 * take care of it. Pass the same scratch array in to boost
	 * performance over multiple sorts. Note the interior data
	 * pointer is currently swapped with the scratch array.
	 * 
	 */
	void radixSort(alias field = "")(ref Array!T scratch)
	{
		enum f = field != "" ? "a."~field : "a";

		scratch.size = _size; //no-op on repeat invocations

		//11-bit histograms on stack (perhaps use TLS? It's 24.5 kilobytes)
		immutable uint kb = 2048;
		uint[kb * 3] b;
		uint* b0 = b.ptr;
		uint* b1 = b0 + kb;
		uint* b2 = b1 + kb;
		
		//Create histograms
		for(int x = 0; x < _size; x++)
		{
			T a = data[x];
			mixin("auto p = &(" ~ f ~ ");");
			uint i = *cast(uint*)p;

			//Assert field is uint or float
			static assert(is(typeof(*p) == float) || is(typeof(*p) == uint));

			static if(is(typeof(*p) == float))
			{
				//Flip float
				int m = i >> 31;
				i ^= -m | 0x80000000;
			}

			b0[i & 0x7FF]++;
			b1[i >> 11 & 0x7FF]++;
			b2[i >> 22]++;
		}
		
		//Convert to cumulative histograms
		uint s0, s1, s2, st;
		for(int x = 0; x < kb; x++) { st = b0[x] + s0; b0[x] = s0 - 1; s0 = st; }
		for(int x = 0; x < kb; x++) { st = b1[x] + s1; b1[x] = s1 - 1; s1 = st; }
		for(int x = 0; x < kb; x++) { st = b2[x] + s2; b2[x] = s2 - 1; s2 = st; }

		//Sort pass 1 (copies items to scratch with 11 bits sorted)
		for(int x = 0; x < _size; x++)
		{
			T a = data[x];
			mixin("auto p = &(" ~ f ~ ");");
			uint* i = cast(uint*)p;

			//Flip float
			static if(is(typeof(*p) == float)) { int m = *i >> 31; *i ^= -m | 0x80000000; }

			uint pos = *i & 0x7FF;
			scratch[++b0[pos]] = a;
		}

		//Pass 2 (copies items back to source with 22 bits sorted)
		for(int x = 0; x < _size; x++)
		{
			T a = scratch[x];
			mixin("uint i = *cast(uint*)&(" ~ f ~ ");");
			uint pos = i >> 11 & 0x7FF;
			data[++b1[pos]] = a;
		}

		//Pass 3 (copies to scratch again with all 32 bits sorted)
		for(int x = 0; x < _size; x++)
		{
			T a = data[x];
			mixin("auto p = &(" ~ f ~ ");");
			uint* i = cast(uint*)p;
			uint pos = *i >> 22;

			//Unflip float
			static if(is(typeof(*p) == float)) { uint m = ((*i >> 31) - 1) | 0x80000000; *i ^= m; }

			scratch[++b2[pos]] = a;
		}

		//Swap arrays so data points to sorted items
		swap(data, scratch.data);
		swap(_other, scratch._other);
	}
}

unittest
{
	Array!uint a1;

	a1.add(1);
	assert(a1[0] == 1);
	assert(a1.length == 1);

	//Resize
	a1.size = 100;
	assert(a1.size == 100);

	//Capacity
	assert(a1.capacity == 128);
	a1.size = 20;
	assert(a1.capacity == 32);
	a1.size = 32;
	assert(a1.capacity == 32);

	//Contains
	assert(a1.contains(1));

	//Variadic construction
	a1 = Array!uint(1, 2, 3, 4, 5);

	assert(a1.contains(1));
	assert(a1.contains(2));
	assert(a1.contains(5));

	//Remove item
	a1.removeItem(2);
	assert(!a1.contains(2));

	//toString
	assert(a1.toString == "[1, 3, 4, 5]");

	//Sorted
	assert(a1.sorted);

	//Sort
	a1 = Array!uint(5, 2, 3, 4, 1, 1, 5);
	a1.sort;
	assert(a1 == [1,1,2,3,4,5,5]);

	//Add sorted
	a1 = Array!uint();
	a1.addSorted(3);
	a1.addSorted(1);
	a1.addSorted(4);
	a1.addSorted(5);
	a1.addSorted(2);
	assert(a1 == [1,2,3,4,5]);

	//Radix uint sort
	Array!uint scratch1;
	a1 = Array!uint(5, 2, 3, 4, 1, 1, 5);
	a1.radixSort(scratch1);
	assert(a1 == [1,1,2,3,4,5,5]);

	//Capacity caching
	a1.size = 30;
	a1.cached = true;
	a1.size = 0;
	assert(a1.capacity == 32);
	a1.size = 5;
	assert(a1.capacity == 32);
	a1.cached = false;
	a1.size = 6;
	assert(a1.capacity == 8);

	//Move
	auto b1 = Array!uint(1,2,3,4);
	a1 = Array!uint(0, 5);
	b1.move(0, 4, a1, 1);
	assert(a1 == [0,1,2,3,4,5]);
	assert(b1 == []);
	a1.move(0, 2, b1, 0);
	assert(a1 == [2,3,4,5]);
	assert(b1 == [0,1]);
	a1.move(3, 1, b1, 2);
	assert(a1 == [2,3,4]);
	assert(b1 == [0,1,5]);
	a1.move(b1);
	assert(b1 == [0,1,5,2,3,4]);


	//Radix float sort
	Array!float scratch2;
	Array!float a2 = Array!float(0.0, -0.0, 1.0, 1.1, -1.0);
	a2.radixSort(scratch2);
	assert(a2 == [-1.0, -0.0, 0.0, 1.0, 1.1]);

	//Radix uint/float field sort
	struct s1 { uint foo; float bar; char harhar; this(this) { } }
	Array!s1 scratch3;
	Array!s1 a3 = Array!s1(s1(60, 40.0), s1(20, 80.0), s1(40, 60.0), s1(0, 100.0));
	
	a3.radixSort!"foo"(scratch3);
	assert(a3 == [s1(0, 100.0), s1(20, 80.0), s1(40, 60.0), s1(60, 40.0)]);
	
	a3.radixSort!"bar"(scratch3);
	assert(a3 == [s1(60, 40.0), s1(40, 60.0), s1(20, 80.0), s1(0, 100.0)]);
}
