/**
 * Reference-count garbage collection
 * 
 * Provides garbage collection based on reference
 * counting instead of scanning. This gives a tight 
 * object lifespan with guaranteed destruction and
 * (in practice) smaller processing bursts.
 * 
 * This is better for games because D currently has a
 * stop-the-world scanning collector. The work bunches 
 * up into frame-shattering chunks, causing the game
 * to either pause intermittently or lose considerable
 * time to running the collector once per frame for
 * predictable performance. The drawbacks of reference
 * counting are so tolerable in this situation it's 
 * embarassing.
 * 
 * Uses malloc and free from the C standard library.
 * Thread safe and lockless.
 * Supports weak and raw pointers.
 * Statically prohibits strong reference cycles.
 * Does not support interior pointers.
 * 
 * The GC is made aware of RC memory if it contains 
 * indirections - that is, pointers, references, arrays 
 * or delegates that might lead to GC memory. To avoid 
 * being scanned, don't store things the GC cares about,
 * that is, anything detected by std.traits.hasIndirections.
 * This does not include RC references themselves, which 
 * are ignored via some reflective cruft. (Also ignored:
 * raider.tools.array. Possibly more in future.)
 * 
 * Just to be clear, GC use is minimised, not prohibited.
 * Sometimes it is valuable or inevitable, particularly
 * with exception handling. But, by using reference counts
 * where they, ah, count, we make our games smoother.
 * 
 * Not compatible with any system that neglects to handle
 * struct (de)construction and copying correctly. At time 
 * of writing that includes builtin associative arrays and
 * struct initialisers.
 */

module raider.tools.reference;

import std.conv : emplace;
import std.traits;
import std.conv;
import core.atomic;
import core.exception : onOutOfMemoryError;
import core.memory : GC;
import core.stdc.stdlib : malloc, free;
import raider.tools.array;

//Evaluates true if a type T has collectable fields.
template hasGarbage(T)
{
	//Get crufty
	static if(isInstanceOf!(R, T) || 
		isInstanceOf!(W, T) ||
		isInstanceOf!(P, T) ||
		isInstanceOf!(Array, T))
		enum hasGarbage = false;
	else
		enum hasGarbage = Impl!(FieldTypeTuple!T);
		
	template Impl(T...)
	{
		/* T is a tuple of types. Impl recurses through 
		 * them by processing T[0] then either terminating 
		 * or passing the remaining types to Impl again. */
		static if (!T.length)
			enum Impl = false;
		//Stay crufty
		else static if(isInstanceOf!(R, T[0]) || 
		               isInstanceOf!(W, T[0]) ||
		               isInstanceOf!(P, T[0]) ||
		               isInstanceOf!(Array, T[0]))
			enum Impl = Impl!(T[1 .. $]);
		else static if(is(T[0] == struct) || is(T[0] == union))
			enum Impl = Impl!(FieldTypeTuple!(T[0]), T[1 .. $]);
		else
			enum Impl = hasIndirections!(T[0]) || Impl!(T[1 .. $]);
	}
}

version(unittest)
{
	struct hasGarbageTest
	{
		struct S1 { void* ptr; } static assert(hasGarbage!S1);
		struct S2 { int ptr; } static assert(!hasGarbage!S2);
		struct S3 { R!int i; } static assert(!hasGarbage!S3);
		class C1 { void* ptr; } static assert(hasGarbage!C1);
		class C2 { int ptr; } static assert(!hasGarbage!C2);
		class C3 { R!int i; } static assert(!hasGarbage!C3);
		class C4 { R!(R!int) ii; } static assert(!hasGarbage!C4);
		class C5 { W!C5 i; } static assert(!hasGarbage!C5);
		class C7 { P!C7 i; } static assert(!hasGarbage!C7);
		static assert(!hasGarbage!(R!int));
		//static assert(!hasGarbage!(R!(void*))); TODO Pointer boxing?
		static assert(hasGarbage!(void*));
	}
}

//Encapsulation allows to use structs as if they were classes.
private template Cap(T)
{
	static if(is(T == class) || is(T == interface)) alias T Cap;
	else static if(is(T == struct) || isScalarType!T)
	{
		class Cap
		{
			T _t; alias _t this;
			static if(is(T == struct))
			this(A...)(A a) { _t = T(a); } 
			else this(T t = 0) { _t = t; }
		}
	}
	else static assert(0, T.stringof~" can't be boxed");
}

private struct Header
{
	uint strongCount = 1;
	uint weakCount = 1; // +1 while strongCount != 0
	version(assert) uint pointerCount = 0;
	bool registeredWithGC = false;
}

/**
 * Allocates and constructs a reference counted object.
 * 
 * Encapsulates structs and scalar types.
 */
public R!T New(T, Args...)(auto ref Args args)
	if(is(T == class) || is(T == struct) || isScalarType!T)
{
	//Get upset if a class can't be instantiated
	if(false) static if(is(T == class)) T t = new T(args);

	//Allocate space for the header + object
	enum size = __traits(classInstanceSize, Cap!T);
	void* m = malloc(Header.sizeof + size);
	if(!m) onOutOfMemoryError;
	scope(failure) core.stdc.stdlib.free(m);

	//Obtain pointers to header and memory chunk
	Header* header = cast(Header*)m;
	void* chunk = m + Header.sizeof;

	//Init header
	*header = Header.init;

	//TODO Investigate any alignment issues that might affect performance.
	
	//Got anything the GC needs to worry about?
	static if(hasGarbage!T)
	{
		GC.addRange(chunk, size);
		header.registeredWithGC = true;
		scope(failure) GC.removeRange(chunk);
	}

	//Construct with emplace
	R!T result;
	result._referent = emplace!(Cap!T)(chunk[0..size], args);
	return result;
}

/**
 * Allocates and default constructs a reference counted object by class name.
 * 
 * Warning: Currently doesn't default construct.
 * Useless except for classes without complex construction.
 * 
 * This method is adapted from object.factory.
 */
public R!Object New(in char[] classname)
{
	R!Object result;

	const ClassInfo ci = ClassInfo.find(classname);

	//Get upset if a class can't be instantiated
	if(!ci) { return result; }
	if(ci.m_flags & 8 && !ci.defaultConstructor) return result;
	if(ci.m_flags & 64) return result; // abstract

	//Allocate space for the header + object
	size_t size = ci.init.length;
	void* m = malloc(Header.sizeof + size);
	if(!m) onOutOfMemoryError;
	scope(failure) core.stdc.stdlib.free(m);

	//Obtain pointers to header and memory chunk
	Header* header = cast(Header*)m;
	void* chunk = m + Header.sizeof;

	//Init header
	*header = Header.init;

	//Assume the GC is interested
	GC.addRange(chunk, size);
	header.registeredWithGC = true;
	scope(failure) GC.removeRange(chunk);

	//Init object
	chunk[0 .. size] = ci.init[];

	//Default-construct (if it has one)
	if(ci.m_flags & 8 && ci.defaultConstructor)
	{
		//This fails for some reason.
		//ci.defaultConstructor(cast(Object)chunk);

		//Source says defaultConstructor is void function(Object)..
		//static assert(is(typeof(ci.defaultConstructor) == void function(Object)));
		//static assert(__traits(compiles, cast(Object)chunk));
	}

	result._void = chunk;
	return result;
}

/**
 * A strong reference.
 * 
 * When there are no more strong references to an object
 * it is immediately deconstructed.
 *
 * This struct implements incref/decref semantics. The 
 * reference is aliased so the struct can be used as if 
 * it were the reference.
 */
public alias Reference!"R" R;

/**
 * A weak reference.
 * 
 * Weak references do not keep objects alive and
 * so help describe ownership. They also break
 * reference cycles that lead to memory leaks.
 * 
 * Weak references are like pointers, except they 
 * can check if the referent is alive and promote
 * safely if so, and can't dereference directly.
 * In fact, weak references aren't much like
 * pointers at all. I lied.
 */
public alias Reference!"W" W;

/**
 * A pointer reference.
 * 
 * Pointer references are like weak references, but
 * they cannot check the referent is alive, and can
 * only be accessed if the programmer ensures it is.
 * In fact, they're really just raw pointers with a
 * bit of optional debugging. Not especially similar
 * to weak references. Sorry.
 * 
 * They (and raw pointers) assume the strength of the 
 * strongest reference you can guarantee exists at a 
 * given moment. If a strong reference exists, access
 * them directly. If a weak reference exists, promote
 * them by constructing a strong reference (make sure
 * to check the promotion succeeded and the reference
 * !is null). If you're not sure any references exist
 * then throw that pointer away, friend, 'cause it
 * sure as shootin' ain't pointin' at nothin'.

 * An assert will raise if pointer refs remain when the 
 * last strong reference expires. Make sure to nullify 
 * all pointer refs before the object is destroyed. In 
 * release mode, the assert is removed, and pointer refs 
 * become as efficient as their namesake. Hopefully.
 */
public alias Reference!"P" P;

public template isReference(T)
{
	enum isReference = isInstanceOf!(R, T) || 
		isInstanceOf!(W, T) || 
		isInstanceOf!(P, T);
}

private template Reference(string C)
if(C == "R" || C == "W" || C == "P")
{
	struct Reference(T)
	if(is(T == class) || is(T == interface) || is(T == struct) || isScalarType!T)
	{ private:
		alias Cap!T B;

		//Referent and void union (abandon hope, Java developers)
		union { public B _referent = null; void* _void; }

		//Header hides before _void
		ref shared(Header) header()
		{ return *((cast(shared(Header)*)_void) - 1); }

	public:

		//Make the reference behave loosely like the referent
		static if(C != "W")
		{
			alias _referent this;
			auto opIndex(A...)(A args) { return _referent[args]; }
		}

		//Concise casting between reference types.
		//Templated to instantiate at call site to avoid cyclic template evaluation failure.
		@property R!T r()() { return R!T(_referent); }
		@property W!T w()() { return W!T(_referent); }
		@property P!T p()() { return P!T(_referent); }

		//Read-access to reference counts
		@property uint rc() { return header.strongCount; }
		@property uint wc() { return header.weakCount - (header.strongCount != 0); }
		version(assert) @property uint pc() { return header.pointerCount; }

		//When assert is off, pointer references do not incref or decref.
		version(assert) { enum hasRefSem = true; }
		else { enum hasRefSem = (C != "P"); }

		//ctor, copy, dtor semantics
		static if(hasRefSem)
		{
			this(B that) { _referent = that; _incref; }
			this(this) { _incref; }
			~this() { _decref;  }
		}
		else this(B that) { _referent = that; }

		//Assign null
		void opAssign(typeof(null) wut)
		{
			static if(hasRefSem) { _decref; }
			_referent = null;
		}

		void opAssign(D, A:T)(D!A rhs) if(isInstanceOf(D, Reference))
		{
			//Assign a reference of the same strength
			static if(is(D == Reference!C)) swap(_referent, rhs.referent);
			//Assign a reference of a different strength
			else
			{
				alias Reference!C RefC; //for some reason D dislikes Reference!C!A
				this = RefC!A(rhs._referent); //can't really blame it
			}
		}

		A opCast(A)() const
		{
			static if(isReference!A) return A(cast(A.B)_referent);
			else
			{
				static assert(C != "W", "Weak reference cannot be cast.");
				
				static if(is(A == bool))
					return _referent is null ? false : true; 
				else static if(is(A == string))
					return to!string(_referent);
				else
					return cast(A)_referent;
			}
		}

	private:

		/* Let us discuss lockless weak references like the scholarly gentlefolk we are
		 * 
		 * These are the rules:
		 * - The object is destroyed when no strong references remain.
		 * - The memory is freed when no strong or weak references remain.
		 * - The object is destroyed once then freed once, in that order.
		 * 
		 * To avoid double-width compare-and-swap (DWCAS) operations,
		 * and simplify the implementation, we slightly modify these rules:
		 * - The object is destroyed when no strong references remain.
		 * - While strong references remain, a weak reference is implied.
		 * - The memory is freed when no weak references remain.
		 * 
		 * This avoids the 'when no strong or weak references remain' thing,
		 * which requires atomicity involving two uints, and thus DWCAS. It
		 * also guarantees the destroy-free ordering.
		 * 
		 * So. Here are the acquire and release operations.
		 * 
		 * Acquire strong:
		 * If copying from another strong ref, just incref.
		 * If promoting to strong from weak or raw, incref if refs remain; 
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
		 * Yay~
		 */

		static if(hasRefSem)
		{
			void _incref()
			{
				if(_referent)
				{
					//Currently, all strong acquires assume a weak source.
					//The performance hit should be minimal, but TODO profile.
					static if(C == "R")
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

						if(!acquire) _referent = null;
					}

					static if(C == "W") atomicOp!"+="(header.weakCount, 1);
					static if(C == "P") atomicOp!"+="(header.pointerCount, 1);
				}
			}
			
			void _decref()
			{
				if(_referent)
				{
					static if(C == "R")
					{
						if(atomicOp!"-="(header.strongCount, 1) == 0)
						{
							_dtor;
							if(atomicOp!"-="(header.weakCount, 1) == 0) _free;
							//Reminder: Exceptions thrown from destructors are errors (unrecoverable)
						}
					}

					static if(C == "W") if(atomicOp!"-="(header.weakCount, 1) == 0) _free;
					static if(C == "P") atomicOp!"-="(header.pointerCount, 1);
				}
			}
		}
		
		static if(C != "P")
		{
			void _free()
			{
				if(header.registeredWithGC) GC.removeRange(_void);
				core.stdc.stdlib.free(_void - Header.sizeof);
			}
		}

		static if(C == "R")
		{
			void _dtor()
			{
				//alias this makes it mildly impossible to call B.~this
				//FIXME Likely to explode if an encapsulated T uses alias this

				//Destroy referent. Temporary variable used because destroy() assigns null.
				void* o = _void;
				static if(is(T == struct)) destroy(_referent._t);
				else static if(is(T == class) || is(T == interface)) destroy(_referent);
				//numeric types don't need destruction
				_void = o;
				
				assert(header.pointerCount == 0);
			}
		}

		//Detect reference cycles
		static if(C == "R" && !__traits(compiles, FieldTypeTuple!T))
			static assert(0, "Reference cycle detected.");
	}
}

version(unittest)
{
	/* Of all the things that need to print stuff for
	 * debugging purposes, reference counting is about
	 * the neediest. */
	import std.stdio;
	int printfNope(in char* fmt, ...) { return 0; }
	alias printfNope log;
	//alias printf log;

	//These must be in module scope for their ClassInfo to register for New.
	class NewC1 { this() { log("this()\n"); } }
	class NewC2 { }

	class NewByNameTest
	{
		unittest
		{
			R!Object o1 = New(fullyQualifiedName!NewC1);
			assert(o1);
			R!NewC1 c1 = cast(R!NewC1)o1;
			assert(c1);
			R!Object o2 = New("raider.tools.reference.NewC2");
			assert(o2);
			R!NewC2 c2 = cast(R!NewC2)o2;
			assert(c2);
		}
	}

	struct RTest
	{
		class C1 { W!C3 c3; } //Change to R!C3 to get a reference cycle error
		class C2 { R!C1 c1; }
		class C3 { R!C2 c2; }
	}

	struct PTest
	{
		unittest
		{
			R!int r = New!int();
			P!int p = r;
			assert(r.rc == 1);
			assert(r.pc == 1);
			p = null;
			assert(r.pc == 0);
			assert(p is null);
			assert(p == null);
		}
	}

	struct WTest
	{
		class C1 {
			int x;
			this() { log("WC1()\n"); }
			~this() { log("~WC1()\n"); } }
		
		unittest
		{
			R!C1 r = New!C1();
			assert(r != null);
			assert(r !is null);
			assert(r);
			assert(r.rc == 1);
			assert(r.wc == 0);
			assert(r.pc == 0);
			
			W!C1 w = r;
			assert(w.r == r);
			//FIXME D fails to destruct the value returned from w.r
			//assert(w.r is r);
			//Specifically with the 'is' syntax.. buh?
			assert(w.r != null);
			assert(w.r !is null);
			assert(w.r);
			assert(r.rc == 1);
			assert(r.wc == 1);
			assert(r.pc == 0);

			w.r.x = 1;
			assert(r.x == 1);
			r.x = w.r.x + w.r.x;
			assert(w.r.x == 2);
			assert(r.rc == 1);
			assert(r.wc == 1);
			assert(r.pc == 0);
			
			R!C1 rr = w.r;
			assert(rr);
			assert(rr is r);
			assert(r.rc == 2);
			assert(r.wc == 1);
			assert(r.pc == 0);
			
			r = null;
			assert(r == null);
			assert(r is null);
			assert(r._referent is null);
			assert(w.r);
			assert(w.rc == 1);
			assert(w.wc == 1);
			assert(w.pc == 0);
			
			rr = null;
			assert(w.r == null);
			assert(w.r is null);
			assert(w.rc == 0);
			assert(w.wc == 1); assert(w.header.weakCount == 1);
			assert(w.pc == 0);
			
			r = w.r;
			assert(r is null);
			assert(w.rc == 0);
			assert(w.wc == 1);
			assert(w.pc == 0);

			w = null;
		}
	}

	struct RInheritanceTest
	{
		class Animal
		{
			this() { log("new animal\n") ;}
			~this() { log("dead animal\n") ;}
			abstract void bite();
		}
		
		class Dog : Animal
		{
			this() { log("new dog\n");}
			~this() { log("dead dog\n"); }
			override void bite() { log("dog bite\n"); }
		}
		
		class Cat : Animal
		{
			this() { log("new cat\n"); }
			~this() { log("dead cat\n"); }
			override void bite() { log("cat bite\n"); }
		}
		
		static void poke(R!Animal animal)
		{
			animal.bite();
		}

		unittest
		{
			R!Animal a = New!Dog();
			
			R!Dog d = cast(R!Dog)a; assert(d);
			R!Cat c = cast(R!Cat)a; assert(c == null);
			assert(cast(R!Cat)a == null);
			poke(cast(R!Animal)d);
			//Cannot implicitly downcast, requires language support.

			//Cannot instance abstract class.
			static assert(!__traits(compiles, New!Animal()));
		}
	}

	struct BlitBugTest
	{
		class Foo { }
		struct Bar { R!Foo f; }
		
		unittest
		{
			R!Foo f = New!Foo();
			//Bar b = { f }; //No copy semantics here, creates untracked reference and double-free occurs
		}
	}
}