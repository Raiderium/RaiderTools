/**
 * Reference-count garbage collection
 * 
 * Provides garbage collection based on reference
 * counting instead of scanning. This gives a tight 
 * object lifespan with guaranteed destruction and
 * no processing bursts. Uses malloc and free from 
 * the C standard library and is thread-safe.
 * 
 * This is better for games because D currently has a
 * stop-the-world scanning collector. The work bunches 
 * up into frame-shattering chunks, causing the game
 * to pause intermittently. The overhead of incrementing 
 * and decrementing reference counts is so tolerable 
 * in this situation it's embarassing.
 * 
 * The GC is made aware of RC memory if it contains 
 * indirections - that is, pointers, references, arrays 
 * or delegates that might lead to GC memory. To avoid 
 * being scanned, don't store things the GC cares about,
 * that is, anything detected by std.traits.hasIndirections.
 * This does not include RC references themselves, which
 * are ignored via some reflective cruft.
 * 
 * Just to be clear, GC use is minimised, not prohibited.
 * Sometimes it is valuable or inevitable, particularly
 * with exception handling. But, by using determinism 
 * where it counts, we make our games smoother.
 * 
 * Not compatible with any system that mishandles structs.
 * I.e. built-in associative arrays. Use tool.map.
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

//Evaluates true if a type T has GC-scannable fields.
template hasGarbage(T)
{
	template Impl(T...)
	{
		static if (!T.length)
			enum Impl = false;
		else static if(isInstanceOf!(R, T[0]) || 
		               isInstanceOf!(W, T[0]) ||
		               isInstanceOf!(P, T[0]) ||
		               isInstanceOf!(Array, T[0]))
			enum Impl = Impl!(T[1 .. $]);
		else static if(is(T[0] == struct) || is(T[0] == union))
			enum Impl = Impl!(FieldTypeTuple!(T[0]), T[1 .. $]);
		else
			enum Impl = hasIndirections!(T[0]) || Impl!(T[1 .. $]);

		/*FIXME Allow weak references to break cycles.
		 * 
		 * Reference template evaluation fails when
		 * references form a cycle. T.tupleof fails 
		 * because T is a forward reference.
		 * 
		 * Presumably a recursion issue; how can it
		 * know the structure of T until evaluating
		 * R!T; how can it finish evaluating R!T until
		 * it knows the structure of T, etc.
		 * 
		 * Oddly enough, T.tupleof only fails in 
		 * ~this() and static scope; it works fine 
		 * in this() and other methods.
		 * 
		 * Electing to ignore until the manure hits 
		 * the windmill and a class absolutely must
		 * have a non-pointer reference to its kin.
		 * The solution is to change the weak
		 * reference strategy from zombies to a list 
		 * of weak references, or a zombie monitor.
		 * 
		 * Serendipitously, the evaluation failure
		 * can be used to detect reference cycles
		 * at compile time, though it generates
		 * some annoying false positives.
		 */
	}

	static if(isInstanceOf!(R, T) || 
	          isInstanceOf!(W, T) ||
	          isInstanceOf!(P, T) ||
	          isInstanceOf!(Array, T))
		enum hasGarbage = false;
	else
		enum hasGarbage = Impl!(FieldTypeTuple!T);
}

version(unittest)
{
	struct hasGarbageTest
	{
		struct S1 { void* ptr; } static assert(hasGarbage!S1);
		struct S2 { int ptr; } static assert(!hasGarbage!S2);
		struct S3 { R!int i; } static assert(!hasGarbage!S3);
		struct S4 { union { int i; R!int j; }} static assert(!hasGarbage!S4);
		class C1 { void* ptr; } static assert(hasGarbage!C1);
		class C2 { int ptr; } static assert(!hasGarbage!C2);
		class C3 { R!int i; } static assert(!hasGarbage!C3);
		class C4 { R!(R!int) ii; } static assert(!hasGarbage!C4);
		//class C5 { W!C5 i; } //See to-do in hasGarbage.
		class C7 { P!C7 i; } static assert(!hasGarbage!C7);
		static assert(!hasGarbage!(R!int));
		//static assert(!hasGarbage!(R!(void*))); TODO Pointer boxing?
		static assert(hasGarbage!(void*));
	}
}

//EnCAPsulation allows to use structs as if they were classes.
private template Cap(T)
{
	static if(is(T == class) || is(T == interface))
		alias T Cap;
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

private struct Header(string C = "")
{
	ushort strongCount = 1;
	ushort weakCount = 0;
	version(assert)
	{
		ushort pointerCount = 0;
		ushort padding; //make CAS happy (needs 8, 16, 32 or 64 bits)
	}

	//Convenience alias to a reference's count.
	static if(C == "R") alias strongCount count;
	static if(C == "W") alias weakCount count;
	static if(C == "P") version(assert) alias pointerCount count;
}

/**
 * Allocates and constructs a reference counted object.
 * 
 * Encapsulates structs and scalar types.
 */
public R!T New(T, Args...)(auto ref Args args)
	if(is(T == class) || is(T == struct) || isScalarType!T)
{
	//HACK Detect, for example, if T is abstract.
	//For some reason, emplace doesn't.
	if(false) static if(is(T == class)) T t = new T(args);

	enum size = __traits(classInstanceSize, Cap!T);
	
	//Allocate space for the header + object
	void* m = malloc(Header!().sizeof + size);
	if(!m) onOutOfMemoryError;
	scope(failure) core.stdc.stdlib.free(m);

	Header!()* header = cast(Header!()*)m;
	void* chunk = m + Header!().sizeof;
	
	//Got anything the GC needs to worry about?
	static if(hasGarbage!T)
	{
		GC.addRange(chunk, size);
		scope(failure) GC.removeRange(chunk);
	}
	
	//Init header
	*header = Header!().init;

	//Construct with emplace
	R!T result;
	result._referent = emplace!(Cap!T)(chunk[0..size], args);
	return result;
}

/**
 * Allocates and default constructs a reference counted object by class name.
 * 
 * This method is adapted from object.factory.
 */
public R!Object New(in char[] classname)
{
	R!Object result;

	const ClassInfo ci = ClassInfo.find(classname);

	if(!ci) { return result; }

	if(ci.m_flags & 8 && !ci.defaultConstructor) return result;
	if(ci.m_flags & 64) return result; // abstract

	size_t size = ci.init.length;

	//Allocate space for the header + object
	void* m = malloc(Header!().sizeof + size);
	if(!m) onOutOfMemoryError;
	scope(failure) core.stdc.stdlib.free(m);

	Header!()* header = cast(Header!()*)m;
	void* chunk = m + Header!().sizeof;

	//Assume the GC is interested
	GC.addRange(chunk, size);
	scope(failure) GC.removeRange(chunk);
	
	//Init header
	*header = Header!().init;

	//Init object
	(cast(byte*)chunk)[0 .. size] = ci.init[];

	//Default-construct (if it has one)
	if(ci.m_flags & 8 && ci.defaultConstructor)
	{
		//This fails for some reason. Source says defaultConstructor is void function(Object)..
		//static assert(is(typeof(ci.defaultConstructor) == void function(Object)));
		//ci.defaultConstructor(cast(Object)chunk);
	}

	result._void = chunk;
	return result;
}

/**
 * A strong reference.
 * 
 * When there are no more strong references to an object
 * it is immediately deconstructed. This guarantee is 
 * what makes reference counting actually useful.
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
 * (..Except they don't, yet.)
 * 
 * Weak references are like pointers, except they 
 * do not need to be nullified manually, they can 
 * promote to a strong reference, and they can 
 * check if the referent is alive.
 * 
 * That said, don't use a weak reference if a
 * pointer reference will do. They impose a 
 * performance penalty.
 * 
 * When you use a weak reference, it is promoted
 * automatically on each access. Better to assign 
 * it to a strong reference, then access that.
 */
public alias Reference!"W" W;

/**
 * A pointer reference.
 * 
 * Pointer references are like weak references, but
 * they cannot check validity, and must not be accessed
 * unless validity is assured by the programmer.

 * An assert will raise if pointer refs remain when the 
 * last strong reference expires. Make sure to nullify 
 * all pointer refs before the object is destroyed. In 
 * release mode, the assert is removed, and pointer refs 
 * become as efficient as their namesake, reducing the 
 * garbage collection footprint.
 */
public alias Reference!"P" P;

public template isReference(T)
{
	enum isReference = isInstanceOf!(R, T) || 
		isInstanceOf!(W, T) || 
		isInstanceOf!(P, T);
}

//This is a template that returns a template
//I can honestly say it is necessary and useful
private template Reference(string C)
if(C == "R" || C == "W" || C == "P")
{
	struct Reference(T)
	if(is(T == class) || is(T == interface) || is(T == struct) || isScalarType!T)
	{ private:
		alias Cap!T B;

		//Referent
		union { public B _referent = null; void* _void; }

		//Header
		ref shared(Header!C) header()
		{ return *((cast(shared(Header!C)*)_void) - 1); }

	public:

		//Make the reference behave like the referent
		static if(C != "W")
		{
			alias _referent this;
			auto opIndex(A...)(A args)
			{
				return _referent[args];
			}

			//Casts to a pointer, for convenience.
			@property P!T p() { return P!T(_referent); }
		}
		//..Unless it's weak
		else
			@property R!T strengthen() { return R!T(_referent); }

		//When assert is off, pointer references do not incref or decref.
		version(assert) { enum hasRefSem = true; }
		else { enum hasRefSem = (C != "P"); }


		//Incref/decref semantics
		static if(hasRefSem)
		{
			this(this) { _incref; }
			~this() { _decref;  }
		}

		//Construct weak and pointer refs from a raw ref
		static if(C != "R")
		this(B that) { _referent = that; static if(hasRefSem) { _incref; } }

		//Assign null
		void opAssign(typeof(null) wut)
		{
			static if(hasRefSem) { _decref; }
			_referent = null;
		}

		void opAssign(D, A:T)(D!A rhs) if(isInstanceOf(D, Reference))
		{
			//Assign a reference of the same type
			static if(is(D == Reference!C))
				swap(_referent, rhs.referent);
			//Assign a reference of a different type
			else
			{
				alias Reference!C RefC; //for some reason D dislikes Reference!C!A
				this = RefC!A(rhs._referent); //can't really blame it
			}
		}

		A opCast(A)() const
		{
			static if(isReference!A)
				return A(cast(A.B)_referent);
			else
			{
				static assert(C != "W", "Weak reference is not directly accessible. Use strengthen property.");
				
				static if(is(A == bool))
					return _referent is null ? false : true; 
				else static if(is(A == string))
					return to!string(_referent);
				else
					return cast(A)_referent;
			}
		}

	private:

		static if(hasRefSem)
		{
			//Incref / decref
			void _incref()
			{
				if(_referent) atomicOp!"+="(header.count, 1);
			}
			
			void _decref()
			{
				/* Let us discuss lockless weak references
				 * 
				 * There are three rules:
				 * - The object is destructed when refs reach 0.
				 * - The memory is freed when refs and wefs reach 0.
				 * - Must be destructed and freed once, in that order.
				 * 
				 * Decref:
				 * If no more refs, dtor and set refs max.
				 * If no more refs OR wefs, do as above, then 
				 * decwef. If wefs max, free.
				 * 
				 * Decwef:
				 * If no more wefs, and refs max,
				 * decwef. If wefs max, free.
				 * 
				 * You are not expected to understand this.
				 * Or its implementation.
				 * I sure don't.
				 */
				if(_referent)
				{
					//CAS the whole header, we need atomicity
					Header!C get, set;
					
					do {
						get = set = atomicLoad(header);
						set.count -= 1; }
					while(!cas(&header(), get, set));

					if(set.count == 0)
					{
						static if(C == "R")
						{
							_dtor;
							scope(exit) //the memory must be freed, come what may
							{
								atomicStore(header.count, ushort.max);

								//If no more wefs, decwef. If wefs max, free.
								if(atomicLoad(header.weakCount) == 0 &&
								   atomicOp!"-="(header.weakCount, 1) == ushort.max)
									_free;
							}
						}
						static if(C == "W")
						{
							//If refs max, decwef. If wefs max, free.
							if(atomicLoad(header.strongCount) == ushort.max &&
							   atomicOp!"-="(header.weakCount, 1) == ushort.max)
								_free;
						}
					}
				}
			}
		}
		
		static if(C != "P")
		{
			void _free()
			{
				static if(__traits(compiles, FieldTypeTuple!T))
				{ static if(hasGarbage!T) GC.removeRange(_void); }
				else static assert(0, "Reference cycle detected.");

				core.stdc.stdlib.free(_void - Header!().sizeof);
			}
		}

		static if(C == "R")
		{
			/**
			 * Promote to a strong reference from a raw pointer.
			 * The pointer is trusted to point at valid header'd
			 * memory for the duration. Intended for use with
			 * the 'this' pointer, i.e. return R!MyClass(this).
			 */
			public this(B that)
			{
				if(that)
				{
					_referent = that;
					
					bool acquire;
					Header!C get, set;

					do {
						acquire = true;
						get = set = atomicLoad(header);

						//If refs are 0 or max, do not acquire.
						//(destruction in progress or complete)
						if(set.count == ushort.max || set.count == 0)
							acquire = false;
						//Otherwise, incref.
						else
							set.count += 1;
					}
					while(!cas(&header(), get, set));

					if(!acquire) _referent = null;
				}
			}

			void _dtor()
			{
				void* o = _void;
				
				//alias this makes it mildly impossible to call B.~this
				//FIXME Likely to explode if an encapsulated T uses alias this
				static if(is(T == struct))
				{
					destroy(_referent._t);
				}
				else static if(is(T == class) || is(T == interface))
				{
					destroy(_referent);
				}
				//numeric types don't need destruction
				
				//Reestablish referent (destroy() assigns null)
				_void = o;
				
				//assert(header.pointerCount == 0);
			}
		}
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
		class C1 { P!C3 c3; } //Change to R!C3 to get a reference cycle error
		class C2 { R!C1 c1; }
		class C3 { R!C2 c2; }
	}

	struct PTest
	{
		unittest
		{
			R!int r = New!int();
			P!int p = r;
			assert(r.header.strongCount == 1);
			assert(r.header.pointerCount == 1);
			p = null;
			assert(r.header.pointerCount == 0);
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
			assert(r.header.strongCount == 1);
			assert(r.header.weakCount == 0);
			assert(r.header.pointerCount == 0);
			
			W!C1 w = r;
			assert(w.strengthen == r);
			//FIXME D fails to destruct the value returned from w.strengthen.
			//assert(w.strengthen is r);
			//if(w.strengthen is r) {} else assert(0);
			assert(w.strengthen != null);
			assert(w.strengthen !is null);
			assert(w.strengthen);
			assert(r.header.strongCount == 1);
			assert(r.header.weakCount == 1);
			assert(r.header.pointerCount == 0);
			
			w.strengthen.x = 1;
			assert(r.x == 1);
			r.x = w.strengthen.x + w.strengthen.x;
			assert(w.strengthen.x == 2);
			assert(r.header.strongCount == 1);
			assert(r.header.weakCount == 1);
			assert(r.header.pointerCount == 0);
			
			R!C1 rr = w.strengthen;
			assert(rr);
			assert(rr is r);
			assert(r.header.strongCount == 2);
			assert(r.header.weakCount == 1);
			assert(r.header.pointerCount == 0);
			
			r = null;
			assert(r == null);
			assert(r is null);
			assert(r._referent is null);
			assert(w.strengthen);
			assert(w.header.strongCount == 1);
			assert(w.header.weakCount == 1);
			assert(w.header.pointerCount == 0);
			
			rr = null;
			assert(w.strengthen == null);
			assert(w.strengthen is null);
			assert(w.header.strongCount == ushort.max);
			assert(w.header.weakCount == 1);
			assert(w.header.pointerCount == 0);
			
			r = w.strengthen;
			assert(r is null);
			assert(w.header.strongCount == ushort.max);
			assert(w.header.weakCount == 1);
			assert(w.header.pointerCount == 0);
			
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
}