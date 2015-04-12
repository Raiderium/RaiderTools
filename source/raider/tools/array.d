module raider.tools.array;

import raider.tools.reference : hasGarbage;
import core.stdc.stdlib;
import core.memory;
import std.conv;
import core.stdc.string : memcpy, memmove;
import std.traits;
import std.algorithm : swap, initializeAll, sort, binaryFun;
import std.bitmanip;

/**
 * Array stores items in contiguous memory
 * 
 * Items must tolerate being moved without consultation.
 * 
 * Items will be registered with the GC if they contain aliasing.
 * The Array struct itself contains no aliasing the GC needs to know about.
 * 
 * References into the array are valid until the next mutating method call.
 * Item order is maintained during mutations unless otherwise noted.
 */
struct Array(T)
{private:
	T* data = null;
	size_t _size = 0; //Number of items stored

	union 
	{
		uint _other = 0;
		mixin(bitfields!
		(
			bool, "_sorted", 1, //data[x] <= data[x+1]
			bool, "_cached", 1, //capacity cannot decrease TODO implement
			uint, "_capacity", 6, //log2 of capacity
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

	//Construct a copy. Invokes item copy constructor
	this(this)
	{
		T* that_data = data;
		size_t that_size = size;
		
		data = null;
		size = 0;
		_other = 0;
		
		resize(that_size);
		data[0.._size] = that_data[0..that_size];
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

	enum sortable = __traits(compiles, binaryFun!"a<b"(T.init, T.init));

	@property T* ptr() { return data; }
	@property size_t size() { return _size; }
	alias size length;

	@property size_t capacity()
	{
		return _capacity ? 1 << _capacity : 0;
	}

	/* Capacity allocation strategy
	 * A dynamic array is tasked with efficiently allocating
	 * space for a list of items that may grow and shrink
	 * at any rate and to any size.
	 * 
	 * Allocating space in powers of two is a good start,
	 * but there is still low-hanging fruit. What if the
	 * the list is grown and pruned rapidly, or only grown 
	 * once?
	 * 
	 * The first situation occurs when an array is cleared 
	 * and refilled in each frame of a game, for instance, 
	 * to store collision data. This is addressed by the 
	 * 'cache' flag (not implemented yet), which stops 
	 * capacity from decreasing.
	 * 
	 * The second situation /was/ addressed by the 'snuggle'
	 * feature, which removed the allocation margin
	 * until the next mutating method call. This now 
	 * seems too complicated and unnecessary. Instead,
	 * the margin might simply have a maximum size.
	 * 
	 * If needed in future, the snuggle feature can be 
	 * found in the commit history of RaiderEngine.
	 */
	
	@property void size(size_t value)
	{
		resize(value);
	}

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
		assert(i < _size);
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
		assert(y <= _size && x <= y);
		return data[x..y];
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
	 * Resize the array.
	 * 
	 * New items are initialised to T.init, lost items are destroyed.
	 */
	void resize(size_t newSize)
	{
		if(newSize == _size) return;
		
		if(newSize > _size) upsize(_size, newSize - _size);
		else downsize(newSize, _size - newSize); // *sighs*
	}
	
	/**
	 * Insert and initialise a range of items
	 * 
	 * Index must be <= size
	 */
	void upsize(size_t index, size_t amount)
	{
		assert(index <= _size);
		if(amount == 0) return;

		uint temp = _capacity;
		_capacity = 0;
		while(capacity < (_size + amount)) _capacity = _capacity + 1;
		
		if(_capacity != temp)
		{
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
		}
		else memmove(data+index+amount, data+index, T.sizeof * (_size-index));
		
		initializeAll(data[index..index+amount]);
		_size += amount;
		_sorted = false;
	}
	
	/**
	 * Destroy and remove a range of items
	 */
	void downsize(size_t index, size_t amount)
	{
		assert(index < _size && (index + amount) <= _size);
		if(amount == 0) return;
		
		static if(is(T == struct))
			foreach(ref item; data[index..index+amount])
				typeid(T).destroy(&item);

		uint temp = _capacity;
		_capacity = 0;
		while(capacity < (_size - amount)) _capacity = _capacity + 1;

		if(_capacity != temp)
		{
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
		}
		else memmove(data+index, data+index+amount, T.sizeof * (_size-(index+amount)));
		
		_size -= amount;
	}
	
	/**
	 * Add item to array.
	 * 
	 * If an insertion index is not specified, it defaults to _size (appending).
	 * 
	 * Maintains item order. Shifts the item at the specified index (if any) and all 
	 * items after it (if any) to the right.
	 * 
	 * This swaps the item into the array, replacing the supplied item with T.init.
	 * If an r-value is given, it makes a copy.
	 */
	void add()(auto ref T item, size_t index)
	{
		upsize(index, 1);
		swap(data[index], item);
		_sorted = false;
	}

	void add()(auto ref T item)
	{
		upsize(_size, 1);
		swap(data[_size-1], item);
		_sorted = false;
	}

	static if(sortable)
	{
		/**
		 * Sorts the array.
		 * 
		 * Sorting algorithm is Introsort (std.algorithm.sort with SwapStrategy.unstable)
		 * It is unstable and does not allocate.
		 */
		void sort()
		{
			std.algorithm.sort!("a < b", std.algorithm.SwapStrategy.unstable)(data[0.._size]);
			_sorted = true;
		}

		@property bool sorted()
		{
			return _sorted;
		}

		/**
		 * Insert item in sorted order.
		 * 
		 * This sorts the array if it is not already sorted, 
		 * and uses binary search to find the insert index.
		 * 
		 * This swaps the item into the array, replacing the supplied item with T.init.
		 */
		void addSorted()(auto ref T item)
		{
			if(_sorted && _size)
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
					if(data[j] <= item) i = j; 
					else
					{
						//If data[i] becomes greater than item, remove the bounds check, it's pointless now.
						//Set bits while data[i] <= item. 
						//Skip bits that make data[i] larger than item.
						b >>= 1;
						for(; b; b >>= 1) if(data[i|b] <= item) i |= b;
						break;
					}
					b >>= 1;
				}
				//i now contains the index of the last item that is <= item.
				//(Or 0 if item is less than everything.)
				if(i) add(item, i+1); //insert the item after it.
				else
				{
					if(item < data[0]) add(item, 0);
					else add(item, 1);
				}
				_sorted = true;
			}
			else
			{
				add(item, _size);
				sort;
			}
		}
	}
	
	/**
	 * Remove the item at the specified index and return it.
	 */
	T remove(size_t index)
	{
		assert(index < _size);
		
		T item;
		swap(item, data[index]);
		downsize(index, 1);
		return item;
	}
	
	/**
	 * Remove the last item in the array and return it.
	 */
	T pop()
	{
		assert(_size);
		
		T item;
		swap(item, data[_size-1]);
		downsize(_size-1, 1);
		return item;
	}
	
	/**
	 * Remove the item at the specified index and return it, potentially disrupting item order.
	 */
	T removeFast(size_t index)
	{
		assert(index < _size);
		
		T item;
		swap(item, data[index]);
		if(index != _size-1)
		{
			swap(data[_size-1], data[index]);
			_sorted = false;
		}
		downsize(_size-1, 1);
		return item;
	}

	/**
	 * Find the index of an item.
	 * 
	 * Returns true if found, and puts the index in foundIndex.
	 */
	bool find(const T item, out size_t foundIndex)
	{
		static if(sortable)
		{
			//TODO Binary search if  _sorted.
			foreach(x; 0.._size)
			{
				if(data[x] == item)
				{
					foundIndex = x;
					return true;
				}
			}
		}
		else
		{
			foreach(x; 0.._size)
			{
				if(data[x] == item)
				{
					foundIndex = x;
					return true;
				}
			}
		}
		return false;
	}

	/**
	 * Find and remove an item matching the specified item.
	 * 
	 * Returns true on success, false if the item was not found.
	 */
	bool removeItem(const T item)
	{
		size_t index;
		if(find(item, index))
		{
			remove(index);
			return true;
		}
		return false;
	}
	
	/**
	 * Check if the array contains an item.
	 */
	bool contains(const T item)
	{
		size_t dat_index_tho;
		return find(item, dat_index_tho);
	}
	
	///Remove all items.
	void clear()
	{
		resize(0);
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
	 * Sort array using 32-bit radix sort.
	 * Implementation based on http://stereopsis.com/radix.html
	 * 
	 * This is not an in-place sort. It needs scratch space to
	 * work with; provide an array of the same type and it will
	 * take care of it. Pass the same scratch array in to boost
	 * performance over multiple sorts. Note the interior data
	 * pointer is currently swapped with the scratch array.
	 * 
	 * Sorts on a uint or float field of T, specified by 'field'.
	 * See unittests for usage examples. If no field is given,
	 * it sorts on T, which must be uint or float.
	 */
	void radixSort(alias field = "a")(ref Array!T scratch)
	{
		scratch.resize(_size); //no-op on repeat invocations

		//11-bit histograms on stack
		immutable uint kb = 2048;
		uint b[kb * 3];
		uint* b0 = b.ptr;
		uint* b1 = b0 + kb;
		uint* b2 = b1 + kb;
		
		//Create histograms
		for(int x = 0; x < _size; x++)
		{
			T a = data[x];
			mixin("auto p = &(" ~ field ~ ");");
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
			mixin("auto p = &(" ~ field ~ ");");
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
			mixin("uint i = *cast(uint*)&(" ~ field ~ ");");
			uint pos = i >> 11 & 0x7FF;
			data[++b1[pos]] = a;
		}

		//Pass 3 (copies to scratch again with all 32 bits sorted)
		for(int x = 0; x < _size; x++)
		{
			T a = data[x];
			mixin("auto p = &(" ~ field ~ ");");
			uint* i = cast(uint*)p;
			uint pos = *i >> 22;

			//Unflip float
			static if(is(typeof(*p) == float)) { uint m = ((*i >> 31) - 1) | 0x80000000; *i ^= m; }

			scratch[++b2[pos]] = a;
		}

		//Swap arrays so data points to sorted items
		swap(data, scratch.data);
		//TODO Investigate consequences of swapping _other.
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
	a1.resize(100);
	assert(a1.size == 100);

	//Capacity
	assert(a1.capacity == 128);
	a1.resize(20);
	assert(a1.capacity == 32);
	a1.resize(32);
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

	//Sort
	a1 = Array!uint(5, 2, 3, 4, 1, 1, 5);
	a1.sort;
	assert(a1 == [1,1,2,3,4,5,5]);

	//Add sorted
	a1 = Array!uint(1, 2, 4, 5);
	a1.addSorted(3);
	assert(a1 == [1,2,3,4,5]);

	//Radix uint sort
	Array!uint scratch1;
	a1 = Array!uint(5, 2, 3, 4, 1, 1, 5);
	a1.radixSort(scratch1);
	assert(a1 == [1,1,2,3,4,5,5]);

	//Radix float sort
	Array!float scratch2;
	Array!float a2 = Array!float(0.0, -0.0, 1.0, 1.1, -1.0);
	a2.radixSort(scratch2);
	assert(a2 == [-1.0, -0.0, 0.0, 1.0, 1.1]);

	//Radix uint/float field sort
	struct s1 { uint foo; float bar; char harhar; }
	Array!s1 scratch3;
	Array!s1 a3 = Array!s1(s1(60, 40.0), s1(20, 80.0), s1(40, 60.0), s1(0, 100.0));
	
	a3.radixSort!"a.foo"(scratch3);
	assert(a3 == [s1(0, 100.0), s1(20, 80.0), s1(40, 60.0), s1(60, 40.0)]);
	
	a3.radixSort!"a.bar"(scratch3);
	assert(a3 == [s1(60, 40.0), s1(40, 60.0), s1(20, 80.0), s1(0, 100.0)]);
}