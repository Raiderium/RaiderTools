/**
 * Reference-count and manual garbage collection
 * 
 * Provides garbage collection based on reference
 * counting or manual management instead of tracing.
 * This gives a tight object lifespan with guaranteed 
 * destruction and (in practice) smaller processing bursts.
 * 
 * This is useful for games because D currently has a
 * stop-the-world tracing collector. The work bunches 
 * up into frame-shattering chunks, causing the game
 * to either pause intermittently or lose considerable
 * time to running the collector once per frame for
 * predictable timing. Here, the drawbacks of reference
 * counting are preferable to those of the collector.
 * 
 * - Thread safe and lockless.
 * - Supports strong and weak references.
 * - Statically prohibits strong reference cycles.
 * - Does not support interior pointers.
 * - Uses malloc; allocator injection is TODO.
 * 
 * To use this module, add the @RC (Reference-Counted)
 * attribute to a class, or @UM (UnManaged) to either 
 * a struct or class. Then call New!T(args).
 * 
 * For reference-counted classes, New returns a strong
 * smart pointer, typed as R!T. Alias this allows the
 * struct to be used as if it were the referent. If
 * the reference is copied or destroyed, the reference
 * count is incremented and decremented accordingly.
 * 
 * This strong reference can be cast to a weak (W!T) 
 * reference (no alias this), or a native reference.
 * Native references to RC objects are equivalent to
 * dumb pointers and should be used for the majority
 * of variables, whenever you can guarantee a strong
 * reference exists to keep them alive.
 * 
 * For unmanaged types, New returns a native reference 
 * or pointer, which you must pass to a corresponding 
 * call to Delete. Delete won't accept references to an
 * interface or non-final class because it must determine
 * at compile-time if the object has garbage or not.
 * 
 * The D garbage collector is made aware of memory if it 
 * contains potential indirections to GC-managed memory - 
 * that is, pointers, references, arrays, delegates, etc.
 * To avoid the overhead of adding and removing scanned 
 * ranges, don't store things the GC cares about.
 * 
 * You can assert(!hasGarbage!T) to check if a type is clean,
 * and use @NotGarbage to ignore fields if you can guarantee
 * they won't lead to GC memory.
 * 
 * @RC and @UM types are trusted to be allocated through
 * New, therefore native pointers and references to them 
 * are not considered garbage. Needless to say, don't betray
 * that trust by using operator new.
 * 
 * The superclasses and interfaces extended by @RC types
 * do not strictly require the @RC attribute, but if they
 * don't have it, they will be unusable in R!T and W!T,
 * and native references will be considered garbage.
 * An @RC superclass or interface must guarantee none of
 * its inheritors are allocated with operator new.
 * 
 * Just to be clear, this module aims to minimise GC use,
 * not prohibit it entirely. Sometimes it is valuable or 
 * inevitable, particularly with strings and exceptions. 
 * But, by using reference counts where they, ah, count, 
 * we make our games smoother.
 * 
 * RC references are not compatible with any system that 
 * neglects to handle struct (de)construction and copying 
 * correctly. At time of writing that includes builtin 
 * associative arrays, the 'is' operator (specific cases), 
 * and struct initialisers (!).
 */
module raider.tools.reference;

/*
 * Huge TODO: Incorporate std.experimental.allocator.
 * This will allow to select situation-appropriate 
 * allocation strategies.
 * 
 * This component of Phobos was approved July 25th 2015
 * to unanimous approval. It is an exceptionally useful
 * application of D's template mechanisms. It absolutely
 * must be leveraged before a single line of reinvented
 * free-list or bitmap code appears.
 * 
 * Notes on implementation:
 * Use quantizer to replace capacity-doubling in tools.array.
 */

import std.conv : emplace;
import std.traits;
import core.atomic : atomicOp, atomicLoad, MemoryOrder, cas;
import core.exception : onOutOfMemoryError;
import std.algorithm : swap;
import core.memory : GC;
import core.stdc.stdlib : malloc, mfree = free; //replace with mallocator
//import std.experimental.allocator.mallocator : Mallocator;

/**
 * Attribute indicates a class or interface is reference-counted.
 */
enum RC;

/**
 * Attribute indicates a class, struct or union is unmanaged.
 */
enum UM; 

/**
 * Attribute indicates a field should be skipped for garbage tracing purposes.
 */
enum NotGarbage;

/**
 * True if a type can be instantiated with New.
 */
template isNonGCType(T) 
{
	static if(isAggregateType!T)
		static assert(!(hasUDA!(T, RC) && hasUDA!(T, UM)), T~" can't have both @RC and @UM.");

	//RC classes must be non-abstract.
	static if(is(T == class) && hasUDA!(T, RC))
		enum isNonGCType = !isAbstractClass!T;
	else
		enum isNonGCType = isUnmanagedType!T;
}

/**
 * True if a type is Unmanaged.
 */
template isUnmanagedType(T)
{
	//UM classes must be final for static garbage analysis.
	static if(is(T == class) && hasUDA!(T, UM))
		enum isUnmanagedType = isFinalClass!T;
	
	else static if(is(T == struct) || is(T == union))
		enum isUnmanagedType = hasUDA!(T, UM);
	else
		enum isUnmanagedType = false;
}

/**
 * True if a type can be used as a strong or weak reference.
 */
template isReferentType(T)
{
	enum isReferentType = (is(T == class) || is(T == interface)) && 
		(hasUDA!(T, RC) && !hasUDA!(T, UM));
}

/**
 * True if a symbol or type is or contains tracable garbage.
 * 
 * Errs on the side of caution. Unrecognised types are assumed 
 * to be worth tracing. If you're absolutely sure a field does 
 * not lead to garbage-collected memory, use @NotGarbage.
 * 
 * Native references and pointers to @RC or @UM types are not
 * considered garbage. Do not use them with operator new.
 */
template hasGarbage(T...) if(T.length == 1)
{
	enum hasGarbage = Impl!T;

	//static required otherwise there are two context pointers
	static template Impl(T...) 
	{
		static if (!T.length)
			enum Impl = false;
		
		//Expand classes and all base classes.
		else static if (is(T[0] P == super))
		{
			static assert(T.length == 1);
			static if(P.length)
			{
				//Template can only touch one context (via a symbol tuple) at a time.
				//That is, base class symbols cannot coexist with those of a subclass.
				//Hence, we separate them into another instantiation.
				enum Impl = Impl!(P[0]) || Impl!(T[0].tupleof);
			}
			else enum Impl = false;
		}

		//Ignore @NotGarbage symbols.
		else static if (is(typeof(T[0])) && hasUDA!(T[0], NotGarbage))
			enum Impl = Impl!(T[1 .. $]);

		//Inspect types..
		else static if (is(typeof(T[0]) U) || is(T[0] U))
		{
			//Expand structs and unions.
			static if (is(U == struct) || is(U == union))
				enum Impl = Impl!(U.tupleof) || Impl!(T[1 .. $]);
			
			//Ignore pointers if the target type is struct/union @UM, immutable, or a function.
			else static if (is(U P : P*))
			{
				static if ((isUnmanagedType!P && !is(P == class)) || 
						is(P == immutable) || is(P == function))
					enum Impl = Impl!(T[1 .. $]);
				else
					enum Impl = true;
			}
			
			//Ignore basic types.
			else static if (isBasicType!U)
				enum Impl = Impl!(T[1 .. $]);
			
			//Ignore references if the class/interface is referent-valid or unmanaged.
			else static if (is(U == class) || is(U == interface))
			{
				static if(isReferentType!U || isUnmanagedType!U)
					enum Impl = Impl!(T[1 .. $]);
				else
					enum Impl = true;
			}
			
			//Instantiate to inspect the item type of a static array.
			else static if (isStaticArray!U && is(U : E[N], E, size_t N))
				enum Impl = Impl!(E, T[1 .. $]);
			
			//Considered garbage: associative arrays, dynamic arrays,
			//interfaces, and anything not explicitly excused.
			else
				enum Impl = true;
		}
		else
			static assert(0, "There's something that isn't a symbol or type?! Buwhaaa.. ");
	}
}

unittest
{
	static assert(!hasGarbage!int);
	static assert( hasGarbage!(int**));

	abstract class A { uint* ptr; }
	static assert( hasGarbage!A);

	interface I {}
	static assert(!hasGarbage!I);

	I i;
	static assert( hasGarbage!(i));

	@RC final class B : A, I { }
	static assert( hasGarbage!B);
	static assert(!hasGarbage!(R!B));

	B b;
	static assert(!hasGarbage!(b));

	B* bp;
	static assert( hasGarbage!(bp));

	class C { float[2] f; }
	static assert(!hasGarbage!C);

	C c;
	static assert( hasGarbage!(c));

	struct D { D* ptr; }
	static assert( hasGarbage!D);

	@UM struct E { E* ptr; uint function (uint) func; }
	static assert(!hasGarbage!E);

	static assert(!hasGarbage!(E*));
	static assert( hasGarbage!(E**));
}

private struct Header
{
	uint strongCount = 1;
	ushort weakCount = 1;
	bool isTraced;
}

static assert(Header.sizeof == 8);
/* Header could be as small as 4 bytes with bitfield packing,
 * but for the sake of CAS performance, simplicity and 64-bit
 * alignment and the fact that it is unlikely to ever have an 
 * appreciable impact on memory resources...
 * ...we move on with our dignity intact
 */

/**
 * Allocates and constructs an object.
 * 
 * If the type is @UM (UnManaged), this is a simple RAII dealie
 * supporting both class and struct types. A corresponding call 
 * to Delete is necessary or the memory will leak. It returns a
 * native reference for classes, and a pointer for structs. The
 * classes must be final, to avoid polymorphic garbage issues.
 * 
 * Otherwise the type is a class with @RC. A reference count is
 * prefixed to the allocated memory. The object is destroyed if
 * all strong references disappear, and deallocated if all weak
 * references also disappear. Reference counts are tracked with
 * templated smart pointers R!T and W!T.
 */
public auto New(T, Args...)(auto ref Args args) if(isNonGCType!T)
{
	//Get upset if a type can't be instantiated (nested, abstract, etc)
	if(false) auto t = new T(args);

	//The irony is not lost on me that the first line of 
	//New contains an unreachable call to operator new

	//Find the space required for the type.
	static if(is(T == class))
		enum size = __traits(classInstanceSize, T);
	else
		enum size = T.sizeof;

	//Add the header. 
	enum allocSize = size + (hasUDA!(T, RC) ? Header.sizeof : 0);

	//Allocate (and never forget that malloc(0) is a thing)
	void* m = malloc(allocSize); 
	if(!m) onOutOfMemoryError;
	scope(failure) mfree(m);

	//Obtain pointers to header and object
	static if(hasUDA!(T, RC))
	{
		Header* header = cast(Header*)m;
		void* state = m + Header.sizeof;

		//Init header
		*header = Header.init;
	}
	else alias state = m;
		
	//Got anything the GC needs to worry about?
	static if(hasGarbage!T)
	{
		GC.addRange(state, size);
		static if(hasUDA!(T, RC)) header.isTraced = true; 
		scope(failure) GC.removeRange(state);
	}

	//Construct with emplace
	static if(hasUDA!(T, RC))
	{
		R!T result;
		result._referent = emplace!T(state[0..size], args);
		return result;
	}
	else
	{
		static if(is(T == class))
			return emplace!T(state[0..size], args); //welcome to the masquerade
		else static if(is(T == struct) || is(T == union))
			return emplace!T(cast(T*)state, args);
		else
			static assert(0, "isNonGCType has made a mistake");
	}
}

public void Delete(T)(T that) if(isUnmanagedType!T && is(T == class))
{
	destroy(that);
	static if(hasGarbage!T) GC.removeRange(cast(void*)&that);
	mfree(cast(void*)&that);
}


public void Delete(T)(T* that) if(isUnmanagedType!T && !is(T == class))
{
	destroy(that);
	static if(hasGarbage!T) GC.removeRange(cast(void*)that);
	mfree(cast(void*)that);
}

/**
 * A strong reference.
 * 
 * When there are no more strong references to an object
 * it is immediately deconstructed.
 *
 * This struct implements incref/decref semantics. The 
 * reference is aliased so the struct can be used as if 
 * it were the referent.
 */
template W(T)
{
	alias W = Reference!("W", T);
}

/**
 * A weak reference.
 * 
 * Weak references do not keep objects alive and
 * so help describe ownership. They also break
 * reference cycles that lead to memory leaks.
 * 
 * Weak references do not alias the referent
 * directly. They can instead check if it is
 * alive and promote to a strong reference
 * by casting, assignment or construction.
 * 
 * A native reference taken from a weak reference
 * is only as strong as that weak reference.
 * You must ensure a strong reference exists,
 * and check it !is null, before directly using
 * any native reference.
 */
template R(T)
{
	alias R = Reference!("R", T);
}

struct Reference(string C, T) if((C == "R" || C == "W") && isReferentType!T)
{ private:
	//Referent and void union (abandon hope, Java developers)
	union {
		public T _referent = null;
		@NotGarbage void* _referent_void;
	}

	//Interface referents don't have the same address as the object
	auto _object_void()
	{
		return cast(void*)cast(Object)_referent;
	}

	//Header hides before the object
	ref shared(Header) header() {
		//subtract 1 and dereference
		return *((cast(shared(Header)*)_object_void) - 1);
	} 

public:

	//Make the reference behave loosely like the referent
	//I hesitate to attempt to clarify exactly *how* loosely
	static if(C == "R")
	{
		alias _referent this;
		auto opIndex(A...)(A args) { return _referent[args]; }
	}

	//Concise casting between reference types.
	//Templated to instantiate at call site to avoid cyclic template evaluation failure.
	@property R!T _r()() { return R!T(_referent); }
	@property W!T _w()() { return W!T(_referent); }

	//Read-access to reference counts
	@property auto _rc() { return header.strongCount; }
	@property auto _wc() { return header.weakCount - (header.strongCount != 0); }

	//ctor with covariant reference
	this(D : Reference!(E, A), string E, A:T)(D that)
	{
		//Unexpected: isInstanceOf!(Reference, D) is weirdly false.
		//Not sure if this is intended behaviour.
		//Loss of information?
		static assert(is(D == Reference!(E, A)));
		static assert(!isInstanceOf!(Reference, D));

		_referent = that._referent;
		static if(C == "R" && E == "W") _acquire;
		static if(C == "R" && E == "R") _incref;
		static if(C == "W") _incwef;


	}

	//ctor with covariant native reference
	this(A:T)(A that) if(is(A == class) || is(A == interface))
	{
		_referent = that;
		static if(C == "R") _acquire; else _incwef;
	}

	this(this) { static if(C == "R") _incref; else _incwef; }
	~this() { static if(C == "R") _decref; else _decwef;}

	//Assign null
	void opAssign(typeof(null) wut)
	{
		static if(C == "R") _decref; else _decwef;
		_referent = null;
	}

	//Assign a covariant reference
	void opAssign(D : Reference!(E, A), string E, A:T)(auto ref D rhs) //const..?
	{
		//Slightly modified copy-and-swap idiom.
		//We do want a copy of the rhs, but only as our strength & type of reference.
		//auto ref avoids the unnecessary copy whenever possible.
		auto tmp = Reference!(C, T)(rhs); //covariant constructor
		swap(_referent, tmp._referent); //tmp disposes of our reference, as normal
	}

	//Assign a covariant native reference
	void opAssign(A:T)(A rhs) if(is(A == class))
	{
		auto tmp = Reference!(C, T)(rhs);
		swap(_referent, tmp._referent);
	}

	//Cast to covariant references of different strengths
	auto opCast(D : Reference!(E, A), string E, A:T)() const 
	{
		//this assumes a weak source even if it's strong :I
		return D(cast(A)_referent); 
	}

	A opCast(A)() const
	{	
		static if(is(A == bool))
			return _referent is null ? false : true; 
		//else static if(is(A == string))
		//	return to!string(_referent); //this should work OUTSIDE.
		//Try hijacking it?
		else
			return cast(A)_referent;
	}
	

private:

	static if(C == "R")
	{
		void _acquire()
		{
			if(_referent)
			{
				uint acquire;
				uint get, set;
				do
				{
					get = set = atomicLoad!(MemoryOrder.raw)(header.strongCount);
					acquire = set != 0;
					set += acquire; 
				}
				while(!cas(&header.strongCount, get, set));
				
				version(assert) if(acquire) assert(set != 0, "Strong refcount overflow (!)");
				
				if(!acquire) _referent = null;
			}
		}
	 
		void _incref()
		{
			if(_referent)
			{
				auto rc = atomicOp!"+="(header.strongCount, 1);
				assert(rc != 0, "Strong refcount overflow (!)");
			}
		}

		void _decref()
		{
			if(_referent)
			{
				auto rc = atomicOp!"-="(header.strongCount, 1);
				assert(rc != typeof(header.strongCount).max, T.stringof ~ "Strong refcount underflow (!)");

				//Reminder: Exceptions thrown from destructors are errors (unrecoverable)
				if(rc == 0) { _dtor; _decwef; }
			}
		}

		void _dtor()
		{
			//Destroy referent. Note that destroy() assigns null.
			auto limbo = _referent_void;
			destroy(_referent);
			//We actually want to keep the memory around a while, destroy(). Be patient.
			_referent_void = limbo; 
		}
	}
	else
	{
		void _incwef()
		{
			if(_referent)
			{
				auto wc = atomicOp!"+="(header.weakCount, 1);
				assert(wc != 0, "Weak refcount overflow (!)");
			}
		}
	}

	void _decwef()
	{
		if(_referent)
		{
			auto wc = atomicOp!"-="(header.weakCount, 1);
			assert(wc != typeof(header.weakCount).max, "Weak refcount underflow (!)");
			if(wc == 0) _free;
		}
	}

	void _free()
	{
		if(header.isTraced) GC.removeRange(_object_void);
		mfree(_object_void - Header.sizeof);
	}
	
	//Detect reference cycles
	static if(C == "R" && !__traits(compiles, Fields!T))
		static assert(0, "Reference cycle detected.");
	// Why people continue to list reference cycles as a 
	// reason to avoid reference counting is beyond me.
	// People can be so afraid of describing ownership.
}

unittest
{
	//A non-function scope is required for most of these tests.
	struct S
	{
		@RC class C3 { R!C2 c2; }
		@RC class C1 { W!C3 c3; } //Change to R!C3 to get a reference cycle error
		@RC class C2 { R!C1 c1; }

		@RC class A { }
		@RC class B : A { }

		unittest
		{
			auto r_b = New!B();  //strong = strong
			R!A r_a;
			r_a = r_b;           //strong = covariant strong
			assert(r_a._referent_void == r_b._referent_void);
			assert(r_a._rc == 2);

			W!A w_a = r_b;         //weak = covariant strong
			W!B w_b = r_b;         //weak = strong
			B n_b = r_b;         //native = strong
			A n_a = r_b;         //native = covariant strong

			//Can't assign base to derived without explicit cast
			static assert(!__traits(compiles, n_b = r_a));
			n_b = cast(B)r_a; assert(n_b);
			n_b = cast(R!B)r_a; assert(n_b);

			n_b = cast(B)w_b;    //native = weak (no referent aliasing, cast required)
			r_b = n_b;           //strong = native
			w_b = n_b;             //weak = native

			r_b = R!B(r_b);     //strong(strong)

			//Can't construct derived from base without explicit cast
			static assert(!__traits(compiles, r_b = R!B(r_a)));
			r_b = R!B(cast(R!B)r_a); assert(r_b);
			     
			r_b = R!B(w_b);     //strong(weak)
			r_a = R!A(w_b);     //strong(covariant weak)
			r_b = R!B(n_b);     //strong(native)
			n_a = R!B(w_b);     //native = covariant strong(weak)

			//No referent aliasing, cast required.
			static assert(!__traits(compiles, n_a = W!B(r_b)));

			assert(w_b._rc == 2);
			assert(w_b._wc == 2);

			//Acquire succeeds
			r_b = w_b; assert(r_b);
			r_b = n_b; assert(r_b);
			r_b = R!B(w_b); assert(r_b);
			r_b = R!B(n_b); assert(r_b);

			r_b = null; 
			r_a = null;

			//Object destroyed, but not freed
			assert(w_b._rc == 0);
			assert(w_b._wc == 2);

			//Acquire fails
			r_b = w_b; assert(r_b is null);
			r_b = n_b; assert(r_b is null);
			r_b = R!B(w_b); assert(r_b is null);
			r_b = R!B(n_b); assert(r_b is null);

			//is operator problem
			auto b = New!B();
			auto b_rc = b._rc;
			//assert(b._r is b); //Fails to destroy the value returned from b._r
			assert(b_rc == b._rc); //This will fail if the above is uncommented.
		}

		@RC final class C { }
		struct D { R!C foo; }

		unittest
		{
			//Struct initializer problem
			R!C c = New!C();
			D d1;
			d1.foo = c; //This works
			assert(c._rc == 2);
			//D d2 = { c }; //This creates an untracked reference and double-free occurs
			assert(c._rc == 2); //This will pass even though d2 holds a reference
		}

		@RC interface IA { }
		@RC interface IB { }
		@RC class E : IA, IB { }

		unittest
		{
			auto e = New!E();
			R!IA ia = e;
			R!IB ib = e;
			assert(ia);
			assert(ib);
			//Interface references point inside the object
			assert(ia._referent_void != ib._referent_void);
			assert(ia._object_void == ib._object_void);
			assert(ia._rc == 3);
			assert(ib._rc == 3);
		}

		@UM interface IC { }
		@UM final class F : IC { }

		unittest
		{
			auto f = New!F();
			assert(f);
			IC ic = f;
			Delete(f);
			static assert(!__traits(compiles, Delete(ic)));
		}

		@UM struct T { }
		@UM union U { uint x; float y; }
		struct V { }

		unittest
		{
			auto t = New!T();
			assert(t);
			Delete(t);

			T tv;
			static assert(!__traits(compiles, Delete(tv)));

			auto u = New!U();
			assert(u);
			Delete(u);

			V* v;
			static assert(!__traits(compiles, New!V()));
			static assert(!__traits(compiles, Delete(v)));
		}
	}


}

/* 11-5-2017
 * Regarding lockless weak references...
 * 
 * These are the rules:
 * - The object is destroyed when no strong references remain.
 * - The memory is freed when no strong or weak references remain.
 * - The object is destroyed once then freed once, in that order.
 * 
 * To avoid double-width compare-and-swap (DWCAS) operations,
 * and simplify the implementation, we slightly modify these rules:
 * - The object is destroyed when no strong references remain.
 * - The memory is freed when no weak references remain.
 * - While strong references remain, a weak reference is implied.
 * 
 * This avoids checking 'when no strong or weak references remain',
 * which requires atomicity on two fields - usually implying DWCAS. 
 * It also guarantees the destroy-free ordering.
 * 
 * So. Here are the acquire and release operations.
 * 'incref' means 'increment strong reference count'.
 * 'incwef' means 'increment weak reference count'.
 * 
 * Acquire strong:
 * If copying from another strong ref, just incref.
 * If promoting to strong from weak, incref if refs remain; 
 * otherwise, fail to acquire. (A custom atomic increment.)
 * 
 * Acquire weak:
 * Just incwef. No special action to take.
 * 
 * Free strong:
 * Decref.
 * If no more refs, destroy then decwef.
 * If no more wefs, free memory.
 * 
 * Free weak:
 * Decwef. If no more wefs, free memory.
 * 
 * Yay!~
 */
