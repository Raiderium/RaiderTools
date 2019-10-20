module raider.tools.array;

import raider.tools.reference;
import raider.tools.memory : hasPostMove;
static import raider.tools.memory;
import core.exception : onOutOfMemoryError;
import core.memory : GC;
import std.conv : to;
import core.stdc.string : memcpy, memmove, memset;
import std.traits : hasMember, hasElaborateDestructor, hasElaborateCopyConstructor,
	hasElaborateAssign, isAssignable, isBasicType;
import std.algorithm : swap;
static import std.algorithm;
import std.functional : unaryFun, binaryFun;
import std.bitmanip : bitfields;
import core.stdc.stdlib : malloc, mfree = free, realloc;

/**
 * Array stores items in contiguous memory.
 * 
 * If T defines void _moved(), items will be informed when
 * their address changes.
 * 
 * If hasGarbage!T, memory will be registered with the GC.
 */
struct Array(T)
{package:
	@NotGarbage T* data = null;
	size_t _size = 0; //Number of items stored
    
	union {
		uint _other = 0;
		mixin(bitfields!(
			size_t, "_quantum", 31, //capacity quantization level
			bool, "_ratchet", 1, //capacity will not decrease while set
		));
        
		/* Cached-ness, as well as capacity quantization, really
		 * is an aspect of the planned memory allocation system.
		 * If at all possible, they should be non-essential to the
		 * interface.
		 * 
		 * Ratcheting is derived from frequent growth and freeing.
		 * Capacity is derived from growth. Basically, both are
		 * performance only, not semantics, and can be part of a
		 * reactive, automatic system. These bitfields should not
		 * be part of semantics within this file, or anywhere.
		 * Arrays can be given a LOT of slack, as soon as they're
		 * created, when we benefit from compaction.
		 */
	}
    
	enum isTraced = (!is(T == class) && hasGarbage!T) ||
		( is(T == class) && !(isReferentType!T || isUnmanagedType!T));
    
	enum hasPostBlit = is(T == struct) && __traits(compiles, T.init.__xpostblit());
	enum hasRawBlit = is(T == struct) && !hasMember!(T, "__xpostblit");
	enum isCopyable = hasPostBlit || hasRawBlit || isBasicType!T;
    
public:
    
	this()() { }
	this(L...)(T item, L list)
	{
		//Recursive form allows implicit coercion (e.g. literal to uint)
		add(item);
		this(list);
		//BUG? 'auto ref T item' doesn't seem to work.
	}
    
	/*this(A...)(A list)
	{
		foreach(item; list)
			add(item);
	}*/
    
	static if(isCopyable)
	{
		this(this)
		{
			T* that_data = data;
			size_t that_size = size;
            
			data = null;
			_size = 0;
			_quantum = 0;
            
			createRaw(0, that_size);
			memcpy(data, that_data, T.sizeof * that_size);
			static if(hasPostBlit)
				foreach(ref item; data[0 .. that_size]) item.__xpostblit();
		}
	}
	else @disable this(this);
    
	~this()
	{
		clear;
	}
    
	static if(isCopyable)
	{
		void opAssign(Array!T that)
		{
			swap(data, that.data);
			swap(_size, that._size);
			swap(_other, that._other);
		}
	}
    
	@property T* ptr() { return data; }
	@property size_t size() const { return _size; }
	@property size_t capacity() const { return quantify(_quantum) / T.sizeof; }
    
	/**
	 * Number of items in array.
	 * 
	 * New items are initialised to T.init, lost items are destroyed.
	 */
	@property void size(size_t value)
	{
		if(value == _size) return;
		if(value > _size) create(_size, value - _size);
		else destroy(value, _size - value);
	}
    
	alias length = size;
    
	///Remove all items.
	void clear() { size = 0; }
	@property bool empty() { return _size == 0; }
    
	static if(isCopyable) //FIXME to!string doesn't like structs with @disable this(this)?
	{
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
	}
    
	/**
	 * Capacity will not decrease while ratchet == true.
	 * 
	 * This is one of those 'temporary measures' that will Definitely Be Replaced
	 * once the replacement feature is implemented (compacting memory allocator).
	 */
	@property bool ratchet() { return _ratchet; }
    
	///Ditto
	@property void ratchet(bool value) { _ratchet = value; }
    
	bool opEquals(const T[] that) const
	{
		return data[0.._size] == that;
	}
    
	bool opEquals(const Array!T that) const //TODO Check this doesn't make a copy.
	{
		return data[0.._size] == that[];
	}
    
	//Deliberately not implemented: toHash. Don't use arrays as keys to associative arrays, kids.
    
	ref T opIndex(const size_t i)
	{
		assert(i < _size, "Index [ " ~ to!string(i) ~ "] is out of bounds.");
		return data[i];
	}
    
	auto opDollar()
	{
		return _size;
	}
    
	/*
	T[] opSlice()
	{
		return data[0.._size];
	}
    
	const(T)[] opSlice() const
	{
		return data[0.._size];
	}
	*/
    
	//TODO Does this replace them?
    
	inout(T[]) opSlice() inout
	{
		return data[0 .. _size];
	}
    
	auto opSlice(size_t x, size_t y)
	{
		assert(y <= _size, "Slice [" ~ to!string(x) ~ " .. " ~ to!string(y) ~ "] is out of bounds.");
		assert(x <= y, "Slice [" ~ to!string(x) ~ " .. " ~ to!string(y) ~ "] is out of order. Stay in school, kids.");
		return data[x..y];
	}
    
	//@disable this(this) means no opSliceAssign.
	static if(isCopyable)
	{
		void opSliceAssign(T[] t)
		{
			data[0.._size] = t[];
		}
        
		void opSliceAssign(T[] t, size_t x, size_t y)
		{
			assert(y <= _size && x <= y);
			data[x..y] = t[];
		}
        
		//Vector assignment
		void opSliceAssign(L)(L l)
		{
			data[0.._size] = cast(T)l;
		}
        
		void opSliceAssign(L)(L l, size_t x, size_t y)
		{
			data[x..y] = cast(T)l;
		}
	}
    
	/**
	 * Insert a range of T.init items
	 */
	void create(size_t index, size_t amount)
	{
		assert(index <= _size);
		createRaw(index, amount);
        
		//Initialise stuff
		static if(hasElaborateAssign!T)
		{
			auto p = typeid(T).initializer().ptr;
			if(p) foreach(ref item; data[index..index+amount]) memcpy(&item, p, T.sizeof);
			else memset(data+index, 0, amount*T.sizeof);
		}
		else data[index..index+amount] = T.init;
	}
    
	/**
	 * Destroy a range of items
	 */
	void destroy(size_t index, size_t amount)
	{
		assert(index + amount <= _size);
		static if(is(T == struct)) //call dtor
			foreach(ref item; data[index..index+amount]) typeid(T).destroy(&item);
		destroyRaw(index, amount);
	}
    
	private pure size_t quantize(size_t size) const
	{
		if(!size) return 0;
        
		size_t q = 1;
		if(size <= 32768)
			while((32 << q) < size) q++;
		else if(size <= 131072)
			q = (size / 16384) + (size % 16384 != 0) + 8; //what we mean
		  //q = (size >> 14) + ((size & 16383) != 0) + 8; //what we want
		else
			q = (size / 65536) + (size % 65536 != 0) + 14;
		return q;
	}
    
	private pure size_t quantify(size_t q) const
	{
		size_t size;
		if(q)
		{
			if(q < 11) size = 32 << q;
			else if(q < 17) size = (q-8)*16384;
			else size = (q-14)*65536;
		}
		return size;
	}
    
	package void createRaw(size_t index, size_t amount) { mutate(index, amount, true); }
	package void destroyRaw(size_t index, size_t amount) { mutate(index, amount, false); }
    
	//Create or destroy a raw range
	package void mutate(size_t index, size_t amount, bool create)
	{
		if(amount == 0) return;
        
		size_t src = index + amount * !create; //source index of the moved chunk
		size_t dst = index + amount * create; //destination index of the moved chunk
		assert(src <= _size);
        
		size_t newSize = _size + (create ? amount : -amount);
		auto q = quantize(newSize * T.sizeof);
        
		if(q > _quantum || (q < _quantum && !_ratchet))
		{
			//Fun mental exercise: Walk through this function with the assumption data == null.
			//The code fair dances on the precipice of disaster.
            
			_quantum = q;
			T* newData;
            
			// TODO Profile malloc against gc_qalloc
			//I'd trade my filthy kingdom for a cross-platform mremap
            
			if(!isTraced && src == _size)
			{ // We can't protect realloc'd memory for tracing purposes, and its copy is often redundant
                
				//(m/re)alloc may return non-null even if no memory is requested. Don't like that.
				if(newSize) newData = cast(T*) realloc(cast(void*)data, capacity * T.sizeof);
				else { newData = null; mfree(data); }
				if(newSize && !newData) onOutOfMemoryError;
                
				static if(hasPostMove!T)
					if(newData != data)
						foreach(ref item; newData[0 .. _size < newSize ? _size : newSize]) item._moved;
			}
			else
			{
				newData = newSize ? cast(T*) malloc(capacity * T.sizeof) : null;
				if(newSize && !newData) onOutOfMemoryError;
                
				memcpy(newData, data, index * T.sizeof);
				static if(hasPostMove!T) //finish with hot memory before moving on
					foreach(ref item; newData[0 .. index]) item._moved;
                
				memcpy(newData+dst, data+src, (_size - src) * T.sizeof);
				static if(hasPostMove!T)
					foreach(ref item; newData[dst .. newSize]) item._moved;
                
				static if(isTraced) {
					GC.addRange(cast(void*)newData, capacity * T.sizeof);
					GC.removeRange(cast(void*)data);
				}
				mfree(data);
			}
			data = newData;
		}
		else {
			memmove(data+dst, data+src, (_size-src) * T.sizeof);
			static if(hasPostMove!T)
				foreach(ref item; data[dst .. newSize]) item._moved;
		}
		_size = newSize;
	}
    
	/**
	 * Move items to another array.
	 */
	void move()(size_t index, size_t amount, ref Array!T that, size_t that_index)
	{
		assert(index + amount <= _size);
		assert(that_index <= that._size);
		if(amount == 0) return;
        
		that.createRaw(that_index, amount);
		memcpy(that.data + that_index, data+index, T.sizeof * amount);
		static if(hasPostMove!T)
			foreach(ref item; that.data[that_index .. that_index + amount])
				item._moved;
		destroyRaw(index, amount);
	}
    
	/**
	 * Move all items to the end of another array.
	 */
	void move()(ref Array!T that)
	{
		move(0, _size, that, that._size);
	}
    
	/**
	 * Add an item to the array.
	 * 
	 * The item is moved into the array, replacing the argument
	 * with T.init if required. If an r-value is given, a copy is made.
	 * 
	 * If a sorting predicate is provided, it finds a sorted insertion index.
	 * If an insertion index is specified, it will be placed there.
	 * Otherwise, the item will be appended.
	 */
	void add(alias dummy = "")(auto ref T item, size_t index) if(dummy == "")
	{
		createRaw(index, 1);
		raider.tools.memory.move!"xm"(data[index], item);
	}
    
	void add(alias less = "")(auto ref T item)
	{
		static if(less == "")
			add(item, _size);
		else
		{
			if(_size == 0) add(item, _size);
			else
			{
				size_t i;
				find!("i", less)(item, i);
				add(item, i);
			}
		}
	}
    
	/**
	 * Remove the item at the specified index and return it.
	 * 
	 * A strategy for taking an item without moving regions of
	 * the array is to move the last item into the vacated slot.
	 * 
	 * This strategy is used unless template parameter 'order' is
	 * specified as non-empty (I recommend "ordered"), in which
	 * case item order is maintained.
	 */
	T remove(string order = "")(size_t index)
	{
		assert(index < _size);
        
		T item = void;
		raider.tools.memory.move!"xx"(item, data[index]);
        
		static if(order != "")
			destroyRaw(index, 1);
		else
		{
			if(index != _size-1) raider.tools.memory.move!"xx"(data[index], data[_size-1]);
			destroyRaw(_size-1, 1);
		}
		return item;
	}
    
	/**
	 * Remove the last item in the array and return it.
	 */
	T pop()
	{
		assert(_size);
        
		T item = void;
		raider.tools.memory.move!"xx"(item, data[_size-1]);
		destroyRaw(_size-1, 1);
		return item;
	}
    
	ref T front()
	{
		assert(_size);
		return data[0];
	}
    
	/**
	 * Remove a range of items and return them in a new array.
	 */
	Array!T remove(size_t index, size_t amount)
	{
		Array!T array;
		move(index, amount, array, 0);
		return array; //DEAR COMPILER PLEASE ELIDE THIS COPY
	}
    
	/**
	 * Find the index of an item.
	 * 
	 * Returns true if found, and puts the index in foundIndex.
	 * 
	 * It can search in terms of a unary function 'field', with a
	 * return type that is comparable to the search term 'that'.
	 * 
	 * If a sorting predicate is specified, the array is assumed
	 * sorted by that predicate and binary search will be used.
	 * The predicate must operate in terms of the field type F.
	 * 
	 * Binary searching will find a sorted insertion index even
	 * if it doesn't find a matching item.
	 */
	bool find(alias field = "i", alias less = "", F)(const auto ref F that, out size_t foundIndex) const
	{
		foundIndex = 0;
		if(!_size) return false;
        
		//Following std.algorithm.sorting's example
		alias ff = unaryFun!(field, "i");
		static assert(is(typeof(ff(T.init) == that)),
			"Invalid search field " ~ field.stringof ~
			"; cannot evaluate " ~ typeof(ff(T.init)).stringof ~ " == " ~ F.stringof);
        
		static if(less != "")
		{
			alias lf = binaryFun!(less);
			static assert(is(typeof(lf(F.init, F.init)) == bool),
				"Invalid sorting predicate "~less.stringof);
            
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
				if(!lf(that, ff(data[j]))) i = j; // if(data[j] <= item) i = j;
				else
				{
					//If data[i] becomes greater than item, remove the bounds check, it's pointless now.
					//Set bits while data[i] <= item.
					//Skip bits that make data[i] larger than item.
					b >>= 1;
					for(; b; b >>= 1) if(!lf(that, ff(data[i|b]))) i |= b; // if(data[i|b] <= item) i |= b;
					break;
				}
				b >>= 1;
			}
			//i now contains the index of the last item that is <= item.
			//(Or 0 if item is less than everything.)
			if(that == ff(data[i]))
			{
				foundIndex = i;
				return true;
			}
            
			//If not found, at least determine an appropriate insert index.
			if(i) foundIndex = i+1; //insert the item after i if nonzero
			else foundIndex = lf(that, ff(data[0])) ? 0 : 1; // item < data[0] ? 0 : 1;
			return false;
		}
		else
		{
			//Linear search
			foreach(x; 0.._size)
			{
				if(ff(data[x]) == that) //mixin("data[x]"~fm!field~" == that"))
				{
					foundIndex = x;
					return true;
				}
			}
			return false;
		}
	}
    
	/**
	 * Find and destroy an item.
	 * 
	 * Returns true on success, false if the item was not found.
	 * 
	 * See also find().
	 */
	bool destroyItem(alias field = "i", alias less = "", string order = "", F)(const auto ref F that)
	{
		size_t index;
		if(find!(field, less)(that, index))
		{
			static if(order != "")
				destroy(index, 1);
			else {
				if(index != _size-1) raider.tools.memory.move!"mx"(data[index], data[_size-1]);
				destroyRaw(_size-1, 1);
			}
			return true;
		}
		return false;
	}
    
	/**
	 * Check if the array contains an item.
	 */
	bool contains(alias field = "i", alias less = "", F)(const F dat)
	{
		size_t index_tho;
		return find!(field, less)(dat, index_tho);
	}
    
	bool opBinaryRight(string op)(const T that) if(op == "in")
	{
		return contains(that);
	}
    
	/**
	 * Sorts the array.
	 * 
	 * Sorting algorithm is Introsort (std.algorithm.sort with SwapStrategy.unstable)
	 * It is unstable and does not allocate.
	 */
	void sort(alias less = "a < b")()
	{
		std.algorithm.sort!(less, std.algorithm.SwapStrategy.unstable)(data[0.._size]);
	}
    
	//True if the array is sorted.
	private bool sorted(alias less = "a < b")()
	{
		return std.algorithm.isSorted!less(data[0.._size]);
	}
    
	/**
	 * Sort array using 32-bit radix sort.
	 * 
	 * Implementation based on http://stereopsis.com/radix.html
	 * 
	 * Sorts on a uint or float, either T or a field of T.
	 * The field must be mutable.
	 * 
	 * This is not an in-place sort. It needs scratch space to
	 * work with; provide an array of the same type and it will
	 * take care of it. Pass the same scratch array in to boost
	 * performance over multiple sorts. Note the interior data
	 * pointer is currently swapped with the scratch array.
	 * 
	 */
	/*
	void radixSort(string field = "i")(ref Array!T scratch)
	{
		alias ff = unaryFun!("&("~field~")");
		static assert(typeof(ff(T.init)) == float || typeof(ff(T.init)) == uint,
			"Invalid radix sort field "~field.stringof);
        
		scratch.size = _size; //no-op on repeat invocations

		//11-bit histograms on stack (perhaps use TLS? It's 24.5 kilobytes)
		//Building and reading the histograms almost certainly takes a while
		immutable uint kb = 2048;
		uint[kb * 3] b;
		uint* b0 = b.ptr;
		uint* b1 = b0 + kb;
		uint* b2 = b1 + kb;
        
		// 8-bit histograms on stack
		//immutable uint kb = 256;
		//uint[kb * 4] b; //4 kb.. the size of a page!
        
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
	*/
    
	void gnomeSort()
	{
		//TODO Profile radixSort against an optimised gnomesort.
		//Seriously, there's a good chance the gnomesort will be faster.
		//Even on random data.
		//(For small arrays.)
	}
    
	/**
	 * Sort array.
	 * 
	 * This method arrogantly claims to be appropriate in any situation.
	 */
     
	//void sort()
	//{
		/* Divide the array at cacheline boundaries (eh)
		 * Gnomesort in parallel. Then, mergesort in parallel.
		 * Merging could be: interleave and gnomesort.
		 * Compare large random sets to radix sort. See what happens!
		 * 
		 * A simple parallel sort is better than a complex single-threaded sort.
		 * EVEN IF it only achieves equal performance on dual-core.
		 * 
		 * When merging, don't forget the trivial cases - where
		 * two neighbouring lists are already sorted.
		 * 
		 * This tries to avoid the despised action in gnomesort
		 * where large chunks of data are repeatedly shuffled across.
		 */
		/* Hey what happens if the swaps are atomic and
		 * we start each thread in a different part of
		 * the array?
		 * 
		 * Probably a lot of false sharing lol
		 */
	//}
}


unittest
{
	static assert(!hasGarbage!(Array!uint));
	static assert(!hasGarbage!(Array!(uint*)));
    
	Array!uint a1;
    
	//static assert(!hasGarbage!(a1)); //BUG: https://issues.dlang.org/show_bug.cgi?id=17870
	static assert(!hasGarbage!(typeof(a1)));
    
	a1.add(1);
	assert(a1[0] == 1);
	assert(a1.length == 1);
    
	//Resize
	a1.size = 100;
	assert(a1.size == 100);
    
	//Capacity
	//assert(a1.capacity == 128);
	a1.size = 20;
	//assert(a1.capacity == 32);
	a1.size = 32;
	//assert(a1.capacity == 32);
    
	//Variadic construction
	a1 = Array!uint(1, 2, 3, 4, 5);
    
	//Contains
	assert(a1.contains(1));
	assert(a1.contains(2));
	assert(a1.contains(5));
	assert(a1.contains!("i", "a < b")(1));
	//I think the predicate needs to go before the field :I
    
	//opBinary "in"
	assert(2 in a1);
    
	//Destroy item - searching by the item itself, on an unsorted array, maintaining item order.
	a1.destroyItem!("i", "", "ordered")(2);
	//Literally reverse the parameter order..
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
	a1 = Array!uint(); //Specify optional sorting predicate HERE?
	a1.add!"a < b"(3); //becomes a case of 'unary sorting predicate - radix sort only'
	a1.add!"a < b"(1); //wait, no, it just implies a.field < b.field
	a1.add!"a < b"(4);
	a1.add!"a < b"(5);
	a1.add!"a < b"(2);
	assert(a1 == [1,2,3,4,5]);
    
	//Radix uint sort
	Array!uint scratch1;
	a1 = Array!uint(5, 2, 3, 4, 1, 1, 5);
	//a1.radixSort(scratch1);
	//assert(a1 == [1,1,2,3,4,5,5]);
    
	//Capacity ratchet
	a1.size = 30;
	//a1.ratchet = true;
	a1.size = 0;
	//assert(a1.capacity == 32);
	a1.size = 5;
	//assert(a1.capacity == 32);
	a1.ratchet = false;
	a1.size = 6;
	//assert(a1.capacity == 8);
    
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
	//a2.radixSort(scratch2);
	//assert(a2 == [-1.0, -0.0, 0.0, 1.0, 1.1]);
    
	//Radix uint/float field sort
	struct S1 { uint foo; float bar; char harhar; this(this) { } }
	Array!S1 scratch3;
	Array!S1 a3 = Array!S1(S1(60, 40.0), S1(20, 80.0), S1(40, 60.0), S1(0, 100.0));
    
	//a3.radixSort!"foo"(scratch3);
	//assert(a3 == [s1(0, 100.0), s1(20, 80.0), s1(40, 60.0), s1(60, 40.0)]);
    
	//a3.radixSort!"bar"(scratch3);
	//assert(a3 == [s1(60, 40.0), s1(40, 60.0), s1(20, 80.0), s1(0, 100.0)]);
}

unittest
{
	struct S
	{
		@RC class Faux { M1* mine; }
        
		struct M1
		{
			@disable this(this); uint id; R!Faux f;
            
			void _moved()
			{
				assert(f);
				f.mine = &this;
			}
		}
        
		unittest
		{
			Array!M1 issue;
            
			foreach(x; 0..20)
			{
				auto faux = New!Faux();
				M1 bah;
				faux.mine = &bah;
				bah.id = x;
				bah.f = faux;
				issue.add(bah);
			}
            
			foreach(ref m1; issue) assert(m1.f.mine == &m1);
		}
	}
}

/* 27-5-2017
 * Regarding quantization...
 * 
 * Quantize takes the size of an array in bytes
 * and finds a larger or equal size that is the
 * amount to be allocated, providing slack that
 * reduces the frequency of reallocations while
 * avoiding excessive internal fragmentation.
 * 
 * It does not actually return that size, but a
 * value of quantum that maps monotonically and
 * uniquely to the quantized size so comparison
 * with other values yields the same outcome as
 * comparing the quantized sizes.
 * 
 * 0 must map to 0.
 * 
 * Quantify reverses the mapping so the array
 * can report its capacity.
 * 
 * This may be a template parameter in future.
 * 
 * The current implementation:
 * 
 * quantize     quantify
 * 0      => 0  => 0
 * 64     => 1  => 32 << q      cache line minimum
 * 128    => 2  => 32 << q      powers of two up to 16kb
 * ...
 * 16384  => 9  => 32 << q      every fourth page
 * 32768  => 10 => 32 << q
 * 49152  => 11 => (q-8)*16384
 * 65536  => 12 => (q-8)*16384
 * ...
 * 131072 => 16 => (q-8)*16384
 * 196608 => 17 => (q-14)*65536 every sixteenth page
 * ...
 * 
 * This would benefit from some analysis of
 * typical array sizes and lifespans.
 * 
 * We are not concerned with the allocator's
 * overhead or internal fragmentation.
 * 
 * 	private pure size_t quantify(size_t q)
	{
		size_t size = 32;
		foreach(_; 0..q) size += size / 2;
		return size;
	}
    
	private pure size_t quantize(size_t size)
	{
		size_t q, s = 32;
		while(s < size) { s += s / 2; q++; }
	}
 */

/* 7-6-2017
 * Regarding _move, that is, moving postblit...
 * 
 * 	void _move() { }
 * 
 * Allows objects to be aware when they are moved in memory.
 * 
 * Is this useful? Very rarely. It isn't generally appropriate
 * for a language to assume structs will contain references to
 * themselves; D's assumption otherwise allows to elide copies
 * in many places.
 * 
 * However, within Array (and perhaps Reference) there will be
 * optional support for _move to allow a pattern where objects
 * can update a unique reference struct, or 'proxy', stored in
 * Array, in service of cache-friendly memory access patterns.
 * 
 * The _move semantics do not carry outside Array.
 * A void* src parameter might allow more complex containers.
 * 
 * swap(): Call _move on both afterward.
 * move(): Call _move afterward.
 */

/* 12-6-2017
 * Regarding sorting..
 * 
 * Two systems were attempted: a flag to force the
 * issue when set, and a flag to indicate if order
 * was disturbed.
 * 
 * Neither is feasible, because they're unreliable
 * if the user changes the items, and only a basic
 * a < b predicate is available.
 * 
 * Thus sorting is the developer's responsibility.
 * Some functions can be informed if and how items
 * are sorted. Sorting allows binary searching and
 * other specialised algorithms.
 * 
 * Certain operations are impossible while sorted.
 * You cannot insert items at a specific index, or
 * move them in a way that changes relative order.
 * 
 * Sortedness is asserted when necessary, but it's
 * not considered an invariant. You can change the
 * relative ordering of items manually, and that's
 * safe as long as you treat the array as unsorted
 * from then on (or sort it again).
 */

/* 11-6-2017
 * Regarding heap compaction...
 * 
 * With thread-per-core we have a grand opportunity: we know
 * when it is safe to move memory, because workers are idle.
 * We also know each array holds the sole reference to their
 * memory allocation (copying is always deep and eager).
 * 
 * Therefore, it may be possible to compact arrays
 * and optimise their access patterns.
 * 
 * This is already done manually (as part of a scatter/collect
 * operation) in the Bag implementation.
 * 
 * Arrays know when they're in a worker by a positive tid.
 * They allocate from a special allocator (which only deals
 * in array stores).
 * When the main thread has control, it runs compaction, either
 * stopping at a time limit or a lower fragmentation limit, and
 * forcibly continuing until very bad fragmentation is gone.
 * 
 * Arrays are sorted by inverse frequency of mutation,
 * then by the address of their structs. Array._moved will
 * allow arrays-of-arrays to move correctly.
 * 
 * Arrays can know how much space is left 'till the next array.
 * They can also start with much more space loose (say a whole page)
 * until a lack of mutations causes compaction.
 * 
 * This makes having lots of very tiny arrays efficient.
 * 
 * The allocator manages arrays smaller than a threshold
 * in individual chunks of that size. It has a scratch chunk
 * for compaction, copying the contents of an in-use chunk in,
 * then changing the scratch pointer.
 * 
 * It only compacts if a chunk has a lot of wasted space.
 * It might compact an almost empty chunk into several
 * available chunks.
 * 
 * The important thing is GENERATIONAL awareness. Arrays that
 * are changing should be virtually alone in a chunk.
 * 
 * If two chunks have content that will fit in one chunk, it
 * can release a chunk.
 * 
 * It keeps several chunks spare. It never moves while allocating.
 * Allocations larger than the threshold go to a page-level
 * system implementing a cross-platform mremap, which avoids
 * copying data.
 */
